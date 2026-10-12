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
