# Decisions

Significant choices made while building CertDeck, newest at the bottom of each section.

## Data & sync
- **Everything is a document** `{id, kind, data, updated_at, deleted}` (docs/PROTOCOL.md). The backend stores
  them in one `Doc` table (JSONB) instead of ~10 relational models. Single user, small data: Python-side
  filtering for analysis is fine, and sync, backup and restore become one generic code path.
- **Sync = push dirty docs + pull by global `seq` cursor**, last-write-wins on `updated_at`. Writers lock a
  single counter row, so seqs commit in order and a cursor never skips a write.
- **Single-writer rule:** the backend only *creates* docs (AI cards, analyses, overrides, FSRS params); the app
  is the only writer afterwards. That makes LWW safe without field-level merging. Retags suggested by the
  AI are therefore applied by the app, not the server.
- **Images are content-addressed** (`sha256.ext`), uploaded/downloaded separately from docs; idempotent and deduped.
- **App DB:** sqflite (SQLite) with one `docs` table mirroring the server plus a few denormalized columns
  (due, certs, card_id, ts) for queries. No codegen (Drift) needed. Config docs (certs, settings) are seeded
  with `updated_at = 0` so a restore from the server always wins.
- **Auth:** one long-lived bearer token from the backend `.env` compared with `hmac.compare_digest`; no Django
  users/sessions/admin. The app keeps it in `flutter_secure_storage`.

## Scheduling
- **FSRS-6 on both sides:** Dart `fsrs` 2.0.1 and Python `fsrs` 6.x both use 21 parameters, so optimizer
  output drops straight into the app. Flutter 3.22 pins `meta` 1.12, so `meta` is overridden (fsrs only uses
  `@visibleForTesting`).
- **Confidence → rating:** wrong → Again; Guessing/Unsure + correct → Hard; Sure + correct → Good, or Easy
  when the previous answer was also Sure + correct (consistently confident cards get pushed further without
  inflating every first success).
- **Misconception** (Sure + wrong): flagged, explanation shown prominently, due capped at +1 day until
  answered Sure + correct twice in a row; heavily weighted in the analysis prompt and the cram queue.
- **Leech:** lapses (Again on a review-state card) ≥ threshold, default 5 (Settings). Flagged, not
  auto-suspended (spec: "I can also suspend it").
- **Exam-date pacing:** desired retention ramps 0.90 → 0.95 over the last 60 days; max interval = days to the
  exam; new cards/day = max(user limit, remaining unseen ÷ (days − buffer)), buffer = min(14, days/4).
  New cards are interleaved by exam domain weight (greedy: most under-introduced domain first).
  Final 7 days: "Final review" (misconceptions, weakest domains, lowest recall first).
- **AI overrides** are bounded server-side (≤10 per analysis, ≤50 cards each, shift ±30 days, priority ±2),
  applied by the app on arrival with the previous due/priority saved in the override doc, shown in the
  card history, and revertible (due is only restored if the card wasn't reviewed since).
- **FSRS optimizer** needs ≥512 reviews spread over days (py-fsrs batch size), so the weekly job skips until then.

## AI
- Model `claude-opus-5-5`, `output_config.effort = "medium"`, structured outputs via `output_config.format`
  (JSON schema), streaming, no `thinking` param (always on for this model), server-side refusal fallback
  (`fallbacks: "default"`). Verified against the Claude API reference on 2026-10-12.
- Generation is grounded in condensed official exam guides stored in `backend/core/guides/`.
- **Dedupe:** the prompt lists existing cards (id | cert:domain | question) and asks for gaps only, plus a
  difflib ≥0.85 post-filter. No embeddings (would need another API/key); fine for thousands of cards.
- AI responses are validated semantically (option counts, indices, cloze blanks…) and invalid cards dropped.
- AI calls are synchronous with long timeouts; whatever they create is saved as docs first, so a dropped
  phone connection loses nothing (next sync pulls it).

## Diagrams (2026-10-13)
- The user is a visual learner and asked for diagrams on new AI cards, imported cards and the existing deck, of four
  kinds (architecture, flows, side-by-side, lifecycles), drawn only "when it helps".
- The model returns a small JSON spec (groups, nodes with icon keys, edges, or a comparison table), never code, and
  the server renders it with Graphviz using the official AWS / Kubernetes icons (vendored from the MIT-licensed
  `diagrams` package, 128 px, ~1 MB). Card text can come from imports, so every label is escaped and only vendored
  icon files are referenced.
- One sweep in the `certdeck-batches` loop covers every path (imports, app-made and AI cards): cards no diagram job has
  seen, 2 minutes after their last change, 15 per Batch API request. A card is retried once if a job fails.
- Single-writer rule kept: the job doc carries `{card_id, image}` and the app appends the image to the card's
  `answer_images` (like retags). The app applies jobs before its media pass so the image arrives in the same sync.

## Exams
- Formats checked against official guides on 2026-10-12: DVA-C02 and SAA-C03 = 65 questions (50 scored),
  130 min, scaled 100–1000, pass 720; CKAD = performance-based, 2 h, pass 66%, 5 domains (20/20/15/25/20),
  simulated with 17 typed/YAML tasks.
- Scaled score is a piecewise-linear map that puts the pass % (72) exactly at 720 (AWS doesn't publish its
  scaling). Flagged answers feed FSRS as "Unsure", others as "Sure"; unanswered ones aren't fed.

## Tooling
- The laptop's Flutter is 3.22.2 (shared with other projects), so the app stays on it with 2024-era plugin
  versions rather than upgrading the SDK. JDK 17 and the Android SDK are installed under `~/opt` and
  `~/Android/Sdk`. Gradle heap capped at 1.5 GB (the laptop OOM-killed the default 4 GB).
- The release keystore lives outside the repo in `~/.config/certdeck/release.jks` (`app/android/key.properties`, gitignored).
- iOS is built on macOS by `app/build-ios.sh` (xcodebuild with automatic signing for the connected iPhone, then
  `devicectl` install): no App Store, works with a free Apple ID (7-day signature) or a paid team (1 year).

## Deployment (VPS)
- At the user's request the backend runs on **169.58.7.222** (the server that hosts mithaqstay.com), not the
  first VPS (217.76.55.241). Everything deployed there during setup was removed and the other project there
  was verified unaffected before and after.
- Read-only inspection of 169.58.7.222: host nginx (systemd) with one site per project (`mithaqstay`, `uptick`),
  host certbot using the nginx authenticator on the stock `certbot.timer` with no custom hooks, and the other
  projects in Docker bound to `127.0.0.1` (`:8000`, `:3100`).
- CertDeck is its own compose project in `/opt/certdeck` (project `certdeck`): own Postgres 16 container + volume,
  own media volume, own internal network, API only on `127.0.0.1:18765`. Secrets are in `/opt/certdeck/.env`
  (generated on the server, chmod 600). Code is shipped with `git archive` by `deploy/deploy.sh`, so no GitHub
  credentials live on the server.
- nginx: one added site, `/etc/nginx/sites-available/certdeck` (+ symlink); `nginx -t`, then a graceful
  `systemctl reload nginx`. Other sites' responses were checked before and after.
- TLS: `certbot certonly --nginx -d certdeck.mithaqstay.com`, the same authenticator the existing certs use, so the
  existing timer renews it. `certonly` means certbot never edits our site file.
- Lesson from the first VPS, kept in case it ever moves back: there, the shared certbot's deploy hook copied every
  renewed cert over another site's live cert, and Docker DNS answers to *service names* on shared networks.
  So: never reuse another project's certbot, and give services unique names (`certdeck-api`, `certdeck-db`).
- FSRS re-optimization runs weekly in a small `certdeck-optimizer` container (a sleep loop; no host cron needed).

## Acceptance device
- The OnePlus 12 was unavailable for the final run, so at the user's direction the final acceptance (clean install
  starts empty, offline study, token restore after reinstall) ran on a HONOR Magic8 Lite, and the user accepted it
  as final (2026-10-12). The OnePlus 12 still has an earlier test build: uninstall it before first use, then install
  `app-release.apk` and enter the token.

## Cost optimization (2026-10-12)
Profile from the AiCall log (15 calls, $1.22): output 67% (about half of it thinking at medium effort), cache
writes 29% with **zero** cache reads, regular input 3%; card generation ~80% of spend (~$0.015–0.02 per card).
Rates from the platform pricing page (Opus 5.5: $4 in, $5 cache write, $0.20 cache read, $20 out; Batch API 50% off).
- **Applied:** per-call $ cost + `GET /api/usage` + "AI spend this month" in Settings; one cached system block per
  cert (prompt + certs + official guide) with the per-request card list after the cache point (verified live: the
  2nd generation read 5,096 cached tokens and wrote none); the 300 most relevant existing cards instead of the
  whole deck (keeps per-generation input flat as the deck grows; difflib still dedupes against every card); no
  cache writes on one-shot calls; **background generation via the Message Batches API** (50% off, opt-in toggle,
  also used by one-tap actions; finished by the `certdeck-batches` poller; refusal fallback omitted there because
  the Batch API rejects it).
- **Not applied (user's choice):** shorter, de-duplicated MCQ explanations.
- **Compared, not switched:** Sonnet 5.5 vs Opus 5.5 on an identical request: both accurate; Sonnet ~2.5x cheaper
  per card but shallower (weaker cloze, no cross-cert tagging, fewer exam traps). Kept Opus 5.5 (spec default);
  switching is `CERTDECK_MODEL=claude-sonnet-5-5` in the server `.env`.
- **Skipped:** tool search, compaction/context editing (no agent loops), Files API, 1-hour cache, lower `max_tokens`,
  lower effort (spec says medium; no eval to prove it safe).
