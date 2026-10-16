"""Darb load test (docs/DARB-LOADTEST.md): the 100k-student profile at peak, ~100 requests/s.

Per simulated student, one request a second on average, weighted like real use: sync dominates (open/resume, every
session end, every 2 min while there are changes), then the account, the pack list, mistake reports, AI explanations
(stubbed with real latency on the slow pool) and pack keys. Run: locust -f locustfile.py --headless -u 100 -r 20
-t 5m --host http://localhost:8080 (tokens.txt from manage.py loadtest_seed)."""
import itertools
import random
import time

from locust import HttpUser, constant_throughput, task

TOKENS = open("tokens.txt").read().split()
_next = itertools.count()


class Student(HttpUser):
    wait_time = constant_throughput(1)

    def on_start(self):
        n = next(_next)
        self.token = TOKENS[n % len(TOKENS)]
        # One IP per student, as Cloudflare reports it (nginx trusts it only in the load test's override).
        self.h = {"Authorization": f"Bearer {self.token}", "CF-Connecting-IP": f"10.{n >> 16 & 255}.{n >> 8 & 255}.{n & 255}"}
        self.cursor = self.rcursor = 0

    @task(70)
    def sync(self):
        now = int(time.time() * 1000)
        reviews = [{"ts": now - k, "card_id": f"qudurat-verbal:{random.randint(1, 1200)}", "rating": random.randint(1, 4),
                    "correct": True, "confidence": "sure", "duration_ms": 8000} for k in range(random.choice([0, 0, 5, 10, 20]))]
        docs = [{"id": f"sess-{now}", "kind": "session", "data": {"done": len(reviews)}, "updated_at": now}] if reviews else []
        with self.client.post("/api/sync", json={"cursor": self.cursor, "review_cursor": self.rcursor, "docs": docs,
                                                  "reviews": reviews}, headers=self.h, name="sync", catch_response=True) as r:
            if r.ok:
                body = r.json()
                self.cursor, self.rcursor = body["cursor"], body["review_cursor"]

    @task(10)
    def me(self):
        self.client.get("/api/me", headers=self.h, name="me")

    @task(8)
    def packs(self):
        self.client.get("/api/packs", headers=self.h, name="packs")

    @task(5)
    def explain(self):  # the slow pool; 402 (free cap) and 429 count as expected answers
        with self.client.post("/api/ai/explain", json={"card": {"type": "basic", "question": f"q{random.randint(1, 50)}",
                                                               "answer": "a"}, "messages": [{"role": "user", "text": "why?"}]},
                              headers=self.h, name="ai explain", catch_response=True) as r:
            if r.status_code in (402, 429):
                r.success()

    @task(1)
    def report(self):
        self.client.post("/api/report", json={"card_id": f"qudurat-verbal:{random.randint(1, 1200)}"}, headers=self.h,
                         name="report")
