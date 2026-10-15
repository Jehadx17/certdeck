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
- **Android:** the debug APK built locally (Gradle capped at 2 GB) and in CI run
  [38805925572](https://github.com/Jehadx17/certdeck/actions/runs/38805925572) (app job ✔, after turning off Jetifier,
  which ran CI out of heap). It **launched on an Android 7.0 (API 24) emulator, 480x800, 1 GB RAM**: displayed in 9.3 s;
  sign-in screen, sync with a local backend, onboarding in Arabic right-to-left.
- **Exit check met:** both apps build and launch (Android 7.0 emulator, iPhone SE-size simulator), and the backend, app
  and stack tests are green in CI.

**Cost so far:** $0. No VPS, no AI calls; CI used about 8 macOS minutes of the free allowance.

**Disk:** the toolchains filled the laptop (100% for a moment). I removed the API 36 emulator image and Darb's build
intermediates, both mine. Current-Android checks now run on the CI's Linux emulators and your HONOR phone.

**Next:** phase 1 (accounts and billing). The backend half is already written and tested (see phase 1).

## Phase 1: Accounts and billing (built; exit check waiting on accounts)

**Built**
- **Sign-in:**
  - Google (both platforms) and Apple (iOS). The backend verifies each ID token against the provider's JWKS: signature,
    issuer, audience, expiry, and Google's `email_verified`.
  - Each phone gets its own token; signing out deletes that phone's token.
  - Under-13 note on the sign-in screen.
- **Age gate:** a new account gives its birth year only (minimum data). Under 12 is refused. Under 18 (Saudi majority,
  counted conservatively) needs a **guardian's email confirmation** before anything syncs or reaches AI. The guardian's
  consent page confirms; the same link later withdraws consent, which deletes the account. Opt-in weekly summary.
  DARB_GUARDIAN_CONSENT switches it off.
- **Account deletion:** in the app (Settings → Delete my account), with the store-billing warning Apple requires.
  The server deletes everything (devices, docs, reviews, jobs, uploads), revokes the Apple refresh token, and deletes
  the RevenueCat subscriber.
- **Billing:**
  - RevenueCat with the app user id = the account's random public id.
  - The **webhook only triggers a re-read** of the subscriber from RevenueCat's REST API; the backend sets
    `premium_until`. The app's "I bought" / "restore" call does the same.
  - Paywall: store prices, annual first with its per-month price, free-trial label, restore, how to cancel, terms and
    privacy. Settings: status, manage or cancel (the store's page), restore.
  - Uploads and their pages are Plus-only (403 `premium`). Free keeps studying, samples and a small AI quota.
- **Onboarding:** segment → grade or track → exam and optional date. The answers go into the synced settings.

**Verified so far**
- 7 account tests: sign-in creates then finds the account; a second phone gets its own token; sign-out; forged,
  expired and wrong-audience tokens are rejected; age gate; minor waits for the guardian (sync 403), the guardian
  confirms by the emailed link, then sync works, then withdrawal deletes; deletion cascades and calls the revocations;
  **a subscription from webhooks grants uploads and a lapsed one loses them**; with the REST key the backend trusts
  only RevenueCat's subscriber record.
- On the API 24 emulator: sign-in (debug token), sync, onboarding in Arabic right-to-left, home.

**Exit check (end-to-end sandbox purchases on both platforms; a lapsed subscription loses access) needs from you**
(DARB-NEEDS-ME.md):
- items 4, 5, 8, 9, 10: store accounts, RevenueCat, the Google Cloud OAuth clients, the App Store Connect keys;
- the products `darb_weekly` / `darb_monthly` / `darb_annual` (SAR 19 / 29 / 199) in both stores, which I create once I
  have the API keys;
- sandbox testers.

## Phase 2: AI gateway (built; eval waiting on the Anthropic key)

**Built**
- **Haiku only:** `ai.call` refuses any other model. Opus and Sonnet exist only in the offline eval and pack pipeline.
- **Under 100k input tokens:** a size estimate, and the exact `count_tokens` for PDFs and large requests. Longer
  requests get 413 "pick fewer pages".
- **Hard monthly dollar cap per account** from real usage (`AiCall.cost_usd`):
  - free $0.03, Plus $0.50, plus a daily call quota (free 10, Plus 200);
  - all edited in the admin without an app update;
  - a 402 says when it resets ("comes back on <date>").
- **Cost levers:**
  - prompt caching on stable prefixes;
  - the Batch API for uploads more than 3 days before the exam;
  - **one shared answer** for the first explanation of the same card (any student), keyed by content + language +
    prompt version;
  - tight max_tokens per feature;
  - follow-ups resend only the last 4 turns.
- **Minors safeguards:** a safety and on-topic block first in every prompt (Anthropic does not publish its child-safety
  prompt; asking them is on your list), no names or emails in prompts, and AI text labelled in the app.
- **Admin** (`/darb-admin/`, Django admin):
  - find an account (email, id), see Plus status and AI spend;
  - reset its AI quota, suspend or restore it, re-read its subscription;
  - an AI spend page: month total, per paying account, by feature, by day, top accounts;
  - the caps. Reports read the replica when one is configured.
- **Eval harness** (`manage.py ai_eval`, set in `core/eval_set.json`):
  - 12 explanations (8 Arabic) with follow-ups, 10 graded answers with gold scores, 4 card-generation sets,
    6 re-teach cards, and an Arabic-quality check;
  - old setup vs Haiku, judged blind by Opus;
  - pass rules in code; writes [DARB-AI-EVAL.md](DARB-AI-EVAL.md) with cost per call and per typical session.

**Verified so far:** 7 gateway/admin/eval tests:
- Haiku-only, safety block first, short history;
- cap → 402 with the reset date, and the admin reset;
- the daily quota and the Plus limits;
- the 100k refusal;
- the shared cache: the second student costs nothing;
- the cost formula;
- admin lookup, spend page and quota reset;
- the eval harness end to end on mocked models.

**Exit check (eval shows Haiku passes per feature; cost per typical session measured) needs:** the Anthropic API key
(DARB-NEEDS-ME.md item 6). The run costs about $3-6.
