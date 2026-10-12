import base64
import hashlib
import json
import random
import shutil
import tempfile
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

from core.models import AiCall, Doc, now_ms, save_docs
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


@override_settings(CERTDECK_API_TOKEN=TOKEN, ANTHROPIC_API_KEY="")
class ApiTests(TestCase):
    def setUp(self):
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
        self.assertEqual(Doc.objects.get(id="a").data, {"v": 1})

        r = self.post("/api/sync", {"cursor": cursor, "docs": [doc("a", {"v": 2}, updated_at=10, deleted=True)]}).json()
        self.assertEqual(r["docs"], [doc("a", {"v": 2}, updated_at=10, deleted=True)])  # equal timestamp wins
        self.assertGreater(r["cursor"], cursor)

        self.assertEqual(self.post("/api/sync", {"cursor": 0, "docs": [{"id": "x"}]}).status_code, 400)

    def test_sync_paging(self):
        save_docs([doc(f"d{i}", {"i": i}) for i in range(1005)])
        r = self.post("/api/sync", {"cursor": 0, "docs": []}).json()
        self.assertEqual(len(r["docs"]), 1000)
        self.assertTrue(r["more"])
        r2 = self.post("/api/sync", {"cursor": r["cursor"], "docs": []}).json()
        self.assertEqual(len(r2["docs"]), 5)
        self.assertFalse(r2["more"])
        ids = [d["id"] for d in r["docs"] + r2["docs"]]
        self.assertEqual(ids, [f"d{i}" for i in range(1005)])  # ordered by seq, nothing skipped

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

    def test_import_export_roundtrip(self):
        example = json.loads(EXAMPLE.read_text())
        r = self.post("/api/import", example)
        self.assertEqual(r.json(), {"imported": len(example["cards"])})
        save_docs([doc("DVA-C02", {"code": "DVA-C02", "name": "Dev", "domains": [{"id": "1", "name": "Dev", "weight": 1}]},
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
        save_docs([doc("old1", {"type": "basic", "question": "What is the maximum execution time of an AWS Lambda function?",
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
        stored = Doc.objects.get(id=mcq["id"])
        self.assertEqual(stored.kind, "card")
        self.assertTrue(stored.data["new"])
        self.assertNotIn("fsrs", stored.data)
        self.assertEqual(Doc.objects.get(id="old1").data["certs"], {"SAA-C03": "3"})  # server never retags itself

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
            self.assertEqual(Doc.objects.get(id=job["id"]).data["status"], "queued")

            batches.retrieve.return_value = NS(processing_status="ended")
            batches.results.return_value = iter([NS(custom_id=job["id"],
                                                    result=NS(type="succeeded", message=message(payload)))])
            call_command("poll_jobs", stdout=StringIO())
        done = Doc.objects.get(id=job["id"]).data
        self.assertEqual((done["status"], done["added"], done["retag"]), ("done", 1, []))
        self.assertEqual(Doc.objects.filter(kind="card").count(), 1)
        call = AiCall.objects.get()
        self.assertTrue(call.batch)
        self.assertAlmostEqual(float(call.cost_usd), (100 * 4 + 5 * 5 + 10 * 0.2 + 50 * 20) / 1e6 / 2, places=6)

    def test_relevant_cards(self):
        from core.ai import MAX_EXISTING_LINES, relevant_cards
        mk = lambda i, certs, q="unrelated words here": Doc(id=i, kind="card", seq=0, updated_at=0,
                                                            data={"certs": certs, "question": q, "created_at": 0})
        cards = [mk(f"x{i}", {"SAA-C03": "1"}) for i in range(MAX_EXISTING_LINES)] + [
            mk("other_domain", {"DVA-C02": "2"}), mk("same_domain", {"DVA-C02": "1"}),
            mk("overlap", {"SAA-C03": "1"}, "How does SQS visibility timeout work?")]
        shown = [d.id for d in relevant_cards(cards, "DVA-C02", "1", "SQS visibility timeout")]
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
        save_docs([doc("orig", original, updated_at=5)])
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
            self.assertTrue(Doc.objects.filter(id=v["id"], kind="card").exists())
        self.assertEqual(body["explanation"], "Think of it as a kitchen timer.")
        self.assertEqual(body["videos"], [{"title": "Lambda limits",
                                           "url": "https://www.youtube.com/results?search_query=aws+lambda+timeout+limit"}])
        self.assertEqual(Doc.objects.get(id="orig").updated_at, 5)  # original untouched

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
        save_docs(cards + reviews + [exam, cert])

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
            self.assertEqual(Doc.objects.get(id=o["id"]).kind, "override")
        analysis = Doc.objects.get(id=body["id"])
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

    # ---------- FSRS ----------

    def test_optimize(self):
        rng = random.Random(1)
        start, reviews = now_ms() - 400 * DAY, []
        for c in range(100):
            for k, offset in enumerate([0, 1, 3, 8, 20, 45, 90]):
                rating = rng.choice([1, 3, 3, 3, 4]) if k else rng.choice([1, 2, 3])
                reviews.append(doc(f"r{c}-{k}", {"card_id": f"card-{c}", "ts": start + (c + offset) * DAY,
                                                 "rating": rating, "duration_ms": 5000}, kind="review"))
        save_docs(reviews[:100])
        out = StringIO()
        call_command("optimize_fsrs", stdout=out)
        self.assertIsNone(json.loads(out.getvalue())["optimized_at"])  # too few reviews: defaults, nothing written
        self.assertFalse(Doc.objects.filter(id="fsrs_params").exists())

        save_docs(reviews)
        self.assertGreaterEqual(len(reviews), MIN_REVIEWS)
        body = self.post("/api/fsrs/optimize", {}).json()
        self.assertEqual(len(body["parameters"]), 21)
        self.assertEqual(body["review_count"], 700)
        self.assertEqual(Doc.objects.get(id="fsrs_params").data, body)
