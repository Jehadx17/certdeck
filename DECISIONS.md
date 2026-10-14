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

## App updates (2026-10-13)
- The user asked for forced updates from the VPS. Android doesn't let a sideloaded app update silently in general, but
  since Android 12 an app may update *itself* without a prompt (PackageInstaller `USER_ACTION_NOT_REQUIRED` + the
  `UPDATE_PACKAGES_WITHOUT_USER_ACTION` permission, target SDK requirement met by 34), after the user grants
  "install unknown apps" once. Older Android or an OEM that insists falls back to the system's one-tap confirm.
- "Forced" = when the app learns of a newer build it covers the UI until the update is installed (cancelling just asks
  again on the next resume). It never blocks offline: studying must not depend on the network.
- The release lives outside the web root (`/opt/certdeck/release`, mounted read-only into the API) and is served only
  with the token; the `/dl/` link is a hard link for first installs on a new phone.

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

## Accounts (2026-10-13, COLLEGE.md)
- **Per-user data, one schema:** every doc, image, AI call and job belongs to an `Account` (`owner` = me: certs +
  college; `student`: college only). Doc ids are unique per account (`settings`, cert codes repeat), so the doc table
  was rebuilt with a `(user, doc_id)` key. Migration 0003 made the existing token the owner's and moved all existing
  data (208 docs, 28 images, AI history) to it, keeping every sync seq, so the phone kept working untouched. Checked
  first on a copy of the production rows, with a full DB + media backup on the server (`/opt/certdeck/backups/`).
- **A student's tabs** (1.3.6): College and Settings only, as COLLEGE.md says. A course's cards open from its
  course screen; the owner keeps Certs, Cards, AI and Exam.
- **Tokens are stored as sha256 hashes** and managed with `manage.py users` over SSH (create, rotate, disable, cap,
  delete). No admin UI, no sign-up (out of scope).
- **Media ownership:** files stay content-addressed and stored once, but `Media(user, name)` decides who may read one;
  a hash alone never grants access (an isolation test covers it).
- **Caps:** AI calls check the month's spend (`AiCall` per user) against `cap_usd` before running (402 past it);
  default $10 for students, none for the owner. Big jobs show an estimate first; Batch jobs are checked at submission
  and again, with the real numbers, before the expensive stage.
- **One phone, two people:** switching the token first checks it with the server (a typo changes nothing), pushes the
  current account's unsynced changes, wipes the local DB and images, then restores the new account. Found on the
  device test: the first version wiped before checking the token.

## College (2026-10-13)
- **Pipeline:** material → one PDF (LibreOffice for pptx/docx in a throwaway profile with a timeout, Pillow for photos)
  → sections (the PDF outline when it groups pages; PowerPoint exports carry one bookmark per slide, so those go to
  the model) → per assessment scope: extract knowledge points (READ model, one document per page so citations are exact
  pages) → priorities 1-5 → cards (WRITE model) → coverage pass → sheets. Backend-owned progress docs (`ingest`,
  `prep`, `prio`, `profile`, `sheet`) keep the single-writer rule; cards and proposed assessments are created once and
  owned by the app.
- **Model mix (measured, same three sections: calculus 13 pp, Arabic prose 4 pp, Java slides 7 pp):** Haiku 5.5 cost
  $0.002-0.005 per section but cited printed page numbers instead of the PDF's (9 of 29 points off on the calculus
  notes), dropped a letter in Arabic words (تتلك for تمتلك) and titled Arabic points in English. Sonnet 5.5
  ($0.04-0.09) was exact on pages and Arabic. Opus 5.5 ($0.08-0.22) found more, finer points. **READ = Sonnet 5.5**
  (`CERTDECK_READ_MODEL`), WRITE = Opus 5.5 (`CERTDECK_MODEL`).
- **Real runs:** CS 112 quiz (30 slides): 61 points → 107 cards, $1.32, under 3 minutes. MATH106 quiz (27 pp of notes,
  Batch API): 46 points → 82 cards incl. 48 problems, every answer verified by SymPy, $0.67. Arabic GS111 quiz
  (12 pp of dense prose): 102 points → 232 cards, $3.16, which exposed two estimate bugs:
  neighbouring sections share their boundary page, which was read (and carded) twice — now each page goes to one
  section; and dense prose holds ~4x the points per page of slides — the estimate now counts the text on each page
  (one point per ~180 characters, at least 1.5 per page, ~1.9 cards per point, ~$0.0124 per card).
- **Numeric answers are verified, never trusted:** the model states a SymPy check (numeric value, equivalent
  expression, derivative of an antiderivative, roots); the server evaluates it in a child process with CPU/memory/time
  limits after a token whitelist (no attribute access, no strings, only known function names). Failing or missing
  checks on numeric answers drop the problem.
- **Batch vs now:** assessments more than 3 days away are prepared through the Batch API at half price (each stage
  is one batch; the worker polls once a minute); closer ones run immediately, 4 requests at a time.
- **Study engine (app, offline):** mode by days left — sprint ≤ 3 (in-session successive relearning: right twice in a
  row, misses back after 3 cards, interleaved by section; yesterday's shaky cards first), compressed 4-14 (FSRS capped
  at the date, retention up to 0.95, new cards paced to finish 2 days early), long. Order = expected marks = priority ×
  (1 − recall); a time budget keeps 15% for repeats and splits the rest into master / skim / skip. Predicted mark is a
  range (recall blended with the last practice exam, ±8 to ±33 points depending on how much evidence there is).
  Daily plan per assessment is capped at 2 hours; "behind" only counts when a plan existed all of yesterday.
- **Written answers:** short answers and problems carry a rubric; the student ticks it, gives a quick verdict, or asks
  the AI (Opus, low effort; photos of handwritten work accepted). Partial credit rates Hard in FSRS.
- **Reminders:** `flutter_local_notifications` 17.2.4 (19.x needs AGP 8.6/SDK 35; this app is on AGP 7.3 with Flutter
  3.22) with core-library desugaring; that crashed the app at start on Android 16 until the WindowManager libraries
  were added (flutter/flutter#110658) — caught on the HONOR before publishing. Gson keep rules for the scheduled
  notifications. Reminders are re-planned on every open and when the app goes to the background.
- **Math:** `flutter_math_fork` 0.7.3 (0.7.4 needs a newer Flutter), `$…$` / `$$…$$` in every Markdown field; formulas
  stay LTR inside Arabic text. Text direction is per text block (most letters Arabic → RTL), so an Arabic card reads
  right-to-left in an English UI and vice versa.
- **Recordings removed (user's request, 2026-10-13):** lecture recordings were built (faster-whisper in a CPU/RAM-capped
  container) and measured at ~2x real time with the `small` model on 2 vCPUs, with English sentences in mixed lectures
  coming out as garbled Arabic. The user then asked to drop audio: code, container, its 3.45 GB image and the model
  volume were removed.

## Device-test fixes (2026-10-13)
- **Mixed Arabic/English text** (user report: hard to read, "overlaps"): the Unicode bidi algorithm reorders an
  English phrase's words and punctuation inside an Arabic sentence (and the other way round). Every run of the other
  script is now wrapped in a directional isolate (LRI/RLI … PDI) before Markdown rendering; a run continues across
  inline markup (bold, cloze ‹ ›) and takes the closing marker it opened, so "one copy per ‹class›" stays one unit;
  code, math and links are untouched. Names inside translated UI sentences use first-strong isolates. Plain-text
  titles take their direction from their own text. Cloze bold markers moved inside the brackets (`**[` after an Arabic
  letter wasn't bold).
- **Progress dialogs** close through their own context: an account switch or a language change rebuilds every screen
  (the home widget is keyed by language and role), which left the dialog of the screen that opened it on top forever.
- **Uploads:** returning from the file picker resumes the app, whose upload pass started before the new file was
  queued; a pass requested while one runs now runs again afterwards.
- **Polling:** every 30 s while the server processes material or prepares an assessment (so progress shows), every
  2 min while waiting on the Batch API or to push local changes.
- **Triage** shares the session's time across question formats (the professor's mix, else even): ranking only by marks
  per second filled a short session with the quickest cards (cloze) and never practised short answers.
- **Plan:** at most 2 hours a day per assessment (triage cuts the rest); "behind" only when the cards existed all of
  yesterday.
- **Syllabus:** when an assessment's coverage isn't written but the course plan lists topics by week, the coverage
  is inferred from the weeks since the previous assessment; scope suggestions read the syllabus pages.
- **Sync while a sync runs** (1.3.4): the request now waits for one more run after the current one (concurrent callers
  share it) instead of returning at once. A skipped sync left a processed photo on "waiting to upload", and hints
  typed during a sync reached the server only on the next 2-minute tick (a priorities update could read the old
  hints). An account switch refuses while anything is still unsynced, whatever the sync returned.
- **Budget refusal** is rebuilt from its amounts in the app's language: the server's message carries numbers, so the
  translation table can't match it whole.
- **Conversion failures** say what to do ("export it as PDF and upload that"). A .pptx that LibreOffice can't convert
  within the worker's 2 GB fails cleanly (a PDF re-imported as slides, every glyph a shape, needed 3 GB).
- **Account switch** (1.3.5): the sync asks the server who the token belongs to before downloading card images. On
  the HONOR one image download stalled for its 60 s timeout mid-restore, and the phone kept the old role (owner tabs
  over the student's data) until the next sync. The Settings screen no longer updates itself after the switch has
  rebuilt it (that crashed harmlessly).
- **Play Protect** on the HONOR asked to upload 1.3.4 to Google for a scan before installing the update (earlier
  versions installed without asking); the same signed APK was installed over adb instead, keeping the app's data.
  Another phone may show the same prompt: scanning and then installing is the phone owner's call.
- **Test student kept:** the `qa-student` account and its five sample courses stay on the server at the user's request
  (for their own testing); it has a $15 monthly cap.

## Easy student app (2026-10-14, EASY.md)
- **Audience:** college students, designed to the bar "a child could use it alone". Adult wording; no parent PIN
  (students do their own setup, under "My courses").
- **Home:** one card per prepared exam with one big "Study now" button; the most urgent exam first. Night-before
  and exam-morning buttons appear on the day they apply. Progress is shown as numbers (your answer, 2026-10-14: stars replaced): the share and count of the exam's cards
  learned, with a bar, instead of the predicted-mark range; the setup screens keep their numbers and costs.
- **One tap to study:** about 10 minutes, chosen by the engine (spaced when there's time, the sprint loop near the
  exam). The triage page and the minute chips are owner/setup tools now.
- **Confidence kept:** an earlier cut inferred it from answer time; you prefer rating it, so Guessing / Unsure /
  Sure are the Check button (one tap rates and reveals), and sure-but-wrong still flags a misconception.
- **Practice test:** 10 questions from the cards in the professor's format mix, offline and without AI cost;
  stars per topic (section titles from the material map) and a round of the missed ones.
- **Problems:** solution steps one at a time ("Next step"), then the verified answer; rubric ticks without weights.
- **Sign-in codes:** 8 characters from an alphabet without 0/O/1/I/L, sha256-stored, 24 h, single use; redeeming
  gives the phone a new token (the account's old token stops working) and wipes/restores the phone's copy like any
  account switch. Failed codes are throttled globally (30 per 10 minutes) rather than per IP, since every request
  reaches gunicorn from the docker gateway address.
- **Sizes** (1.4.1, at your request): normal app sizes, no extra text scaling: 50 dp main buttons with 16 sp text,
  56 dp confidence buttons, titles 18–22 sp. Text still follows the phone's own font-size setting.
- **Photos of handwritten work removed** (2026-10-14, at your request): they cost an AI vision call per grading for
  little benefit. Written answers are graded from the typed text (AI) or by the student's own verdict / rubric
  ticks; the server's college/grade no longer accepts images.
- **Short-answer cards: at most 5 words** (2026-10-14, at your request): the model answer is a term, name, number or
  short phrase; broad "explain" topics become several short cards or cloze/MCQ, and the detail lives in the
  explanation. The generation rules say so, and the server drops a short card whose answer is longer. Applies to new
  preparations and practice questions; existing cards keep their answers.

