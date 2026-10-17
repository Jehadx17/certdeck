import json
import re
import tempfile
from pathlib import Path
from types import SimpleNamespace as NS
from unittest import mock

from django.test import TestCase

from core import content
from core.models import ContentBatch, Pack, PackItem
from core.tests import message

BP = {"slug": "demo-quant", "title_ar": "القدرات - كمي", "title_en": "Qudurat - quantitative", "segments": ["high"],
      "exams": ["qudurat"], "subject": "math", "format": "MCQ, 4 options",
      "sources": [{"url": "https://etec.gov.sa/x", "what": "sections"}],
      "topics": [{"id": "t1", "title_ar": "النسبة", "count": 4, "item_types": ["mcq"]}]}


def gen_items(k):
    """Four generated items: two good, one with a wrong SymPy check, one the solver will disagree with."""
    item = lambda q, opts, c, check=None: dict(type="mcq", question=q, options=opts, correct=[c], answer=None,
                                               explanation="لأن...", hint="فكّر في...", difficulty=2, skill="نسبة", check=check)
    return [item(f"ما ناتج {k}+٣؟", [str(k), str(k + 3), "٠", "١٠٠"], 1, {"kind": "numeric", "expr": f"{k}+3", "value": str(k + 3), "var": None}),
            item("سؤال جيد ٢", ["أ", "ب", "ج", "د"], 0),
            item("مفتاح خطأ", ["٤", "٥", "٦", "٧"], 0, {"kind": "numeric", "expr": "2+2", "value": "5", "var": None}),
            item("سيخالفه المحلّل", ["أ", "ب", "ج", "د"], 2)]


class FakeBatches:
    """The Message Batches API, answering each request from its prompt."""

    def __init__(self):
        self.batches = {}

    def create(self, requests):
        bid = f"b{len(self.batches)}"
        self.batches[bid] = requests
        return NS(id=bid)

    def retrieve(self, bid):
        return NS(processing_status="ended")

    def results(self, bid):
        for r in self.batches[bid]:
            p, text = r["params"], r["params"]["messages"][0]["content"]
            ns = [int(n) for n in re.findall(r"^\[(\d+)\]", text, re.M)]
            if p["system"][0]["text"].startswith("You write ORIGINAL"):
                out = {"items": gen_items(len(self.batches))}
            elif p["system"][0]["text"].startswith("You are an independent expert"):
                qs = dict(re.findall(r"^\[(\d+)\] (.*)$", text, re.M))
                out = {"answers": [{"i": n, "choice": 0 if "سيخالفه" in qs[str(n)] else (1 if "ناتج" in qs[str(n)] else 0),
                                    "answer": None, "confidence": 4, "flawed": False, "reason": ""} for n in ns]}
            else:  # audit: the first audited item has an error
                out = {"results": [{"i": n, "error": i == 0, "kind": "key" if i == 0 else "none", "note": ""} for i, n in enumerate(ns)]}
            msg = message(out)
            msg.model = p["model"]
            yield NS(custom_id=r["custom_id"], result=NS(type="succeeded", message=msg))


class PipelineTests(TestCase):
    def test_blueprint_to_audited_pack(self):
        tmp = Path(tempfile.mkdtemp())
        (tmp / "demo-quant.json").write_text(json.dumps(BP, ensure_ascii=False))
        fake = FakeBatches()
        with mock.patch.object(content, "BLUEPRINTS", tmp), mock.patch("core.ai._batches", return_value=fake), \
                mock.patch.object(content, "AUDIT_SAMPLE", 2):
            lines = [content.advance("demo-quant") for _ in range(8)]
        pack = Pack.objects.get(slug="demo-quant")
        statuses = dict(PackItem.objects.filter(pack=pack).values_list("data__question", "status"))
        self.assertNotIn("مفتاح خطأ", statuses)  # the SymPy check caught the wrong key: never stored
        self.assertEqual(statuses["سيخالفه المحلّل"], "quarantined")  # the blind solver disagreed with the key
        # Both good items passed the solver; the audit (sample of 2) found an error in one of them, which is not shipped.
        self.assertEqual(sorted(st for q, st in statuses.items() if q != "سيخالفه المحلّل"), ["rejected", "verified"])
        self.assertEqual(pack.sources[0]["kind"], "official blueprint (format and topics only)")
        self.assertIsNotNone(pack.error_rate)
        self.assertIn("n=2", pack.error_ci)
        self.assertIn("complete", lines[-1])
        self.assertTrue(all(b.status == "done" for b in ContentBatch.objects.all()))
        gen = fake.batches["b0"][0]["params"]
        self.assertEqual((gen["model"], gen["output_config"]["effort"]), ("claude-opus-5-5", "high"))
        self.assertNotIn("fallbacks", json.dumps(fake.batches))  # the Batch API rejects it

    def test_import_offline_items(self):
        tmp = Path(tempfile.mkdtemp())
        (tmp / "demo-quant.json").write_text(json.dumps(BP, ensure_ascii=False))
        rows = [dict(i, topic="t1", **({"source": "mezla:MezlaQ4/28246"} if n == 0 else {})) for n, i in enumerate(gen_items(5))] + [dict(gen_items(5)[1], topic="t1"),  # a repeat
                                                               dict(gen_items(6)[0], topic="nope")]
        (tmp / "items.jsonl").write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n")
        with mock.patch.object(content, "BLUEPRINTS", tmp):
            stats = content.import_items("demo-quant", tmp / "items.jsonl")
        self.assertEqual((stats["added"], stats["check failed"], stats["duplicate"], stats["unknown topic"]), (3, 1, 1, 1))
        self.assertEqual(set(PackItem.objects.values_list("status", "source")), {("verified", "claude-code:items.jsonl"),
                                                                                       ("verified", "claude-code:items.jsonl mezla:MezlaQ4/28246")})

    def test_check_matches_arabic_keys(self):
        from core import verify
        num = lambda v: {"kind": "numeric", "expr": v, "value": v}
        for value, key in [("5.2", "٥,٢"), ("-11", "١١-"), ("16", "2^4"), ("42", "6 × 7"), ("1/3", "١/٣")]:
            self.assertTrue(verify.matches_key(num(value), key), (value, key))
        self.assertFalse(verify.matches_key(num("9.5"), "١١,٥"))
        self.assertTrue(verify.check({"kind": "numeric", "expr": "lcm(6, 10, 8)", "value": "120"}))
        for expr, value in [("(9+16)%24", "1"), ("54321*12345//10 % 10", "4"), ("round(1470*1.07)", "1573"),
                            ("min(27//4, 19//2)", "6"), ("max(60, 65)", "65"), ("abs(abs(-6)-2+4)", "8"), ("int(7777/10/20)", "38")]:
            self.assertTrue(verify.check({"kind": "numeric", "expr": expr, "value": value}), expr)

    def test_wilson_interval(self):
        lo, hi = content.wilson(1, 60)
        self.assertTrue(0 < lo < 1 / 60 < hi < 0.1)
        self.assertEqual(content.wilson(0, 0), (0.0, 1.0))
