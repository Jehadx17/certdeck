import hashlib
import io
import json
import re
import shutil
import tempfile
import uuid
from datetime import date, timedelta
from pathlib import Path
from types import SimpleNamespace as NS
from unittest import mock

from django.test import TestCase, override_settings

from core import college, ingest
from core.models import AiCall, Doc, Job, now_ms, save_docs
from core.tests import drain, make_account, message

from django.utils.timezone import now as tz_now

PAID = tz_now() + timedelta(days=30)


def pdf_bytes(pages=3, text="Page"):
    """A small real PDF (Pillow) with [pages] pages."""
    from PIL import Image, ImageDraw

    ims = []
    for i in range(pages):
        im = Image.new("RGB", (300, 200), "white")
        ImageDraw.Draw(im).text((20, 80), f"{text} {i + 1}", fill="black")
        ims.append(im)
    buf = io.BytesIO()
    ims[0].save(buf, "PDF", save_all=True, append_images=ims[1:])
    return buf.getvalue()


def fake_ai(request_kwargs_log=None):
    """Answers each college call by the prompt it was sent."""
    def create(**kw):
        if request_kwargs_log is not None:
            request_kwargs_log.append(kw)
        system = kw["system"][1]["text"]
        if system.startswith("You map the structure"):
            return message({"language": "en", "title": "Calculus notes", "sections": [
                {"title": "Course plan", "level": 1, "start": 1, "end": 1, "kind": "other"},
                {"title": "Chapter 5 Integration", "level": 1, "start": 2, "end": 3, "kind": "content"},
                {"title": "5.3 Substitution", "level": 2, "start": 3, "end": 3, "kind": "content"},
            ], "syllabus_pages": {"start": 1, "end": 1}})
        if system.startswith("You read a course syllabus"):
            return message({"course_name": "Calculus II", "course_code": "MATH106", "assessments": [
                {"kind": "quiz", "title": "Quiz 1", "weeks": "3-4", "date": None, "weight_pct": 5, "minutes": None,
                 "coverage": "Chapter 5", "format": "", "scope": ["{mid}/s2"]},
                {"kind": "final", "title": "Final Exam", "weeks": "16", "date": "2027-01-20", "weight_pct": 40,
                 "minutes": 120, "coverage": "All", "format": "written", "scope": ["bogus/s9"]}]})
        if system.startswith("You extract everything examinable"):
            return message({"points": [
                {"kind": "formula", "title": "Power rule", "content": "$\\int u^r du = \\frac{u^{r+1}}{r+1}+C$", "loc": 2, "emphasis": 3},
                {"kind": "example", "title": "Example 1", "content": "Evaluate $\\int_0^3 x^2 dx$ = 9", "loc": 3, "emphasis": 2},
                {"kind": "fact", "title": "Empty", "content": " ", "loc": 3, "emphasis": 0}]})
        if system.startswith("You rate flashcards"):
            n = len(re.findall(r"(?m)^\d+\. ", kw["messages"][0]["content"]))
            return message({"scores": [7] * n})
        if system.startswith("Score how likely"):
            n = len(re.findall(r"(?m)^\d+\. ", kw["messages"][0]["content"]))
            return message({"scores": [5] * n})
        if system.startswith("You write study cards"):
            text = kw["messages"][0]["content"]
            ids = [l[1:37] for l in text.split("\n") if l.startswith("[") and l[37:38] == "]"]
            base = dict(answer=None, options=None, correct=None, option_explanations=None, accepted=None, items=None,
                        code=None, answer_code=None, language=None, explanation="Because.", rubric=None, steps=None,
                        check=None, kp_ids=ids[:1], page=3, worked=False, similar_to=None, tags=["integration"])
            return message({"cards": [
                dict(base, type="problem", question="Evaluate $\\int_0^3 x^2\\,dx$.", answer="9", steps=["F = x^3/3", "9 - 0 = 9"],
                     rubric=[{"point": "antiderivative", "weight": 2}, {"point": "evaluate", "weight": 2}],
                     check={"kind": "numeric", "expr": "integrate(x**2, (x, 0, 3))", "value": "9", "var": None, "tolerance": None},
                     worked=True, kp_ids=ids[1:2] or ids[:1]),
                dict(base, type="problem", question="Wrong key", answer="10", steps=["..."],
                     check={"kind": "numeric", "expr": "integrate(x**2, (x, 0, 3))", "value": "10", "var": None, "tolerance": None}),
                dict(base, type="problem", question="No check", answer="42", steps=["..."]),
                dict(base, type="short", question="State the power rule.", answer="$\\int u^r du = ...$",
                     rubric=[{"point": "formula", "weight": 1}]),
                dict(base, type="cloze", question="The power rule needs $r \\neq$ {{-1}}."),
            ]})
        if system.startswith("You check a draft set"):  # the review keeps the drafts as they are
            return message({"cards": json.loads(kw["messages"][0]["content"].split("Draft cards (JSON):\n", 1)[1])})
        if system.startswith("From the knowledge points"):
            return message({"summary": "## Ch 5\n- substitution (p. 3)", "facts": "- power rule", "formulas": None})
        if system.startswith("You grade a student's answer"):
            return message({"points": [{"point": "antiderivative", "met": True, "note": "ok"}], "score": 0.5,
                            "verdict": "correct", "feedback": "Evaluate the bounds.", "error_type": "Missing Step"})
        raise AssertionError(f"unexpected prompt: {system[:60]}")
    return create


@override_settings(ANTHROPIC_API_KEY="")
class CollegeTests(TestCase):
    def setUp(self):
        college.WORKERS = 1
        self.owner, self.auth = make_account(premium_until=PAID)  # uploads are a subscriber feature
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        p = override_settings(DARB_UPLOAD_DIR=tmp / "uploads")
        p.enable()
        self.addCleanup(p.disable)

    def post(self, url, body, auth=None):
        return self.client.post(url, body, content_type="application/json", **(auth or self.auth))

    def upload(self, mid, data, n=0, auth=None, chunk=1000):
        url = f"/api/upload/{mid}/{n}"
        for off in range(0, len(data), chunk):
            r = self.client.put(f"{url}?offset={off}", data[off:off + chunk], content_type="application/octet-stream",
                                **(auth or self.auth))
            self.assertEqual(r.status_code, 200, r.content)
        return self.post(f"{url}/done", {"sha256": hashlib.sha256(data).hexdigest()}, auth)

    def material(self, kind="notes", course="c1", files=1):
        mid = str(uuid.uuid4())
        save_docs(self.owner, [{"id": mid, "kind": "material", "updated_at": 1, "deleted": False,
                                "data": {"course_id": course, "kind": kind, "title": "MATH106 notes", "files": [{}] * files}}])
        return mid

    def test_upload_resume_and_types(self):
        mid = self.material()
        data = pdf_bytes()
        url = f"/api/upload/{mid}/0"
        self.assertEqual(self.client.put(f"{url}?offset=0", data[:500], content_type="application/octet-stream", **self.auth).json(),
                         {"size": 500})
        r = self.client.put(f"{url}?offset=0", data[:500], content_type="application/octet-stream", **self.auth)
        self.assertEqual((r.status_code, r.json()["error"]), (409, "offset must be 500"))  # a retried chunk can't duplicate
        self.assertEqual(self.client.get(url, **self.auth).json(), {"size": 500, "done": False})
        self.client.put(f"{url}?offset=500", data[500:], content_type="application/octet-stream", **self.auth)
        self.assertEqual(self.post(f"{url}/done", {"sha256": "0" * 64}).status_code, 400)  # corrupted: start over
        self.assertEqual(self.upload(mid, data).json(), {"ok": True, "type": "pdf"})
        self.assertEqual(self.client.get(url, **self.auth).json(), {"size": len(data), "done": True})
        bad = self.upload(mid, b"#!/bin/sh\nrm -rf /\n", n=1)
        self.assertEqual(bad.status_code, 415)
        self.assertEqual(self.client.put("/api/upload/not-a-uuid/0?offset=0", b"x", content_type="application/octet-stream",
                                         **self.auth).status_code, 400)

    def test_material_to_prepared_assessment(self):
        log = []
        mid = self.material()
        self.assertEqual(self.post("/api/college/process", {"material_id": mid}).status_code, 409)  # nothing uploaded yet
        self.upload(mid, pdf_bytes(3))
        r = self.post("/api/college/process", {"material_id": mid})
        self.assertEqual(r.json()["status"], "queued")

        with mock.patch("core.ai._create", side_effect=fake_ai(log)):
            drain()
        ing = ingest.get_ingest(self.owner, mid)
        self.assertEqual((ing["status"], ing["pages"], ing["lang"]), ("ready", 3, "en"))
        self.assertEqual([(s["id"], s["title"], s["start"], s["end"]) for s in ing["structure"]],
                         [("s1", "Course plan", 1, 1), ("s2", "Chapter 5 Integration", 2, 3), ("s3", "5.3 Substitution", 3, 3)])
        map_req = log[0]
        self.assertEqual(map_req["model"], "claude-haiku-5-5")  # runtime AI is Haiku only
        self.assertEqual([b["title"] for b in map_req["messages"][0]["content"][:3]], ["p. 1", "p. 2", "p. 3"])

        # The course plan page became proposed assessments with a scope matched to the sections.
        props = {d.data["title"]: d for d in Doc.objects.filter(kind="assessment")}
        self.assertEqual(set(props), {"Quiz 1", "Final Exam"})
        quiz = props["Quiz 1"]
        self.assertEqual((quiz.data["status"], quiz.data["weeks"], quiz.data["scope"]),
                         ("proposed", "3-4", []))  # "{mid}/s2" isn't a real key -> dropped, no guessing
        self.assertEqual(props["Final Exam"].data["date"], "2027-01-20")

        # The student confirms the quiz (date in 2 days -> prepared now, not in the background) with a scope.
        a = dict(quiz.data, status="active", date=(date.today() + timedelta(days=2)).isoformat(),
                 scope=[{"material_id": mid, "section_id": "s2"}], hints="Substitution will be on it")
        save_docs(self.owner, [{"id": quiz.doc_id, "kind": "assessment", "updated_at": now_ms(), "deleted": False, "data": a}])
        est = self.post("/api/college/prepare", {"assessment_id": quiz.doc_id}).json()["estimate"]
        self.assertEqual((est["pages"], est["sections"], est["new_sections"]), (2, 1, 1))
        self.assertGreater(est["usd"], 0)
        prep = self.post("/api/college/prepare", {"assessment_id": quiz.doc_id, "confirm": True}).json()
        self.assertEqual((prep["status"], prep["mode"]), ("queued", "now"))

        log.clear()
        with mock.patch("core.ai._create", side_effect=fake_ai(log)):
            drain()
        prep = Doc.objects.get(doc_id=f"prep-{quiz.doc_id}").data
        self.assertEqual(prep["status"], "done", prep)
        kps = Doc.objects.filter(kind="kp")
        self.assertEqual(kps.count(), 2)  # the empty point was dropped
        self.assertEqual({k.data["section"] for k in kps}, {f"{mid}/s2"})
        extract = next(k for k in log if k["system"][1]["text"].startswith("You extract"))
        self.assertEqual([b["title"] for b in extract["messages"][0]["content"] if b["type"] == "document"], ["p. 2", "p. 3"])
        prio = Doc.objects.get(doc_id=f"prio-{quiz.doc_id}").data["scores"]
        self.assertEqual(sorted(prio.values()), [5, 5])
        # Edited hints of a prepared assessment queue a re-scoring 2 minutes later (not during the sync).
        a = Doc.objects.get(doc_id=quiz.doc_id)
        self.post("/api/sync", {"docs": [{"id": a.doc_id, "kind": "assessment", "updated_at": now_ms(), "deleted": False,
                                          "data": dict(a.data, hints="Only 5.3")}]})
        self.assertTrue(Job.objects.filter(kind="prio", ref=quiz.doc_id).exists())
        self.assertEqual(drain(), 0)  # not due yet
        gen = next(k for k in log if k["system"][1]["text"].startswith("You write study cards"))
        self.assertEqual(gen["model"], "claude-haiku-5-5")
        self.assertIn("Substitution will be on it", gen["messages"][0]["content"])

        cards = {c.data["question"]: c.data for c in Doc.objects.filter(kind="card")}
        # Verified problem kept; wrong answer key and unverifiable numeric answer dropped (fill pass reruns the same mock).
        self.assertIn("Evaluate $\\int_0^3 x^2\\,dx$.", cards)
        self.assertNotIn("Wrong key", cards)
        self.assertNotIn("No check", cards)
        problem = cards["Evaluate $\\int_0^3 x^2\\,dx$."]
        self.assertTrue(problem["verified"] and problem["worked"])
        self.assertEqual(problem["rubric"], [{"point": "antiderivative", "weight": 0.5}, {"point": "evaluate", "weight": 0.5}])
        self.assertEqual((problem["course"], problem["section"], problem["ref"]["loc"]), ("c1", f"{mid}/s2", 3))
        self.assertEqual(cards["State the power rule."]["type"], "short")
        self.assertGreaterEqual(prep["unverified"], 2)
        self.assertEqual(prep["uncovered"], 0)
        sheets = {d.data["kind"]: d.data["content"] for d in Doc.objects.filter(kind="sheet")}
        self.assertEqual(set(sheets), {"summary", "facts"})  # formulas: null -> no sheet
        self.assertGreater(prep["cost_usd"], 0)
        self.assertTrue(AiCall.objects.filter(endpoint="college_generate").exists())
        self.assertTrue(AiCall.objects.filter(endpoint="college_review").exists())

        # Grading a written answer against the rubric.
        with mock.patch("core.ai._create", side_effect=fake_ai(log)):
            g = self.post("/api/college/grade", {"card": problem, "answer": "x^3/3"}).json()
        self.assertEqual((g["score"], g["verdict"]), (0.5, "partial"))  # verdict follows the score, not the model's word
        self.assertEqual(g["error_type"], "missing step")
        self.assertEqual(self.post("/api/college/grade", {"card": problem, "answer": ""}).status_code, 400)

    def test_background_mode_and_student_isolation(self):
        mid = self.material()
        self.upload(mid, pdf_bytes(2))
        self.post("/api/college/process", {"material_id": mid})
        with mock.patch("core.ai._create", side_effect=fake_ai()):
            drain()
        aid = str(uuid.uuid4())
        save_docs(self.owner, [{"id": aid, "kind": "assessment", "updated_at": 1, "deleted": False, "data": {
            "course_id": "c1", "kind": "final", "title": "Final", "date": (date.today() + timedelta(days=20)).isoformat(),
            "scope": [{"material_id": mid, "section_id": "s2"}], "status": "active"}}])
        batches = mock.MagicMock()
        batches.create.return_value = NS(id="msgbatch_x")
        batches.retrieve.return_value = NS(processing_status="in_progress")
        with mock.patch("core.ai._batches", return_value=batches):
            prep = self.post("/api/college/prepare", {"assessment_id": aid, "confirm": True}).json()
            self.assertEqual(prep["mode"], "batch")  # 20 days away: 50% off through the Batch API
            drain()
        prep = Doc.objects.get(doc_id=f"prep-{aid}").data
        self.assertEqual((prep["status"], prep["stage"], prep["pending"]["batch_id"]), ("waiting", "extract", "msgbatch_x"))
        self.assertNotIn("fallbacks", json.dumps(batches.create.call_args.kwargs))

        # Another account sees none of it: not the docs, not the files, not the pages.
        _, sara = make_account("sara@example.com", premium_until=PAID)
        self.assertEqual(self.client.get(f"/api/upload/{mid}/0", **sara).json(), {"size": 0, "done": False})
        self.assertEqual(self.post("/api/college/process", {"material_id": mid}, sara).status_code, 404)
        self.assertEqual(self.post("/api/college/prepare", {"assessment_id": aid}, sara).status_code, 404)
        self.assertEqual(self.client.get(f"/api/college/page/{mid}/1", **sara).status_code, 409)
        pulled = self.post("/api/sync", {"cursor": 0, "docs": []}, sara).json()["docs"]
        self.assertEqual(pulled, [])

    def test_photos_become_pages(self):
        from PIL import Image
        mid = self.material(kind="photos", files=2)
        for n in range(2):
            buf = io.BytesIO()
            Image.new("RGB", (400, 600), "white").save(buf, "JPEG")
            self.assertEqual(self.upload(mid, buf.getvalue(), n=n).json()["type"], "jpg")
        self.assertEqual(ingest.build_pdf(self.owner, mid), 2)



class ScopePagesTests(TestCase):
    def test_boundary_pages_are_read_once(self):
        m = {"id": "m1"}
        sec = lambda i, a, b: (f"m1/s{i}", m, {"start": a, "end": b, "level": 2}, {})
        scope = [sec(1, 4, 5), sec(2, 5, 6), sec(3, 6, 9)]  # neighbours share their boundary page
        self.assertEqual(college._scope_pages(scope), {"m1/s1": [4, 5], "m1/s2": [6], "m1/s3": [7, 8, 9]})
        self.assertEqual(college._scope_pages(scope, skip={"m1/s1"}), {"m1/s2": [6], "m1/s3": [7, 8, 9]})
        # Dense prose holds far more knowledge points per page than slides.
        self.assertGreater(college._expected_kps([1300] * 10), 3 * college._expected_kps([350] * 10) / 2)

    def test_short_answers_stay_short(self):
        short = lambda answer: college._clean_course_card(
            {"type": "short", "question": "What do we call it?", "explanation": "Because.", "answer": answer})
        self.assertEqual(short("The default constructor")[0]["answer"], "The default constructor")
        self.assertEqual(short("one two three four five six"), (None, "too long"))
