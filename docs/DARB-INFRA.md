# Darb: infrastructure, sizing and upgrade path

Prices and limits checked 2026-10-15 on the linked pages; latency measured the same day.

## Where: Contabo, Germany (EU)
Contabo has no Gulf or Middle East data centre and serves the Middle East from Germany ([locations](https://contabo.com/en/locations/)).
I measured latency with Globalping ICMP from its 6 probes in Saudi Arabia (data-centre networks: Oracle Jeddah, Huawei Cloud Riyadh, Wafai Net Riyadh/Thuwal),
pinging Contabo's own speedtest hosts. Results are at `https://api.globalping.io/v1/measurements/<id>`.

| Contabo region | min RTT | avg RTT | location fee (VPS 8) | measurement |
|---|---|---|---|---|
| **EU, Karlsruhe** | **63.7 ms** | ~75 ms | **€0** | 2AbrvZL1YkH9pvZKm00021K5a |
| UK, Portsmouth | 76.3 | ~79 | €3.25 | 20twUIgnO1kCEhucn00021K5a |
| US East | 142.1 | ~151 | €4.75 | 27un4JhdlfV5gBLSm00021K5a |
| India, Mumbai | 145.8 | ~163 | €7.40 | 2lyML2BMKz6E2abeb00021K5a |
| Singapore | 161.7 | ~215 | €7.85 | 2qhPZIRV8G0THzfWs00021K5a |

Home broadband probes in the UAE and Bahrain saw 98-123 ms to Germany. **Germany is both the fastest and the cheapest.**
A sync round trip (~75 ms + server time) is invisible to a student because studying is offline-first. Packs are served
from Cloudflare's edge (Jeddah/Riyadh/Dammam points of presence), not from Germany.

## Contabo prices (€/month, no setup fee; 12-month term -15%, 24-month -20%)
Sources: [VPS](https://contabo.com/en/vps/), [VDS](https://contabo.com/en/vds/). The pages have a VAT toggle and I could not
confirm whether these figures include VAT (release checklist: confirm on the order page).

| Plan | vCPU / RAM / disk | monthly | 12-mo term |
|---|---|---|---|
| Cloud VPS 6 | 6 / 12 GB / 100 GB NVMe | 7.50 | 6.38 |
| Cloud VPS 8 | 8 / 24 GB / 150 GB NVMe | 14.00 | 11.90 |
| Cloud VPS 12 | 12 / 48 GB / 200 GB NVMe | 25.00 | 21.25 |
| VDS S (dedicated cores) | 6 / 24 GB / 180 GB NVMe | 49.00 | 41.65 |

## Other services
- **Cloudflare R2** ([pricing](https://developers.cloudflare.com/r2/pricing/)): $0.015/GB-month, Class A $4.50/M, Class B
  $0.36/M, **egress free**; free tier 10 GB, 1M writes, 10M reads per month. Holds packs (behind the CDN) and backups.
- **Cloudflare Free plan** in front of the API: 10 cache rules, 5 WAF custom rules, Free Managed Ruleset, **1 rate-limit
  rule (per IP, path match)** ([rate limiting](https://developers.cloudflare.com/waf/rate-limiting-rules/)). Uploads are capped at
  100 MB and **a request that gets no answer within 125 s returns 524**
  ([524](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-5xx-errors/error-524/)). So every
  request must answer in under ~100 s, and anything longer goes on the job queue. Per-account and per-device limits live in Django.
- **pgBackRest to R2** ([config](https://pgbackrest.org/configuration.html)): `repo1-type=s3`,
  `repo1-s3-endpoint=<account>.r2.cloudflarestorage.com`, `repo1-s3-region=auto`, `repo1-s3-uri-style=path`. Use
  pgBackRest's own `repo1-cipher-type=aes-256-cbc`, because R2 rejects `x-amz-server-side-encryption`
  ([R2 S3 API](https://developers.cloudflare.com/r2/api/s3/api/)). Known issue: restores from R2 were slow in older releases
  ([pgbackrest#2782](https://github.com/pgbackrest/pgbackrest/issues/2782)). The restore test times it.
- **Sentry Developer (free)** ([pricing](https://sentry.io/pricing/)): 5,000 errors/month, 1 user, 30-day history.
- **Uptime**: UptimeRobot free, 50 monitors every 5 min ([pricing](https://uptimerobot.com/pricing/)), but its page calls it
  "for hobby and non-profit projects". Better Stack free has 10 monitors, 3-min checks, and email/Slack alerts
  ([pricing](https://betterstack.com/pricing)). **Use Better Stack** for a commercial app.
- **Anthropic** ([pricing](https://platform.claude.com/docs/en/about-claude/pricing)), $/MTok in/out:
  - Haiku 5.5: 0.10/0.50 up to 100K prompt tokens (cached tokens count toward the 100K), 0.50/2.50 above that.
  - Sonnet 5.5: 2/10. Opus 5.5: 4/20.
  - Batch is 50% off and stacks with caching. Cache reads are 0.1x on Haiku.

## Architecture (stateless app, one DATABASE_URL)
```
Cloudflare (TLS, WAF, 1 rate rule, CDN for cdn.darbedu.sa -> R2 packs)
   |
nginx (per app VPS; per-IP limit_req; routes slow paths to the worker VPS)
   |-- /api/* ------------> api containers (gunicorn, stateless; sync, account, billing, pack keys)
   |-- /api/ai/*, /api/upload*, /api/college/* --> slow pool on the worker VPS (own gunicorn, own threads,
   |                         uploads disk), so a slow AI call can never hold a sync worker
   v
PgBouncer (transaction pooling) -> Postgres primary --streaming--> standby (read replica option)
                                       \--> pgBackRest: WAL archive + backups to R2 (encrypted)
worker container: Postgres-backed job queue (SKIP LOCKED): uploads, reteach, autopilot, FSRS fits, partitions,
                  anomaly rules, AI spend alert
```
Nothing about a request lives in an app container: tokens are in Postgres, packs are in R2, uploads are on the worker VPS
only, and AI work runs on the slow pool or the queue. To add an app VPS, run the same image and add it to nginx's upstream.

## Sizing
**Launch** (about 500 new students/week): **one Cloud VPS 8** (€14/month) running everything with the same compose file.
Backups go continuously to R2. That costs about €14 + R2 (< $1) per month, plus AI.

**100k registered / ~30k monthly active / ~100 req/s peak** (the target layout, 5 VPS):

| Role | Plan | €/mo (monthly / 12-mo) |
|---|---|---|
| app 1 + nginx | Cloud VPS 6 | 7.50 / 6.38 |
| app 2 + nginx | Cloud VPS 6 | 7.50 / 6.38 |
| Postgres primary + PgBouncer | Cloud VPS 12 | 25.00 / 21.25 |
| Postgres standby (hot, read replica) | Cloud VPS 12 | 25.00 / 21.25 |
| worker (slow pool + job queue + uploads) | Cloud VPS 8 | 14.00 / 11.90 |
| **total** | | **€79.00 / €67.16** |

This is under the €100 target. The load test in [DARB-LOADTEST.md](DARB-LOADTEST.md) checks it.

## Upgrade path (each step and the metric that triggers it)
| Step | Trigger (any one, sustained a week at peak hour) | Action | Cost after |
|---|---|---|---|
| 0. All-in-one VPS 8 | launch | | €14 |
| 1. DB on its own VPS 12 | DB CPU > 50%, or sync p95 > 300 ms, or RAM used by Postgres + app > 70% | move with `pg_dump`/pgBackRest restore; change `DATABASE_URL` | €39 |
| 2. Hot standby | > 500 paying subscribers, or you want recovery in minutes (not a restore from R2) | streaming replica on a VPS 12; replica URL for admin/reports | €64 |
| 3. Split app / worker | app CPU > 60%, or the slow pool queue waits > 5 s, or upload processing delays > 10 min | second app VPS 6 + worker VPS 8 | €79-86 |
| 4. Bigger DB | DB cache hit < 99%, or IO wait > 10%, or connections saturate PgBouncer | VPS 12 -> VDS M/L (dedicated cores) | €120-150 |
| 5. Managed Postgres (e.g. RDS) | ops time on the DB > ~4 h/month, or the dataset outgrows a VDS, or a regulator requires in-Kingdom hosting | dump/restore to the managed service; set `DATABASE_URL` | provider pricing |

Metrics come from Postgres (`pg_stat_*`), node CPU/RAM, nginx timings and the app's own `/api/health?deep=1`. Alerts are listed in [DARB-OPS.md](DARB-OPS.md).
