# Darb: load test (100k-student profile)

Script: `darb/deploy/tests/loadtest.sh` with `locustfile.py`; CI job `loadtest` (commit tag `[loadtest]`).

The test runs the production compose stack:
- nginx with the real per-IP limits;
- 2 api containers;
- PgBouncer and Postgres 16;
- the slow pool, with AI stubbed at real Haiku latency (`DARB_AI_STUB_MS=3000`);
- 3,000 seeded accounts.

Each simulated student sends its own `CF-Connecting-IP`, as Cloudflare does. A load-test-only nginx override trusts
that header on the Docker network, so the per-IP limits apply per student.

**The traffic mix (per student, 1 request/s):**

| Request | Share |
|---|---|
| sync | 70% |
| me | 10% |
| pack list | 8% |
| AI explain | 5% |
| mistake report | 1% |

Pack files come from the CDN (R2 + Cloudflare), so a pack-download spike never reaches the VPS. Its server side is the
pack list and key requests, which run at the same rate as `me`.

## Result: passed (CI run 38956484671, 2026-10-16)
The machine was a GitHub ubuntu-24.04 runner, **2 vCPU / 7 GB**, also running the load generator. That's a
quarter of the launch server (Cloud VPS 8: 8 vCPU / 24 GB).

### Stage 1: peak of 100k students, 100 concurrent at 1 req/s for 5 min
| | requests | failures | median | p95 | p99 |
|---|---|---|---|---|---|
| sync | 20,474 | 0 | 44 ms | 260 ms | 570 ms |
| me | 2,886 | 0 | 30 ms | 190 ms | 510 ms |
| pack list | 2,297 | 0 | 30 ms | 210 ms | 560 ms |
| AI explain (stub, 3 s) | 1,403 | 0 | 2.8 s | 4.4 s | 4.5 s |
| **all** | **27,337 (91 req/s)** | **0** | 43 ms | | |

Containers at the midpoint (`docker stats`, % of one core):

| api-1 | api-2 | db | slow | PgBouncer | nginx |
|---|---|---|---|---|---|
| 50% | 49% | 45% | 17% | 6% | 2% |

Postgres afterwards:
- 236k commits, 0 rollbacks, 0 deadlocks;
- cache hit 99.99%;
- 209k reviews written into the month partition.

### Stage 2: launch-day spike, 300 concurrent for 2 min (3× the peak)
- 11,968 requests and **0 failures**.
- Throughput levelled off at **100 req/s**: the runner's 2 vCPU were full (load generator + api + db).
- Requests queued instead of failing: sync median 2.6 s, p95 6.1 s.
- On the 8-vCPU server, the same app and db containers get 4× the CPU.

### Weekly launch traffic (about 500 new students/week)
That's about 1 sign-in every 20 minutes at the busiest hour: nothing measurable next to the sync load.

## What this says, and the scaling triggers (DARB-INFRA.md → Upgrade path)
- **The peak fits on one VPS 8 with room to spare.** Here the stack used about 1.7 of 2 vCPU at 91 req/s, and 0 errors.
  The VPS 8 has 8.
- **Watch these, in this order** (thresholds sustained for a week at the peak hour):

| Metric | Trigger | Step |
|---|---|---|
| sync p95 | > 300 ms (260 ms here at full CPU) | 1. DB on its own VPS |
| DB CPU | > 50% | 1. DB on its own VPS |
| app CPU | > 60% | 3. split app / worker |
| slow-pool queue wait | > 5 s | 3. split app / worker |
| DB cache hit | < 99% (99.99% here) | 4. bigger DB |
| PgBouncer connections | saturated | 4. bigger DB |

## Fixed on the way
- **One 502 in 27k requests.** Gunicorn's default keep-alive (2 s) is shorter than nginx's upstream reuse, so nginx
  sometimes sent a request on a socket gunicorn had just closed. Gunicorn's keep-alive is now 75 s.
- **All traffic came from one IP in CI**, so nginx's per-IP limit answered 429. That was correct behaviour, but not
  real traffic; fixed with per-student IPs as above.

## Still to do (👤 VPS first)
Run the same script on the Cloud VPS 8 before launch, with the load generator on a separate machine, and add the
numbers here.
