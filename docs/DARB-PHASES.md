# Darb: phase reports

Each phase ends with what was built, how it was verified, the cost measured, and what is next (docs/GOAL-DARB.md → Rules).

## Phase 0: Foundation (2026-10-15)

**Built**
- **New app `darb/app`**, bundle/application id **`sa.darbedu.app`** on both platforms, built from CertDeck's student
  app.
  - Flutter **3.35.7** (Dart 3.9.2), AGP 8.9.1, Gradle 8.12, Android **minSdk 24 / targetSdk 36**, **iOS 13+**.
    Why these and not older or newer: [DARB-DEVICES.md](DARB-DEVICES.md).
  - Arabic-first with English available; light/dark/system themes.
  - Removed: the self-updater (not allowed on Play), on-device ML Kit translation, and the entry points to CertDeck's
    owner screens. Those screens are deleted in phase 5, when the segment screens replace them.
  - Release builds are R8-shrunk and signed from a gitignored `key.properties`. Gradle is capped at 2 GB: the
    template's 8 GB default froze the laptop once.
- **New backend `darb/backend`** (Django 5.2 + DRF):
  - Postgres only, configured by **one `DATABASE_URL`** (PgBouncer-safe: no server-side cursors or prepared statements);
    an optional replica URL.
  - Per-device bearer tokens.
  - Runtime AI fixed to **claude-haiku-5-5**.
  - Uploads limited to PDF/photos (30 MB/file, 20 files, 60 pages).
  - CertDeck's cert/owner features are removed: generate, analyze, diagrams, variants, import/export, media, self-update.
- **Scale fixes 1-3 are done now, not at launch, because the protocol changed anyway**
  ([DARB-PROTOCOL.md](DARB-PROTOCOL.md)):
  1. **Per-user sync cursor:** `UPDATE core_account SET seq = seq + n ... RETURNING seq` locks only that student's row.
     The global `Counter` row is gone.
  2. **Compact review log:** the `core_review` table is partitioned by month, with packed flags and primary key
     `(account, ts, card)`. Pack cards never enter the sync table, and documents are capped at 64 KB.
  3. **Slow work off the sync path:**
     - a Postgres job queue (`FOR UPDATE SKIP LOCKED`, leased, deduplicated) runs upload processing, preparation,
       re-scoring, autopilot and re-teach on the `worker`;
     - interactive AI and uploads go to their own `slow` gunicorn pool (nginx routes `/api/ai|upload|college/`);
     - the `api` pool keeps 30 s timeouts and short requests.
- **Docker stack `darb/deploy`:**
  - nginx (Cloudflare real-IP ranges, per-IP rate limits, TLS include);
  - `api` (scalable, stateless), `slow`, `worker`, one-shot `migrate`;
  - Postgres 16 + **PgBouncer** (transaction pooling) + **pgBackRest** (WAL archive and full/diff backups to R2,
    encrypted) from one image.
- **CI** `.github/workflows/darb.yml`:
  - backend tests on Postgres 16;
  - Flutter analyze, test and a debug APK;
  - the whole stack with `--scale api=2` and a sync round trip through nginx → api → PgBouncer → Postgres plus a worker
    pass;
  - an iOS simulator build that launches the app (commits marked `[ios]`).
- **Docs:** [DARB-STORES.md](DARB-STORES.md), [DARB-INFRA.md](DARB-INFRA.md) (Contabo prices, latency from Saudi Arabia,
  sizing, upgrade path), [DARB-PDPL.md](DARB-PDPL.md), [DARB-DEVICES.md](DARB-DEVICES.md),
  [DARB-PROTOCOL.md](DARB-PROTOCOL.md), [DARB-NEEDS-ME.md](DARB-NEEDS-ME.md),
  [DARB-COMPETITORS.md](DARB-COMPETITORS.md).

**Verified**
- Backend: **17 tests** green locally on Postgres 16 and in CI. They cover the per-user cursor and isolation, last
  write wins, compact reviews (round trip, dedupe on resend, paging, validation, flags), the job queue (dedupe,
  reschedule, run-again, lease and retry, give-up) and the uploads pipeline on the queue with Haiku.
- App: **22 unit tests** green. The **end-to-end sync tests** (2) ran against a local Darb backend:
  - offline study on device A, sync, a fresh install B restores docs and the review log;
  - the free-text answer stays on the phone;
  - last write wins across devices;
  - two accounts on one phone never mix.
- CI run [38803156632](https://github.com/Jehadx17/certdeck/actions/runs/38803156632):
  - backend ✔;
  - **Docker stack ✔** (2 API containers behind nginx, sync through PgBouncer, a worker pass);
  - **iOS ✔**: built with Xcode 26.3 (17C529) and **launched on an iPhone SE-size simulator**. The screenshot shows the
    welcome screen, right-to-left, light theme.
- Android: see the launch line below.

**Cost so far:** $0. No VPS, no AI calls; CI used about 8 macOS minutes of the free allowance.

**Next:** phase 1 (accounts and billing). The backend half is already written and tested (see phase 1).
