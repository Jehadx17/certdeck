import base64
import hashlib
import json
import random
import re
import shutil
import tempfile
import unittest
from io import StringIO
from pathlib import Path
from types import SimpleNamespace as NS
from unittest import mock

import anthropic
import httpx2
import jsonschema
from django.conf import settings
from django.core.management import call_command
from django.test import TestCase, override_settings
from django.utils import timezone
from datetime import timedelta

from core.models import Account, AiCall, Doc, Media, Token, now_ms, save_docs, token_hash
from core.stats import MIN_REVIEWS

TOKEN = "test-token"
AUTH = {"HTTP_AUTHORIZATION": f"Bearer {TOKEN}"}
EXAMPLE = settings.BASE_DIR.parent / "examples" / "cards.example.json"
DAY = 86_400_000


def message(payload, stop_reason="end_turn"):
    return NS(stop_reason=stop_reason,
              content=[NS(type="thinking", thinking="..."), NS(type="text", text=json.dumps(payload))],
              usage=NS(input_tokens=100, output_tokens=50, cache_read_input_tokens=10, cache_creation_input_tokens=5))


def ai_card(**kw):
    card = dict(type="basic", question="Q?", answer=None, options=None, correct=None, option_explanations=None,
                accepted=None, items=None, code=None, answer_code=None, language=None, explanation="Because.",
                certs=[{"cert": "DVA-C02", "domain": "1"}], tags=["lambda"], topic="lambda limits")
    card.update(kw)
    return card


def doc(id, data, kind="card", updated_at=1, deleted=False):
    return {"id": id, "kind": kind, "data": data, "updated_at": updated_at, "deleted": deleted}


@override_settings(ANTHROPIC_API_KEY="")
class ApiTests(TestCase):
    def setUp(self):
        self.owner = Account.objects.get(role="owner")  # created by migration 0003
        Token.objects.create(account=self.owner, hash=token_hash(TOKEN))
        media_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, media_dir)
        patcher = override_settings(CERTDECK_MEDIA_DIR=media_dir)
        patcher.enable()
        self.addCleanup(patcher.disable)

    def post(self, url, body):
        return self.client.post(url, body, content_type="application/json", **AUTH)

    # ---------- auth ----------

    def test_auth(self):
        self.assertEqual(self.client.get("/api/health").json(), {"ok": True})
        r = self.client.post("/api/sync", {"cursor": 0, "docs": []}, content_type="application/json")
        self.assertEqual(r.status_code, 401)
        self.assertIn("error", r.json())
        r = self.client.post("/api/sync", {"cursor": 0, "docs": []}, content_type="application/json",
                             HTTP_AUTHORIZATION="Bearer wrong")
        self.assertEqual(r.status_code, 401)
        self.assertEqual(self.client.get("/api/export").status_code, 401)
        self.assertEqual(self.post("/api/sync", {"cursor": 0, "docs": []}).status_code, 200)

    # ---------- sync ----------

    def test_sync_lww(self):
        r = self.post("/api/sync", {"cursor": 0, "docs": [doc("a", {"v": 1}, updated_at=10)]}).json()
        self.assertEqual([d["id"] for d in r["docs"]], ["a"])
        self.assertEqual(r["docs"][0], doc("a", {"v": 1}, updated_at=10))
        cursor = r["cursor"]

        r = self.post("/api/sync", {"cursor": cursor, "docs": [doc("a", {"v": "old"}, updated_at=5)]}).json()
        self.assertEqual(r, {"docs": [], "cursor": cursor, "more": False})  # older write rejected
        self.assertEqual(Doc.objects.get(doc_id="a").data, {"v": 1})

        r = self.post("/api/sync", {"cursor": cursor, "docs": [doc("a", {"v": 2}, updated_at=10, deleted=True)]}).json()
        self.assertEqual(r["docs"], [doc("a", {"v": 2}, updated_at=10, deleted=True)])  # equal timestamp wins
        self.assertGreater(r["cursor"], cursor)

        self.assertEqual(self.post("/api/sync", {"cursor": 0, "docs": [{"id": "x"}]}).status_code, 400)

    def test_sync_paging(self):
        save_docs(self.owner, [doc(f"d{i}", {"i": i}) for i in range(1005)])
        r = self.post("/api/sync", {"cursor": 0, "docs": []}).json()
        self.assertEqual(len(r["docs"]), 1000)
        self.assertTrue(r["more"])
        r2 = self.post("/api/sync", {"cursor": r["cursor"], "docs": []}).json()
        self.assertEqual(len(r2["docs"]), 5)
        self.assertFalse(r2["more"])
        ids = [d["id"] for d in r["docs"] + r2["docs"]]
        self.assertEqual(ids, [f"d{i}" for i in range(1005)])  # ordered by seq, nothing skipped

    # ---------- accounts & isolation ----------

    def student(self, name="sara", cap="10"):
        with mock.patch("getpass.getpass", return_value="longenough"):
            call_command("users", "create", name, f"{name}@x.com", "--cap", cap, stdout=StringIO())
        r = self.client.post("/api/login", {"email": f"{name}@x.com", "password": "longenough"}, content_type="application/json")
        return Account.objects.get(name=name), {"HTTP_AUTHORIZATION": "Bearer " + r.json()["token"]}

    def test_me_and_users_command(self):
        self.assertEqual(self.client.get("/api/me", **AUTH).json()["role"], "owner")
        sara, auth = self.student()
        me = self.client.get("/api/me", **auth).json()
        self.assertEqual((me["name"], me["role"], me["cap_usd"], me["remaining_usd"]), ("sara", "student", 10.0, 10.0))
        r = self.client.post("/api/login", {"email": "sara@x.com", "password": "longenough"}, content_type="application/json")
        phone2 = {"HTTP_AUTHORIZATION": "Bearer " + r.json()["token"]}  # a second device: both stay signed in
        self.assertEqual([self.client.get("/api/me", **a).status_code for a in (auth, phone2)], [200, 200])
        call_command("users", "disable", "sara", stdout=StringIO())
        self.assertEqual(self.client.get("/api/me", **phone2).status_code, 401)
        call_command("users", "enable", "sara", stdout=StringIO())
        call_command("users", "signout", "sara", stdout=StringIO())
        self.assertEqual([self.client.get("/api/me", **a).status_code for a in (auth, phone2)], [401, 401])
        call_command("users", "cap", "sara", "none", stdout=StringIO())
        self.assertIsNone(Account.objects.get(name="sara").cap_usd)
        with self.assertRaises(Exception):
            call_command("users", "delete", "sara", stdout=StringIO())  # needs --yes
        save_docs(sara, [doc("x", {"v": 1})])
        call_command("users", "delete", "sara", "--yes", stdout=StringIO())
        self.assertFalse(Doc.objects.filter(doc_id="x").exists())
        self.assertEqual(self.client.get("/api/me", **{"HTTP_AUTHORIZATION": "Bearer "}).status_code, 401)

    def test_email_sign_in(self):
        sara, auth = self.student()
        post = lambda path, email, pw: self.client.post(path, {"email": email, "password": pw}, content_type="application/json")
        self.assertEqual(post("/api/signup", "bad", "longenough").status_code, 400)
        self.assertEqual(post("/api/signup", "new@x.com", "short").status_code, 400)
        r = post("/api/signup", " New@X.com ", "longenough")
        self.assertEqual((r.status_code, r.json()["role"]), (200, "student"))
        me = self.client.get("/api/me", HTTP_AUTHORIZATION="Bearer " + r.json()["token"]).json()
        self.assertEqual(me["name"], "new@x.com")
        self.assertEqual(post("/api/signup", "new@x.com", "longenough").status_code, 400)  # taken
        self.assertEqual(post("/api/login", "new@x.com", "wrongpass").status_code, 400)
        self.assertEqual(post("/api/login", "nobody@x.com", "longenough").status_code, 400)
        r2 = post("/api/login", "NEW@x.com", "longenough")
        self.assertEqual(r2.status_code, 200)
        self.assertEqual(self.client.get("/api/me", HTTP_AUTHORIZATION="Bearer " + r.json()["token"]).status_code, 200)  # still signed in
        with mock.patch("getpass.getpass", return_value="longenough"):
            call_command("users", "login", "sara", "Sara@x.com", stdout=StringIO())
        self.assertEqual(post("/api/login", "sara@x.com", "longenough").json()["name"], "sara")
        call_command("users", "disable", "sara", stdout=StringIO())
        self.assertEqual(post("/api/login", "sara@x.com", "longenough").status_code, 400)
        from django.core.cache import cache
        cache.clear()
        for _ in range(10):
            post("/api/login", "new@x.com", "wrongpass")
        self.assertEqual(post("/api/login", "new@x.com", "longenough").status_code, 429)
        cache.clear()

    def test_isolation(self):
        sara, auth = self.student()
        # Same fixed ids on both sides never collide; each user pulls only their own docs.
        self.post("/api/sync", {"cursor": 0, "docs": [doc("settings", {"who": "owner"}, kind="settings", updated_at=10),
                                                      doc("c1", {"type": "basic", "question": "owner Q"})]})
        r = self.client.post("/api/sync", {"cursor": 0, "docs": [doc("settings", {"who": "sara"}, kind="settings", updated_at=5),
                                                                 doc("c1", {"type": "basic", "question": "sara Q"},
                                                                     updated_at=99)]},
                             content_type="application/json", **auth).json()
        self.assertEqual({d["id"]: d["data"] for d in r["docs"]},
                         {"settings": {"who": "sara"}, "c1": {"type": "basic", "question": "sara Q"}})
        mine = self.post("/api/sync", {"cursor": 0, "docs": []}).json()["docs"]
        self.assertEqual({d["id"]: d["data"].get("who") or d["data"].get("question") for d in mine},
                         {"settings": "owner", "c1": "owner Q"})
        # Media: knowing a file's hash doesn't give access to it.
        data = b"\x89PNG owner's diagram"
        name = hashlib.sha256(data).hexdigest() + ".png"
        self.assertEqual(self.client.put(f"/api/media/{name}", data, content_type="image/png", **AUTH).status_code, 200)
        self.assertEqual(self.client.get(f"/api/media/{name}", **auth).status_code, 404)
        self.assertEqual(self.client.get(f"/api/media/{name}", **AUTH).status_code, 200)
        self.assertEqual(self.client.put(f"/api/media/{name}", data, content_type="image/png", **auth).status_code, 200)
        self.assertEqual(self.client.get(f"/api/media/{name}", **auth).status_code, 200)  # uploaded it herself
        # Export holds only the caller's cards.
        self.assertEqual([c["question"] for c in self.client.get("/api/export", **auth).json()["cards"]], ["sara Q"])
        # AI endpoints read only the caller's cards (dedupe list, card text).
        with mock.patch("core.ai._create", return_value=message({"cards": [], "retag": []})) as create:
            self.client.post("/api/ai/generate", {"topic": "x", "count": 1}, content_type="application/json", **auth)
        listed = create.call_args.kwargs["messages"][0]["content"][0]["text"]
        self.assertIn("sara Q", listed)
        self.assertNotIn("owner Q", listed)
        self.assertEqual(AiCall.objects.get().user, sara)

    def test_budget_cap(self):
        sara, auth = self.student(cap="0.05")
        AiCall.objects.create(user=sara, endpoint="generate", model="m", ok=True, cost_usd="0.049")
        AiCall.objects.create(user=self.owner, endpoint="generate", model="m", ok=True, cost_usd="50")  # not hers
        with mock.patch("core.ai._create", return_value=message({"reply": "ok"})):
            ok = self.client.post("/api/ai/explain", {"card": {"question": "Q"}}, content_type="application/json", **auth)
        self.assertEqual(ok.status_code, 200)  # $0.049 + this call's cost (tiny) was under the cap when it started
        AiCall.objects.create(user=sara, endpoint="generate", model="m", ok=True, cost_usd="0.01")
        r = self.client.post("/api/ai/explain", {"card": {"question": "Q"}}, content_type="application/json", **auth)
        self.assertEqual(r.status_code, 402)
        self.assertIn("budget", r.json()["error"])
        me = self.client.get("/api/me", **auth).json()
        self.assertEqual(me["remaining_usd"], 0.0)
        with mock.patch("core.ai._create", return_value=message({"reply": "ok"})):  # the owner has no cap
            self.assertEqual(self.post("/api/ai/explain", {"card": {"question": "Q"}}).status_code, 200)

    # ---------- media ----------

    def test_media(self):
        data = b"\x89PNG fake image bytes"
        name = hashlib.sha256(data).hexdigest() + ".png"
        url = f"/api/media/{name}"
        self.assertEqual(self.client.get(url, **AUTH).status_code, 404)
        self.assertEqual(self.client.put(url, b"other bytes", content_type="image/png", **AUTH).status_code, 400)
        self.assertEqual(self.client.put(url, data, content_type="image/png", **AUTH).status_code, 200)
        self.assertEqual(self.client.put(url, data, content_type="image/png", **AUTH).status_code, 200)  # idempotent
        r = self.client.get(url, **AUTH)
        self.assertEqual((r.status_code, r["Content-Type"]), (200, "image/png"))
        self.assertEqual(b"".join(r.streaming_content), data)
        self.assertEqual(self.client.put("/api/media/abc.png", data, content_type="image/png", **AUTH).status_code, 400)
        self.assertEqual(self.client.get(f"/api/media/{name}%0A", **AUTH).status_code, 400)

    # ---------- import / export ----------

    def test_app_release(self):
        self.assertEqual(self.client.get("/api/app/latest", **AUTH).status_code, 404)
        release = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, release)
        (release / "latest.json").write_text('{"version_code": 3, "version_name": "1.2.0", "sha256": "ab"}')
        (release / "certdeck.apk").write_bytes(b"PK apk")
        with override_settings(CERTDECK_RELEASE_DIR=release):
            self.assertEqual(self.client.get("/api/app/latest").status_code, 401)
            self.assertEqual(self.client.get("/api/app/latest", **AUTH).json()["version_code"], 3)
            r = self.client.get("/api/app/apk", **AUTH)
            self.assertEqual((r["Content-Type"], b"".join(r.streaming_content)),
                             ("application/vnd.android.package-archive", b"PK apk"))

    def test_import_export_roundtrip(self):
        example = json.loads(EXAMPLE.read_text())
        r = self.post("/api/import", example)
        self.assertEqual(r.json(), {"imported": len(example["cards"])})
        save_docs(self.owner, [doc("DVA-C02", {"code": "DVA-C02", "name": "Dev", "domains": [{"id": "1", "name": "Dev", "weight": 1}]},
                       kind="cert")])

        out = self.client.get("/api/export", **AUTH).json()
        schema = json.loads(settings.CARDS_SCHEMA_PATH.read_text())
        jsonschema.Draft202012Validator(schema).validate(out)
        self.assertEqual(out["media"], example["media"])
        self.assertEqual(out["certs"][0]["code"], "DVA-C02")
        exported = {c["id"]: c for c in out["cards"]}
        for card in example["cards"]:
            self.assertEqual({k: exported[card["id"]][k] for k in card}, card)

        bad = dict(example, format="anki")
        self.assertEqual(self.post("/api/import", bad).status_code, 400)
        bad = dict(example, media={"0" * 64 + ".png": base64.b64encode(b"x").decode()})
        self.assertIn("sha256", self.post("/api/import", bad).json()["error"])
        r = self.post("/api/import", {"format": "certdeck", "version": 1, "cards": [{"type": "basic", "question": "Q"}]})
        self.assertEqual(r.json(), {"imported": 1})

    # ---------- AI ----------

    def test_generate(self):
        save_docs(self.owner, [doc("old1", {"type": "basic", "question": "What is the maximum execution time of an AWS Lambda function?",
                                "answer": "15 min", "certs": {"SAA-C03": "3"}})])
        payload = {
            "cards": [
                ai_card(type="mcq", question="A team needs sub-millisecond session reads. Which service?",
                        options=["DynamoDB", "ElastiCache", "S3", "RDS"], correct=[1],
                        option_explanations=["ms", "yes", "slow", "slow"],
                        certs=[{"cert": "DVA-C02", "domain": "1"}, {"cert": "SAA-C03", "domain": "3"}]),
                ai_card(question="what is the maximum execution time of an AWS lambda function", answer="15m"),
                ai_card(type="mcq", question="Broken", options=["a", "b"], correct=[7], option_explanations=["a", "b"]),
                ai_card(type="cloze", question="No blanks here"),
                ai_card(type="typed", question="CLI to assume a role?", answer="aws sts assume-role",
                        certs=[{"cert": "DVA-C02", "domain": "2"}, {"cert": "XYZ", "domain": "1"}]),
                ai_card(certs=[{"cert": "DVA-C02", "domain": "9"}]),
            ],
            "retag": [{"card_id": "old1", "cert": "DVA-C02", "domain": "1"},
                      {"card_id": "missing", "cert": "DVA-C02", "domain": "1"},
                      {"card_id": "old1", "cert": "DVA-C02", "domain": "9"}],
        }
        pdf = base64.b64encode(b"%PDF-1.4 notes").decode()
        with mock.patch("core.ai._create", return_value=message(payload)) as create:
            r = self.post("/api/ai/generate", {"cert": "DVA-C02", "domain": "1", "topic": "lambda", "count": 10,
                                               "files": [{"name": "n.pdf", "media_type": "application/pdf", "data": pdf}]})
        self.assertEqual(r.status_code, 200, r.content)
        body = r.json()
        self.assertEqual(body["skipped_duplicates"], 1)
        self.assertEqual(body["dropped_invalid"], 3)
        self.assertEqual(body["retag"], [{"card_id": "old1", "cert": "DVA-C02", "domain": "1"}])
        self.assertEqual(len(body["cards"]), 2)
        mcq, typed = body["cards"]
        self.assertEqual(mcq["certs"], {"DVA-C02": "1", "SAA-C03": "3"})
        self.assertEqual(typed["certs"], {"DVA-C02": "2"})
        self.assertTrue(mcq["source"].startswith("ai:DVA-C02 d1 "))
        stored = Doc.objects.get(doc_id=mcq["id"])
        self.assertEqual(stored.kind, "card")
        self.assertTrue(stored.data["new"])
        self.assertNotIn("fsrs", stored.data)
        self.assertEqual(Doc.objects.get(doc_id="old1").data["certs"], {"SAA-C03": "3"})  # server never retags itself

        kw = create.call_args.kwargs
        self.assertEqual(kw["model"], "claude-opus-5-5")
        self.assertEqual(kw["output_config"]["effort"], "medium")
        self.assertEqual(kw["output_config"]["format"]["type"], "json_schema")
        self.assertNotIn("thinking", kw)
        self.assertEqual(len(kw["system"]), 1)  # one stable, cached prefix: prompt + certs + official guide
        self.assertEqual(kw["system"][0]["cache_control"], {"type": "ephemeral"})
        self.assertIn("Develop code for AWS Lambda", kw["system"][0]["text"])
        self.assertNotIn("old1", kw["system"][0]["text"])  # the changing card list stays out of the cached prefix
        content = kw["messages"][0]["content"]
        self.assertEqual(content[0]["type"], "document")
        self.assertIn("old1 | SAA-C03:3 | What is the maximum", content[1]["text"])

        call = AiCall.objects.get()
        self.assertEqual((call.endpoint, call.ok, call.input_tokens, call.cache_read_tokens), ("generate", True, 100, 10))
        # Opus 5.5: 100 in x $4 + 5 cache writes x $5 + 10 cache reads x $0.20 + 50 out x $20, per MTok
        self.assertAlmostEqual(float(call.cost_usd), (100 * 4 + 5 * 5 + 10 * 0.2 + 50 * 20) / 1e6)
        usage = self.client.get("/api/usage", **AUTH).json()
        self.assertEqual((usage["calls"], usage["batch_calls"]), (1, 0))
        self.assertAlmostEqual(usage["usd"], float(call.cost_usd))
        self.assertAlmostEqual(usage["by_endpoint"]["generate"], float(call.cost_usd))

    def test_background_generate(self):
        payload = {"cards": [ai_card(question="What does SQS long polling reduce?", answer="Empty receives")],
                   "retag": []}
        batches = mock.MagicMock()
        batches.create.return_value = NS(id="msgbatch_1")
        with mock.patch("core.ai._batches", return_value=batches):
            r = self.post("/api/ai/generate", {"cert": "DVA-C02", "topic": "sqs", "count": 5, "background": True})
            self.assertEqual(r.status_code, 200, r.content)
            job = r.json()["job"]
            self.assertEqual((job["status"], job["batch_id"], job["label"]), ("queued", "msgbatch_1", "sqs"))
            req = batches.create.call_args.kwargs["requests"][0]
            self.assertEqual(req["custom_id"], job["id"])
            self.assertEqual(req["params"]["model"], "claude-opus-5-5")
            self.assertNotIn("extra_body", req["params"])  # no refusal fallback on the Batch API
            self.assertFalse(Doc.objects.filter(kind="card").exists())

            batches.retrieve.return_value = NS(processing_status="in_progress")
            call_command("poll_jobs")
            self.assertEqual(Doc.objects.get(doc_id=job["id"]).data["status"], "queued")

            batches.retrieve.return_value = NS(processing_status="ended")
            batches.results.return_value = iter([NS(custom_id=job["id"],
                                                    result=NS(type="succeeded", message=message(payload)))])
            call_command("poll_jobs", stdout=StringIO())
        done = Doc.objects.get(doc_id=job["id"]).data
        self.assertEqual((done["status"], done["added"], done["retag"]), ("done", 1, []))
        self.assertEqual(Doc.objects.filter(kind="card").count(), 1)
        call = AiCall.objects.get()
        self.assertTrue(call.batch)
        self.assertAlmostEqual(float(call.cost_usd), (100 * 4 + 5 * 5 + 10 * 0.2 + 50 * 20) / 1e6 / 2, places=6)

    def test_diagram_dot_is_escaped(self):
        from core import diagram
        dot = diagram.to_dot({"title": 'x" image="/etc/passwd', "groups": [
            {"id": "a", "label": "A", "kind": "vpc", "parent": "b"}, {"id": "b", "label": "B", "kind": "nope", "parent": "a"}],
            "nodes": [{"id": "n", "label": 'q"] x [image="/etc/hostname"', "icon": "../../etc/passwd", "group": "a"}],
            "edges": [{"source": "n", "target": "missing"}], "table": {"columns": ["<b>", "x"], "rows": [["<TD>", "&"]]}})
        outside_strings = re.sub(r'"(?:[^"\\]|\\.)*"', '""', dot)  # what's left can only be DOT syntax
        self.assertNotIn("image", outside_strings)  # labels can't add attributes; unknown icon -> no file reference
        self.assertNotIn("/etc/", outside_strings)
        self.assertNotIn("->", dot)  # edge to a missing node dropped
        self.assertIn("&lt;TD&gt;", dot)

    @unittest.skipUnless(shutil.which("dot"), "needs Graphviz")
    @override_settings(ANTHROPIC_API_KEY="test-key")
    def test_diagrams_job(self):
        save_docs(self.owner, [doc("a", {"type": "basic", "question": "Where does an EBS volume live?", "answer": "One AZ"}),
                   doc("b", {"type": "basic", "question": "SSH port?", "answer": "22"}),
                   doc("occ", {"type": "occlusion", "question": "?", "image": "x.png", "masks": []}),
                   doc("pic", {"type": "basic", "question": "?", "answer": "!", "answer_images": ["y.png"]}),
                   doc("fresh", {"type": "basic", "question": "?", "answer": "!"}, updated_at=now_ms())])
        spec = {"title": "EBS lives in one AZ", "direction": "TB",
                "groups": [{"id": "az", "label": "us-east-1a", "kind": "az", "parent": None}],
                "nodes": [{"id": "i", "label": "EC2", "icon": "aws/compute/ec2", "group": "az", "highlight": False},
                          {"id": "v", "label": "EBS volume", "icon": "aws/storage/elastic-block-store-ebs-volume",
                           "group": "az", "highlight": True}],
                "edges": [{"source": "v", "target": "i", "label": "attached", "dashed": False, "both": False}],
                "table": None}
        batches = mock.MagicMock()
        batches.create.return_value = NS(id="msgbatch_d")
        with mock.patch("core.ai._batches", return_value=batches):
            call_command("poll_jobs", stdout=StringIO())
            job = Doc.objects.get(kind="job")
            self.assertEqual((job.data["task"], job.data["card_ids"]), ("diagrams", ["a", "b"]))
            prompt = batches.create.call_args.kwargs["requests"][0]["params"]
            self.assertIn("aws/compute: ", prompt["system"][0]["text"])
            self.assertIn('<card id="a" type="basic">', prompt["messages"][0]["content"])

            batches.retrieve.return_value = NS(processing_status="ended")
            payload = {"diagrams": [{"card_id": "a", "diagram": spec}, {"card_id": "zzz", "diagram": spec}]}
            batches.results.return_value = iter([NS(custom_id=job.doc_id, result=NS(type="succeeded", message=message(payload)))])
            call_command("poll_jobs", stdout=StringIO())  # finishes the job; a, b are covered now, so nothing new queues
        done = Doc.objects.get(kind="job").data
        self.assertEqual((done["status"], done["added"], [d["card_id"] for d in done["diagrams"]]), ("done", 1, ["a"]))
        png = (settings.CERTDECK_MEDIA_DIR / done["diagrams"][0]["image"]).read_bytes()
        self.assertTrue(png.startswith(b"\x89PNG"))
        self.assertEqual(AiCall.objects.get().endpoint, "diagrams")

    def test_relevant_cards(self):
        from core.ai import MAX_EXISTING_LINES, relevant_cards
        mk = lambda i, certs, q="unrelated words here": Doc(doc_id=i, kind="card", seq=0, updated_at=0,
                                                            data={"certs": certs, "question": q, "created_at": 0})
        cards = [mk(f"x{i}", {"SAA-C03": "1"}) for i in range(MAX_EXISTING_LINES)] + [
            mk("other_domain", {"DVA-C02": "2"}), mk("same_domain", {"DVA-C02": "1"}),
            mk("overlap", {"SAA-C03": "1"}, "How does SQS visibility timeout work?")]
        shown = [d.doc_id for d in relevant_cards(cards, "DVA-C02", "1", "SQS visibility timeout")]
        self.assertEqual(shown[:3], ["same_domain", "overlap", "other_domain"])
        self.assertEqual(len(shown), MAX_EXISTING_LINES)

    def test_explain(self):
        card = {"id": "c1", "type": "mcq", "question": "Q?", "options": ["a", "b", "c"], "correct": [0]}
        with mock.patch("core.ai._create", return_value=message({"reply": "Because **a**."})) as create:
            r = self.post("/api/ai/explain", {"card": card, "messages": [
                {"role": "user", "text": "why?"}, {"role": "assistant", "text": "..."}, {"role": "user", "text": "more"}]})
        self.assertEqual(r.json(), {"reply": "Because **a**."})
        self.assertEqual([m["role"] for m in create.call_args.kwargs["messages"]], ["user", "assistant", "user"])

        fill = {"explanation": "A is right.", "option_explanations": ["right", "wrong", "wrong"]}
        with mock.patch("core.ai._create", return_value=message(fill)):
            self.assertEqual(self.post("/api/ai/explain", {"card": card, "mode": "fill"}).json(), fill)
        with mock.patch("core.ai._create", return_value=message(dict(fill, option_explanations=["x"]))):
            self.assertEqual(self.post("/api/ai/explain", {"card": card, "mode": "fill"}).status_code, 502)
        self.assertEqual(AiCall.objects.count(), 3)

    def test_variants_leech(self):
        original = {"type": "basic", "question": "Lambda max timeout?", "answer": "15 min",
                    "certs": {"DVA-C02": "1"}, "tags": ["lambda"]}
        save_docs(self.owner, [doc("orig", original, updated_at=5)])
        payload = {"variants": [ai_card(question="A job runs 20 minutes. Can Lambda run it?", answer="No, max 15 min"),
                                ai_card(type="typed", question="Max Lambda timeout in seconds?", answer="900",
                                        certs=[{"cert": "SAA-C03", "domain": "3"}])],
                   "explanation": "Think of it as a kitchen timer.", "learn": "- 900 s max",
                   "videos": [{"title": "Lambda limits", "query": "aws lambda timeout limit"}]}
        with mock.patch("core.ai._create", return_value=message(payload)):
            r = self.post("/api/ai/variants", {"card": dict(original, id="orig"), "count": 3, "leech": True})
        body = r.json()
        self.assertEqual(len(body["variants"]), 2)
        for v in body["variants"]:
            self.assertEqual((v["variant_of"], v["certs"]), ("orig", {"DVA-C02": "1"}))
            self.assertTrue(Doc.objects.filter(doc_id=v["id"], kind="card").exists())
        self.assertEqual(body["explanation"], "Think of it as a kitchen timer.")
        self.assertEqual(body["videos"], [{"title": "Lambda limits",
                                           "url": "https://www.youtube.com/results?search_query=aws+lambda+timeout+limit"}])
        self.assertEqual(Doc.objects.get(doc_id="orig").updated_at, 5)  # original untouched

    def test_analyze(self):
        now = now_ms()
        cards = []
        for i in range(60):
            fsrs = {"state": 2, "stability": 1 + i, "difficulty": 5, "due": now, "last_review": now - 3 * DAY}
            cards.append(doc(f"c{i}", {"type": "basic", "question": f"Q{i}", "certs": {"DVA-C02": "1" if i < 55 else "2"},
                                       "fsrs": fsrs, "lapses": i % 4, "misconception": i == 3, "leech": i == 7}))
        cards.append(doc("new1", {"type": "basic", "question": "N", "certs": {"DVA-C02": "2"}, "new": True}))
        reviews = [doc(f"r{i}", {"card_id": f"c{i % 60}", "ts": now - DAY, "rating": 1 if i % 3 == 0 else 3,
                                 "confidence": ["guess", "unsure", "sure"][i % 3], "correct": i % 3 != 0,
                                 "misconception": i % 3 == 0 and i % 2 == 0, "duration_ms": 4000, "source": "study"},
                       kind="review") for i in range(120)]
        exam = doc("e1", {"cert": "DVA-C02", "finished_at": now, "score_pct": 70, "passed": False, "questions": [
            {"card_id": "c1", "domain": "1", "correct": True}, {"card_id": "c56", "domain": "2", "correct": False}]},
                   kind="exam")
        cert = doc("DVA-C02", {"code": "DVA-C02", "name": "Dev", "exam_date": "2030-01-01", "active": True,
                               "domains": [{"id": "1", "name": "Dev", "weight": 0.5}, {"id": "2", "name": "Sec", "weight": 0.5}]},
                   kind="cert")
        save_docs(self.owner, cards + reviews + [exam, cert])

        ov = lambda **kw: {"card_ids": [], "domain": None, "kind": "advance", "days": None, "priority": None,
                           "reason": "weak", **kw}
        payload = {
            "summary": "Weak in security.",
            "weak_areas": [{"rank": 2, "domain": "1", "topic": "x", "diagnosis": "d"},
                           {"rank": 1, "domain": "2", "topic": "iam", "diagnosis": "d"}],
            "actions": [{"label": "Generate 15 cards on IAM", "domain": "2", "topic": "IAM", "count": 500}],
            "videos": [{"title": "IAM", "query": "aws iam policy evaluation"}],
            "overrides": [
                ov(card_ids=["c3", "nope"], days=-100),          # advance, clamped to -30
                ov(card_ids=["c4"], kind="postpone", days=100),  # clamped to 30
                ov(card_ids=["c5"], kind="priority", priority=5),  # clamped to 2
                ov(card_ids=["c6"]),                             # due now
                ov(domain="1"),                                  # expands to <= 50 cards, weakest first
                ov(card_ids=["nope"]),                           # dropped: unknown ids
                ov(card_ids=["c8"], reason=""),                  # dropped: no reason
            ] + [ov(card_ids=[f"c{i}"], kind="priority", priority=-1) for i in range(10, 20)],
        }
        with mock.patch("core.ai._create", return_value=message(payload)) as create:
            r = self.post("/api/ai/analyze", {"cert": "DVA-C02"})
        self.assertEqual(r.status_code, 200, r.content)
        body = r.json()

        sent = json.loads(create.call_args.kwargs["messages"][0]["content"].split("\n", 1)[1])
        d1 = sent["domains"][0]
        self.assertEqual((d1["id"], d1["cards"], d1["reviews"]), ("1", 55, 110))
        self.assertIsNotNone(d1["mean_retrievability"])
        self.assertEqual(d1["confidence"]["guess"]["accuracy_pct"], 0.0)
        self.assertEqual(sent["domains"][1]["new"], 1)
        self.assertEqual(sent["domains"][1]["exam_questions"], 1)
        self.assertIsNotNone(sent["days_until_exam"])
        self.assertEqual(sent["worst_cards"][0]["id"], "c3")
        self.assertLessEqual(len(sent["worst_cards"]), 25)
        self.assertEqual(sent["study_habits"]["days_active_last_7"], 1)  # the study habits go to the coach too
        self.assertIn("avg_seconds_per_review", sent["study_habits"])

        overrides = body["overrides"]
        self.assertEqual(len(overrides), 10)
        self.assertEqual((overrides[0]["card_ids"], overrides[0]["due_shift_days"]), (["c3"], -30))
        self.assertEqual(overrides[1]["due_shift_days"], 30)
        self.assertEqual(overrides[2]["priority"], 2)
        self.assertTrue(overrides[3]["due_now"])
        domain_ids = overrides[4]["card_ids"]
        self.assertEqual(len(domain_ids), 50)
        self.assertEqual(domain_ids[:3], ["c0", "c1", "c2"])  # lowest stability -> lowest retrievability first
        for o in overrides:
            self.assertEqual((o["applied_at"], o["reverted_at"], o["before"]), (None, None, {}))
            self.assertEqual(Doc.objects.get(doc_id=o["id"]).kind, "override")
        analysis = Doc.objects.get(doc_id=body["id"])
        self.assertEqual(analysis.data["override_ids"], [o["id"] for o in overrides])
        self.assertEqual(body["actions"][0], {"label": "Generate 15 cards on IAM", "cert": "DVA-C02", "domain": "2",
                                              "topic": "IAM", "count": 50})
        self.assertEqual(body["weak_areas"][0]["rank"], 1)
        self.assertTrue(body["videos"][0]["url"].endswith("aws+iam+policy+evaluation"))

    def test_ai_errors(self):
        card = {"card": {"type": "basic", "question": "Q"}}
        request = httpx2.Request("POST", "https://api.anthropic.com/v1/messages")
        cases = [
            (anthropic.APITimeoutError(request=request), 503),
            (anthropic.RateLimitError("slow down", response=httpx2.Response(429, request=request), body=None), 429),
            (anthropic.InternalServerError("boom", response=httpx2.Response(500, request=request), body=None), 502),
            (message({"reply": "x"}, stop_reason="refusal"), 502),
            (NS(stop_reason="end_turn", content=[NS(type="text", text="not json")], usage=None), 502),
        ]
        for outcome, status in cases:
            kw = {"side_effect": outcome} if isinstance(outcome, Exception) else {"return_value": outcome}
            with mock.patch("core.ai._create", **kw):
                r = self.post("/api/ai/explain", card)
            self.assertEqual(r.status_code, status, outcome)
            self.assertIn("error", r.json())
        r = self.post("/api/ai/explain", card)  # real seam, no API key configured
        self.assertEqual(r.status_code, 503)
        self.assertEqual(AiCall.objects.filter(ok=False).count(), len(cases) + 1)

    # ---------- metrics ----------

    def test_metrics(self):
        t0 = now_ms() - 10 * DAY
        rv = lambda i, cid, ts, ok, conf="sure", dur=4000: doc(
            f"m{i}", {"card_id": cid, "ts": ts, "correct": ok, "confidence": conf, "duration_ms": dur,
                      "misconception": conf == "sure" and not ok}, kind="review")
        save_docs(self.owner, [
            rv(1, "a", t0, True), rv(2, "b", t0 + 60_000, False),            # session 1 (day 0)
            rv(3, "a", t0 + 8 * DAY, True), rv(4, "b", t0 + 8 * DAY + 60_000, False, "unsure"),  # session 2, 8d after
        ])
        m = self.client.get("/api/metrics", **AUTH).json()
        self.assertEqual((m["reviews"], m["sessions"], m["days_active_last_7"]), (4, 2, 1))
        self.assertEqual(m["recall_by_days_since_last_review"]["7-14d"], {"reviews": 2, "accuracy_pct": 50.0})
        self.assertEqual(m["calibration"]["sure"]["misconception_rate_pct"], 33.3)
        self.assertEqual(m["avg_session_reviews"], 2.0)
        self.assertIsNone(m["session_completion_pct"])
        save_docs(self.owner, [doc(f"s{i}", {"started_at": now_ms() - i * 1000, "completed": i < 3}, kind="session")
                               for i in range(4)])
        save_docs(self.owner, [doc("m9", {"card_id": "z", "ts": t0 + 9 * DAY, "correct": True, "confidence": "unsure",
                                          "study_first": True}, kind="review")])
        m = self.client.get("/api/metrics", **AUTH).json()
        self.assertEqual((m["session_completion_pct"], m["sessions_logged_last_28"]), (75.0, 4))
        self.assertEqual(m["calibration"]["unsure"]["reviews"], 1)  # the study-first review is not counted

        student = Account.objects.create(name="stu", role="student")
        Token.objects.create(account=student, hash=token_hash("stu-token"))
        stu = {"HTTP_AUTHORIZATION": "Bearer stu-token"}
        self.assertEqual(self.client.get("/api/metrics", **stu).json()["reviews"], 0)
        self.assertEqual(self.client.get("/api/metrics?user=" + self.owner.name, **stu).status_code, 403)
        self.assertEqual(self.client.get("/api/metrics?user=stu", **AUTH).json()["reviews"], 0)
        self.assertEqual(self.client.get("/api/metrics?user=nobody", **AUTH).status_code, 404)

    # ---------- FSRS ----------

    def _reviews(self, simulate):
        """1120 review docs: 160 cards x 7 reviews at fixed day offsets. simulate=False: random ratings (no signal);
        True: recall sampled from FSRS with slower-forgetting parameters than the defaults (a learnable signal)."""
        from datetime import datetime, timezone
        from fsrs import Card, Rating, Scheduler
        from fsrs.scheduler import DEFAULT_PARAMETERS
        rng = random.Random(1)
        true = Scheduler(parameters=[w * 3 if i < 4 else w for i, w in enumerate(DEFAULT_PARAMETERS)], enable_fuzzing=False)
        start, reviews = now_ms() - 400 * DAY, []
        for c in range(160):
            card = Card(card_id=c)
            for k, offset in enumerate([0, 1, 3, 8, 20, 45, 90]):
                ts = start + (c + offset) * DAY
                if simulate:
                    when = datetime.fromtimestamp(ts / 1000, timezone.utc)
                    ok = k == 0 or rng.random() < true.get_card_retrievability(card, when)
                    rating = 3 if ok else 1
                    card = true.review_card(card, Rating(rating), when)[0]
                else:
                    rating = rng.choice([1, 3, 3, 3, 4]) if k else rng.choice([1, 2, 3])
                reviews.append(doc(f"r{c}-{k}", {"card_id": f"card-{c}", "ts": ts, "rating": rating, "duration_ms": 5000}, kind="review"))
        return reviews

    def test_optimize(self):
        reviews = self._reviews(simulate=True)
        save_docs(self.owner, reviews[:100])
        out = StringIO()
        call_command("optimize_fsrs", stdout=out)
        self.assertIsNone(json.loads(out.getvalue().split(": ", 1)[1])["optimized_at"])  # too few reviews: defaults, nothing written
        self.assertFalse(Doc.objects.filter(doc_id="fsrs_params").exists())

        save_docs(self.owner, reviews)
        self.assertGreaterEqual(len(reviews), MIN_REVIEWS)
        body = self.post("/api/fsrs/optimize", {}).json()
        self.assertEqual(len(body["parameters"]), 21)
        self.assertEqual(body["review_count"], 1120)
        self.assertIsNotNone(body["optimized_at"])  # the fit beat the defaults on the held-out 20%
        self.assertEqual(Doc.objects.get(doc_id="fsrs_params").data, body)

    def test_optimize_keeps_params_when_fit_is_not_better(self):
        from fsrs.scheduler import DEFAULT_PARAMETERS
        save_docs(self.owner, self._reviews(simulate=True))
        worse = [w * 0.2 if i < 4 else w for i, w in enumerate(DEFAULT_PARAMETERS)]  # forgets much faster than this data does
        with mock.patch("fsrs.Optimizer") as opt:
            opt.return_value.compute_optimal_parameters.return_value = worse
            body = self.post("/api/fsrs/optimize", {}).json()
        self.assertIsNone(body["optimized_at"])
        self.assertEqual(body["parameters"], list(DEFAULT_PARAMETERS))
        self.assertFalse(Doc.objects.filter(doc_id="fsrs_params").exists())


@override_settings(ANTHROPIC_API_KEY="")
class AutopilotTests(TestCase):
    def setUp(self):
        from core import autopilot
        self.ap = autopilot
        self.user = Account.objects.get(role="owner")
        self.now = now_ms()

    def reviews(self, days_ago, per_day=1, card="c", ok=True, start=0):
        """One review doc per (day, k); each a different card unless [card] is given a fixed id."""
        out = []
        for i, d in enumerate(days_ago):
            for k in range(per_day):
                out.append(doc(f"a{start}-{i}-{k}", {"card_id": card if card != "c" else f"c{start}-{i}-{k}", "ts": self.now - d * DAY + k * 60_000,
                                                  "correct": ok, "confidence": "sure", "rating": 3 if ok else 1, "duration_ms": 4000},
                               kind="review"))
        return out

    def autopilot_doc(self, data, updated_days_ago):
        save_docs(self.user, [doc("autopilot", {**self.ap.blank(), **data, "updated_at": self.now - updated_days_ago * DAY},
                                  kind="autopilot")])

    def test_rules(self):
        save_docs(self.user, self.reviews(range(30, 10, -1), per_day=2))  # 40 reviews, nothing in the last 10 days
        low = self.ap.tune(self.user, self.now)
        self.assertEqual((low["session_minutes"], low["new_per_day"]), (5, 15))  # one step down, x0.75
        self.assertIn("few study days", low["reason"])

        Doc.objects.filter(kind="review").delete()
        save_docs(self.user, self.reviews(range(0, 6), per_day=6, start=1))  # studied 6 of the last 7 days
        high = self.ap.tune(self.user, self.now)
        self.assertEqual((high["session_minutes"], high["new_per_day"]), (10, 24))  # x1.2

        self.autopilot_doc({"new_per_day": 39, "retention_adj": 0.03}, updated_days_ago=8)
        high = self.ap.tune(self.user, self.now)
        self.assertEqual(high["new_per_day"], 40)  # capped
        self.assertEqual(high["retention_adj"], 0.03)

    def test_a_pick_made_after_the_last_change_is_the_starting_point(self):
        save_docs(self.user, self.reviews(range(0, 6), per_day=6, start=1))  # studied most days: x1.2
        self.autopilot_doc({"new_per_day": 10}, updated_days_ago=8)
        save_docs(self.user, [doc("settings", {"new_per_day": 30, "new_per_day_set_at": self.now - DAY}, kind="settings")])
        self.assertEqual(self.ap.tune(self.user, self.now)["new_per_day"], 36)  # from the picked 30, not the old 10
        save_docs(self.user, [doc("settings", {"new_per_day": 30, "new_per_day_set_at": self.now - 20 * DAY}, kind="settings", updated_at=2)])
        self.assertEqual(self.ap.tune(self.user, self.now)["new_per_day"], 12)  # an old pick no longer overrides

    def test_long_gap_recall_moves_retention(self):
        first = [doc(f"f{i}", {"card_id": f"g{i}", "ts": self.now - 40 * DAY, "correct": True, "confidence": "sure", "rating": 3}, kind="review") for i in range(35)]
        second = [doc(f"s{i}", {"card_id": f"g{i}", "ts": self.now - 10 * DAY, "correct": i < 5, "confidence": "sure", "rating": 3 if i < 5 else 1}, kind="review") for i in range(35)]
        save_docs(self.user, first + second)  # 35 reviews 30 days after the previous one, 14% right
        self.assertEqual(self.ap.tune(self.user, self.now)["retention_adj"], 0.02)

    def test_cooldown_and_revert_on_drop(self):
        save_docs(self.user, self.reviews(range(30, 10, -1), per_day=2))
        prev = {"session_minutes": 15, "new_per_day": 30, "retention_adj": 0.0, "load_factor": 1.0, "reason": "before", "updated_at": 1}
        self.autopilot_doc({"session_minutes": 5, "new_per_day": 10, "history": [prev], "snapshot": {"days_active_last_7": 6, "recall_14d": None, "recall_7_14d": None}}, updated_days_ago=2)
        self.assertIsNone(self.ap.tune(self.user, self.now))  # changed 2 days ago: too early to judge or change again

        self.autopilot_doc({"session_minutes": 5, "new_per_day": 10, "history": [prev], "snapshot": {"days_active_last_7": 6, "recall_14d": None, "recall_7_14d": None}}, updated_days_ago=8)
        out = self.ap.tune(self.user, self.now)  # 6 active days then, 0 now: a drop of 3+ days
        self.assertTrue(out["reverted"])
        self.assertEqual((out["session_minutes"], out["new_per_day"], out["history"]), (15, 30, []))
        self.assertTrue(out["reason"].startswith("Reverted"))

    def test_supervise_clamps_model_output_and_survives_budget(self):
        m = {"x": 1}
        proposal = {**self.ap.blank(), "retention_adj": 0.02, "reason": "rules"}
        wild = message({"retention_adj_delta": 5, "load_factor": 9, "reason": "go wild"})
        with mock.patch("core.ai._create", return_value=wild) as create:
            out = self.ap.supervise(self.user, m, proposal, self.now)
        self.assertEqual((out["retention_adj"], out["load_factor"]), (0.03, 1.2))  # 0.02 + 0.03 -> clamped to 0.03
        self.assertEqual(create.call_args.kwargs["model"], settings.CERTDECK_READ_MODEL)
        self.assertEqual(AiCall.objects.get(endpoint="autopilot").user, self.user)

        self.user.cap_usd = "0.001"
        self.user.save()
        with mock.patch("core.ai._create") as create:
            self.assertIs(self.ap.supervise(self.user, m, proposal, self.now), proposal)  # over budget: rules only
        create.assert_not_called()

    def test_run_saves_doc_and_skips_small_accounts(self):
        save_docs(self.user, self.reviews(range(0, 10), per_day=2))  # 20 reviews
        self.assertIsNone(self.ap.run(self.user, self.now, use_ai=False))
        self.assertFalse(Doc.objects.filter(kind="autopilot").exists())
        save_docs(self.user, self.reviews(range(0, 6), per_day=5, start=1))  # 50 reviews, 6 active days
        out = self.ap.run(self.user, self.now, use_ai=False)
        saved = Doc.objects.get(doc_id="autopilot", user=self.user).data
        self.assertEqual(saved, out)
        self.assertEqual((saved["new_per_day"], saved["history"][0]["new_per_day"]), (24, None))
        self.assertIsNone(self.ap.run(self.user, self.now, use_ai=False))  # weekly cooldown
        call_command("autopilot", "--no-ai", stdout=StringIO())

    def test_reteach_writes_two_cards_once(self):
        from core import reteach
        card = {"type": "basic", "question": "Q?", "answer": "A", "explanation": "E", "leech": True, "lapses": 6,
                "certs": {"DVA-C02": "1"}, "tags": ["lambda"], "course": "course-1", "section": "m/s1", "kp_ids": ["k1"]}
        save_docs(self.user, [doc("leech-1", card), doc("fine", {**card, "leech": False})])
        reply = message({"variants": [ai_card(question="Atomic?", answer="A1"), ai_card(question="X vs Y?", answer="A2")]})
        with mock.patch("core.ai._create", return_value=reply) as create:
            self.assertEqual(reteach.run(self.user, self.now), 2)
            self.assertEqual(reteach.run(self.user, self.now), 0)  # already re-taught: no second call
        self.assertEqual(create.call_count, 1)
        new = [d.data for d in Doc.objects.filter(kind="card") if d.data.get("variant_of") == "leech-1"]
        self.assertEqual(len(new), 2)
        self.assertEqual({(c["course"], c["section"], c["kp_ids"][0], c["new"]) for c in new}, {("course-1", "m/s1", "k1", True)})
        marker = Doc.objects.get(doc_id="reteach-leech-1").data
        self.assertEqual(len(marker["new_card_ids"]), 2)
        self.assertEqual(Doc.objects.get(doc_id="leech-1").data, card)  # the student's card doc is untouched
