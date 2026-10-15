import json
from types import SimpleNamespace as NS

from django.db import connection
from django.test import TestCase

from core import jobs
from core.models import Account, Device, Doc, Job, all_reviews, now_ms, pack_flags, save_docs, unpack_flags

DAY = 86_400_000


def message(payload, stop_reason="end_turn"):
    return NS(stop_reason=stop_reason,
              content=[NS(type="thinking", thinking="..."), NS(type="text", text=json.dumps(payload))],
              usage=NS(input_tokens=100, output_tokens=50, cache_read_input_tokens=10, cache_creation_input_tokens=5))


def make_account(email="s@example.com", **kw):
    """An account with one device; returns (account, auth headers for the test client)."""
    account = Account.objects.create(email=email, **kw)
    _, token = Device.issue(account, "android")
    return account, {"HTTP_AUTHORIZATION": f"Bearer {token}"}


def doc(id, data, kind="settings", updated_at=1, deleted=False):
    return {"id": id, "kind": kind, "data": data, "updated_at": updated_at, "deleted": deleted}


def review(card, ts, rating=3, **kw):
    return {"ts": ts, "card_id": card, "rating": rating, "correct": rating > 1, "confidence": "sure",
            "duration_ms": 4000, **kw}


def drain():
    """Runs every due job (what the worker does)."""
    from core import tasks  # noqa: F401 - registers the handlers
    n = 0
    while jobs.run_one():
        n += 1
    return n


class SyncTests(TestCase):
    def setUp(self):
        self.a, self.auth = make_account()

    def sync(self, body, auth=None):
        r = self.client.post("/api/sync", body, content_type="application/json", **(auth or self.auth))
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def test_auth(self):
        self.assertEqual(self.client.post("/api/sync", {}, content_type="application/json").status_code, 401)
        self.assertEqual(self.client.get("/api/me", HTTP_AUTHORIZATION="Bearer nope").status_code, 401)
        self.assertEqual(self.client.get("/api/health").json(), {"ok": True})
        me = self.client.get("/api/me", **self.auth).json()
        self.assertEqual(me["id"], self.a.public_id)
        self.a.active = False
        self.a.save()
        self.assertEqual(self.client.get("/api/me", **self.auth).status_code, 401)

    def test_docs_last_write_wins_and_cursor(self):
        out = self.sync({"cursor": 0, "docs": [doc("settings", {"lang": "ar"}, updated_at=10), doc("x", {"n": 1}, "exam")]})
        self.assertEqual([d["id"] for d in out["docs"]], ["settings", "x"])
        cursor = out["cursor"]
        self.assertEqual(self.sync({"cursor": cursor})["docs"], [])  # nothing new
        self.sync({"cursor": cursor, "docs": [doc("settings", {"lang": "en"}, updated_at=5)]})  # older: ignored
        self.assertEqual(Doc.objects.get(doc_id="settings").data, {"lang": "ar"})
        out = self.sync({"cursor": cursor, "docs": [doc("settings", {"lang": "en"}, updated_at=11)]})
        self.assertEqual([d["data"] for d in out["docs"]], [{"lang": "en"}])
        self.assertEqual(out["cursor"], cursor + 1)  # the per-user cursor counts this user's writes only

    def test_cursor_is_per_user_and_data_is_isolated(self):
        b, auth_b = make_account("b@example.com")
        self.sync({"cursor": 0, "docs": [doc("settings", {"who": "a"})]})
        out_b = self.sync({"cursor": 0, "docs": [doc("settings", {"who": "b"})], "reviews": [review("q:1", now_ms())]}, auth_b)
        self.assertEqual([d["data"] for d in out_b["docs"]], [{"who": "b"}])
        self.assertEqual(out_b["cursor"], 1)  # b's first write is b's seq 1, whatever a did
        self.assertEqual(self.sync({"cursor": 0})["reviews"], [])
        self.assertEqual(Account.objects.get(pk=self.a.pk).seq, 1)

    def test_reviews_round_trip_compactly(self):
        now = now_ms()
        r1 = review("qdr:12", now - 1000, rating=1, misconception=True, confidence="sure", source="exam", score=0.5,
                    error_type="Missing step")
        out = self.sync({"cursor": 0, "review_cursor": 0, "reviews": [r1, review("qdr:13", now)]})
        self.assertEqual(len(out["reviews"]), 2)
        got = out["reviews"][0]
        self.assertEqual((got["card_id"], got["rating"], got["correct"], got["misconception"], got["confidence"],
                          got["source"], got["score"], got["error_type"]),
                         ("qdr:12", 1, False, True, "sure", "exam", 0.5, "Missing step"))
        rc = out["review_cursor"]
        # A resent review (the response was lost) is not stored twice.
        out = self.sync({"cursor": out["cursor"], "review_cursor": rc, "reviews": [r1]})
        self.assertEqual(out["reviews"], [])
        self.assertEqual(len(all_reviews(self.a)), 2)
        # A fresh install pulls everything.
        self.assertEqual(len(self.sync({"cursor": 0, "review_cursor": 0})["reviews"]), 2)

    def test_validation(self):
        bad = [{"cursor": -1}, {"docs": [{"id": "x"}]}, {"reviews": [review("c", now_ms() - 500 * DAY)]},
               {"reviews": [review("c", now_ms(), rating=7)]}, {"docs": [doc("x", {"big": "x" * 70_000})]},
               {"reviews": [review("c", now_ms() + i) for i in range(501)]}]
        for body in bad:
            r = self.client.post("/api/sync", body, content_type="application/json", **self.auth)
            self.assertIn(r.status_code, (400, 413), body)

    def test_paging(self):
        now = now_ms()
        for k in range(3):
            self.sync({"reviews": [review(f"c{k}:{i}", now - k * 1000 - i) for i in range(400)]})
        out = self.sync({"cursor": 0, "review_cursor": 0})
        self.assertEqual((len(out["reviews"]), out["more"]), (1000, True))
        out = self.sync({"cursor": out["cursor"], "review_cursor": out["review_cursor"]})
        self.assertEqual((len(out["reviews"]), out["more"]), (200, False))

    def test_flags(self):
        for r in ({}, {"correct": True, "study_first": True, "confidence": "guess", "source": "cram"},
                  {"misconception": True, "confidence": "unsure", "source": "other"}):
            u = unpack_flags(pack_flags(r))
            self.assertEqual({k: u[k] for k in r}, r)

    def test_reviews_queue_the_daily_job(self):
        self.sync({"reviews": [review("q:1", now_ms())]})
        self.sync({"reviews": [review("q:2", now_ms())]})
        self.assertEqual(Job.objects.filter(kind="daily", account=self.a).count(), 1)


class JobQueueTests(TestCase):
    def setUp(self):
        self.a, _ = make_account()
        self.ran = []
        jobs.HANDLERS["t"] = lambda account, ref: self.ran.append(ref) or (5 if ref == "later" else None)
        self.addCleanup(jobs.HANDLERS.pop, "t")

    def test_dedupe_reschedule_and_again(self):
        jobs.enqueue("t", self.a, "x")
        jobs.enqueue("t", self.a, "x")
        jobs.enqueue("t", self.a, "later")
        self.assertEqual(Job.objects.count(), 2)
        self.assertTrue(jobs.run_one() and jobs.run_one())
        self.assertFalse(jobs.run_one())  # "later" asked to run again in 5 s
        self.assertEqual(sorted(self.ran), ["later", "x"])
        self.assertEqual(list(Job.objects.values_list("ref", flat=True)), ["later"])
        # Enqueued while it runs: it runs once more afterwards.
        jobs.HANDLERS["t"] = lambda account, ref: jobs.enqueue("t", account, ref) or self.ran.append("again?")
        jobs.enqueue("t", self.a, "y")
        jobs.run_one()
        self.assertEqual(Job.objects.filter(ref="y").count(), 1)

    def test_failure_retries_after_the_lease(self):
        def boom(account, ref):
            raise RuntimeError("x")
        jobs.HANDLERS["t"] = boom
        jobs.enqueue("t", self.a, "z")
        self.assertTrue(jobs.run_one())
        job = Job.objects.get(ref="z")
        self.assertEqual((job.attempts, job.running), (1, False))
        with connection.cursor() as c:
            c.execute("UPDATE core_job SET run_at = now(), attempts = %s", [jobs.MAX_ATTEMPTS])
        self.assertTrue(jobs.run_one())
        self.assertFalse(Job.objects.exists())  # gave up after MAX_ATTEMPTS


class DeletionTests(TestCase):
    def test_account_delete_cascades(self):
        a, _ = make_account()
        save_docs(a, [doc("settings", {})], [review("q:1", now_ms())])
        jobs.enqueue("daily", a)
        a.delete()
        self.assertEqual((Doc.objects.count(), Job.objects.count(), Device.objects.count()), (0, 0, 0))
        with connection.cursor() as c:
            c.execute("SELECT count(*) FROM core_review")
            self.assertEqual(c.fetchone()[0], 0)
