# CertDeck

Personal, offline-first, AI-powered spaced-repetition app for certification exams (DVA-C02 → SAA-C03 → CKAD), plus a
**College** side for a few invited students: they upload their course material and get cards, practice exams, sheets
and a study plan aimed at their next quiz, midterm or final.
Flutter Android app + Django backend. Specs: [SPEC.md](SPEC.md) (certs), [COLLEGE.md](COLLEGE.md) (college); design
decisions are in [DECISIONS.md](DECISIONS.md).

```
app/        Flutter app (Android): local SQLite, FSRS, all card types, study/exam/AI screens
backend/    Django + DRF: accounts, sync/backup, media, AI endpoints (Claude), college pipeline, FSRS optimizer
deploy/     Dockerfile, compose project, nginx server block, deploy script
docs/       PROTOCOL.md (app↔backend contract), cards.schema.json (import/export format)
examples/   cards.example.json (one card of every type, incl. an occlusion image)
```

## How it works (one paragraph)
Everything (cards, review logs, certs, settings, exam results, AI analyses, overrides, chats) is a *document*
stored in SQLite on the phone. Studying, scheduling (FSRS), browsing and exam simulations never need the
network. Every change is marked dirty and pushed to the backend on app open/resume, after each session,
every 10 minutes while there are changes, and via **Sync now**. The backend keeps a copy of every document plus the
images, so a fresh install + token = full restore. AI features call the backend (which holds the Anthropic
key) and show "Needs connection" when offline. See [docs/PROTOCOL.md](docs/PROTOCOL.md).

## App

Requirements on the laptop: Flutter 3.22.2 (`~/FlutterSDK/flutter`), JDK 17 (`~/opt/jdk17`), Android SDK
(`~/Android/Sdk`). The release keystore is `~/.config/certdeck/release.jks`, referenced by the gitignored
`app/android/key.properties`. **Back both up:** a different key means updates must uninstall first.

```bash
export JAVA_HOME=~/opt/jdk17 ANDROID_HOME=~/Android/Sdk PATH=~/opt/jdk17/bin:$PATH
cd app
flutter build apk --release                       # → build/app/outputs/flutter-apk/app-release.apk
~/Android/Sdk/platform-tools/adb install -r build/app/outputs/flutter-apk/app-release.apk   # phone on USB, USB debugging on
flutter test                                      # logic checks
# sync/restore end-to-end check against a running backend:
CERTDECK_TEST_URL=http://127.0.0.1:8765 CERTDECK_TEST_TOKEN=devtoken flutter test test/sync_test.dart   # needs a fresh backend DB (SQLITE_PATH=/tmp/x.sqlite3)
# + CERTDECK_TEST_TOKEN2=<a student's token> to also test switching accounts on one phone
```

**Updating the app (forced, from the server):** bump `version:` in `app/pubspec.yaml`, `flutter build apk --release`,
then `deploy/release-apk.sh`. It uploads the APK to `/opt/certdeck/release/` (served to the app by `GET /api/app/latest`
and `/api/app/apk`, token only) and prints a browser link for first installs (`/dl/…`). Every phone checks on open and
resume: if the server has a newer build, the app locks, downloads it (sha256-checked) and installs it, without a prompt on
Android 12+ once CertDeck may "install unknown apps" (asked once). Offline it keeps working and retries later.
Data is kept across updates (same signing key).

First run: **Settings → Backend & sync** → server URL `https://certdeck.mithaqstay.com` + API token →
**Save & sync**. On a new phone this restores everything.

### iOS (no App Store)
Needs macOS with Xcode (the laptop's Hackintosh partition works), an Apple ID, and the iPhone on USB.
One time: install Xcode, open it, Xcode → Settings → Accounts → add your Apple ID → Manage Certificates… →
+ → Apple Development. On the iPhone: tap Trust when connected, and turn on Settings → Privacy & Security →
Developer Mode.
```bash
# private repo: sign in first (brew install gh && gh auth login)
gh repo clone Jehadx17/certdeck && certdeck/app/build-ios.sh   # later: git pull && app/build-ios.sh
```
The script installs Flutter 3.22.2 and CocoaPods if missing, signs with your Apple ID's team and installs the app.
First launch: Settings → General → VPN & Device Management → trust your Apple ID. A **free** Apple ID signs for
7 days: re-run the script weekly (your data stays). A paid developer account ($99/yr) signs for a year
(`CERTDECK_TEAM=<team id>` picks the team if you have several).

## Backend

### Local development
```bash
cd backend
~/.local/bin/uv venv --python 3.12 .venv
~/.local/bin/uv pip install --python .venv/bin/python --index-strategy unsafe-best-match -r requirements.txt
.venv/bin/python manage.py migrate
.venv/bin/python manage.py test                  # 24 tests (accounts, isolation, caps, college pipeline), Anthropic mocked
CERTDECK_API_TOKEN=devtoken .venv/bin/python manage.py runserver 127.0.0.1:8765
```
Without `POSTGRES_DB` it uses SQLite. Env vars: see [backend/.env.example](backend/.env.example).

## College (students)
**The student app is the easy version** (EASY.md): new phones sign in with a short code
(`users code <name>` on the server prints it; valid 24 h, once), the home shows one big **Study now** button per
prepared exam, and the setup below lives under **My courses**.

How it works: a student adds a **course**, uploads its **material** (slides as PDF or PowerPoint, notes, a textbook,
photos of pages, the syllabus, past quizzes) and confirms its **quizzes & exams** (the syllabus proposes them with
weeks and weights). For each one they pick what it covers (chapters, lectures) and add the professor's hints, then tap
**Prepare**: after a cost estimate, the server reads exactly those pages, extracts every examinable point (cited by
page), ranks them for this assessment (hints, the professor's past papers, the syllabus), writes cards and practice
problems (math answers verified by computer algebra) and summary / key-facts / formula sheets. Studying is offline:
**sprint** mode with ≤ 3 days left (time-budgeted, most marks first, right twice in a row), **compressed** with 4-14
days, long-term otherwise; plus practice exams in the professor's format (AI or rubric grading, photos of handwritten
work), a predicted-mark range, a night-before sheet, an exam-morning check and daily reminders. Arabic and English,
right-to-left included (Settings → Language). Details: [DECISIONS.md](DECISIONS.md) → College.

**Add a student** (on the server, see *Accounts and tokens* below): `users create <name>` prints a token; give them
the token and the server URL `https://certdeck.mithaqstay.com`. They see only College, Cards and Settings.

**Install for a student**
- Android: send them the browser link printed by `deploy/release-apk.sh` (`https://certdeck.mithaqstay.com/dl/…`),
  they allow the install, open CertDeck → Settings → Backend & sync → URL + token → Save & sync. Updates arrive by
  themselves (the same forced update as mine).
- iPhone: only through your Mac (see *iOS* below): their iPhone on USB, `app/build-ios.sh`. With a free Apple ID the
  app stops opening after 7 days until you run the script again with their phone plugged in (their data stays);
  a paid developer account ($99/year) makes it a yearly chore. iOS has no self-update: re-run the script for updates.
- One phone, two accounts: entering another token pushes the current account's changes, clears the phone and
  restores the other account (a wrong token changes nothing).

**Cost** (Anthropic, charged to the student's monthly cap, default $10): roughly $0.04-0.08 per page of lecture
slides or notes and $0.15-0.25 per page of dense prose prepared now, half that through the Batch API (assessments
more than 3 days away); the app shows the estimate before anything runs. Grading a written answer ≈ $0.01-0.02,
a fresh practice question ≈ $0.02.

### Production (169.58.7.222, root)
Isolated compose project in `/opt/certdeck` (own Postgres, volumes, network; API on `127.0.0.1:18765`),
served at `https://certdeck.mithaqstay.com/api/` by the host nginx (site file `deploy/nginx-certdeck.conf` →
`/etc/nginx/sites-available/certdeck`), with a Let's Encrypt cert renewed by the existing `certbot.timer`.
See DECISIONS.md → Deployment.

```
/opt/certdeck/.env     secrets + settings (chmod 600, never in git)
/opt/certdeck/src/     code, replaced on every deploy
```

**Update / redeploy** (from the laptop, after committing):
```bash
deploy/deploy.sh          # git archive HEAD → server, docker compose up -d --build; migrations run on start
```

Useful on the server:
```bash
cd /opt/certdeck/src/deploy
alias dc='docker compose --env-file /opt/certdeck/.env'
dc ps; dc logs -f certdeck-api          # token usage per AI call is logged ("ai generate ok=True in=… out=…")
dc logs -f certdeck-college             # course material processing and assessment preparation
dc exec certdeck-api python manage.py optimize_fsrs
curl -s 127.0.0.1:18765/api/health
```

### Accounts and tokens
Every phone uses a token that belongs to an **account**: `owner` (me: certs + college) or `student` (college only).
The owner account was created from the old single `CERTDECK_API_TOKEN` (migration 0003), so that token keeps
working; `CERTDECK_API_TOKEN` in `.env` is not read after that. Manage accounts on the server:
```bash
ssh root@169.58.7.222
cd /opt/certdeck/src/deploy && alias users='docker compose --env-file /opt/certdeck/.env exec certdeck-api python manage.py users'
users create sara              # a student with the default $10/month AI cap; prints her token (shown once)
users create sara --cap 20     # another cap; --cap none = no cap
users list                     # everyone, with this month's AI spend
users cap sara 15              # change a cap
users rotate sara              # new token; the old one stops working (use `users rotate owner` for mine)
users disable sara             # block access, keep data (`enable` restores)
users delete sara --yes        # delete the account and all its data
```
The student enters the server URL and token once in Settings → Backend & sync. Change the Anthropic key
(`ANTHROPIC_API_KEY` in `/opt/certdeck/.env`) and restart with `docker compose --env-file /opt/certdeck/.env up -d`.

### Remove CertDeck from the server
`rm /etc/nginx/sites-enabled/certdeck && nginx -t && systemctl reload nginx`, then
`docker compose --env-file /opt/certdeck/.env down` in `/opt/certdeck/src/deploy` (add `-v` to delete the data).

## AI cost
- Every AI call is logged with its token counts and $ cost (`AiCall`); Settings shows **AI spend this month**
  (`GET /api/usage`). Server logs: `ai generate ok=True in=… out=… $0.0821`.
- **Background generation** (toggle on the Generate tab, also used by one-tap actions) goes through the Message
  Batches API at 50% off; the `certdeck-batches` service finishes jobs (usually within minutes) and the app picks
  the cards up on its next sync.
- **Diagrams:** every card is looked at once (existing deck, imports, new AI cards; not occlusion cards or cards that
  already have an answer image). In the background (Batch API, ~$0.005 per card) the AI draws a diagram when a
  picture helps: architecture (Region/AZ/VPC boxes with official AWS/Kubernetes icons), numbered flows, side-by-side
  tables, lifecycles. The server renders it with Graphviz (`core/diagram.py`, icons in `core/icons/`) and the app adds
  it to the card's answer images on the next sync (tap it to zoom; remove it in the card editor).
  `CERTDECK_AUTO_DIAGRAMS=false` in the server `.env` turns this off.
- Model: `CERTDECK_MODEL` in `/opt/certdeck/.env` (default `claude-opus-5-5`; `claude-sonnet-5-5` is ~2.5x cheaper,
  see DECISIONS.md). Restart `certdeck-api` and `certdeck-batches` after changing it.

## Import / export
Format: [docs/cards.schema.json](docs/cards.schema.json) (JSON Schema). Example:
[examples/cards.example.json](examples/cards.example.json). Images are inlined as base64 under `media`
(name = `sha256.ext`).
- On the phone: Settings → Export cards to a file (share/save) / Import cards from a file.
- Through the backend: Settings → Export from server / Import a file through the server, or directly:
  `curl -H "Authorization: Bearer $TOKEN" https://certdeck.mithaqstay.com/api/export > cards.json` and
  `curl -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data @cards.json https://certdeck.mithaqstay.com/api/import`.

## Verification (2026-10-12)
- Backend: 11 Django tests; on the live server (HTTPS, Postgres) token auth, sync, import/export and every AI
  endpoint with the real key: generate from cert/domain, pasted text, PDF and screenshot; dedupe; cross-cert retag;
  CKAD exam-style; explain chat; fill; leech variants; weakness analysis with bounded overrides; optimizer threshold.
- App: logic tests + an end-to-end sync/restore test (`test/sync_test.dart`). On real phones (OnePlus 12, HONOR
  Magic8 Lite): fresh-install token restore, study session with confidence and misconceptions, every card type
  (incl. drag-to-order, typed lenient matching, code highlighting, occlusion creation with drawn regions), search and
  card history, in-app generation and one-tap actions, override revert, MCQ and CKAD exam simulations, import
  from file, export via share sheet, AI chat, and offline mode (network blocked for the app): studying works, AI shows
  "Needs connection", and offline reviews sync on reconnect.
- Final acceptance on the HONOR Magic8 Lite (the OnePlus 12 was unavailable; done there at the user's request): clean
  install starts empty → token → a card created and studied offline → reconnect sync → uninstall/reinstall → token →
  card, FSRS state and review history restored. Server test data was then wiped; the app was left installed,
  connected and empty.

## Verification (2026-10-14, easy student app, EASY.md)
- On the HONOR, 1.4.0: a fresh account (`kid-test`) signed in with a sign-in code in about 20 s; first-run intro,
  empty home, Help, My courses (the setup screens). On `qa-student` (Arabic): from a cold open, one tap on
  "Study now" reaches the first question; Guessing / Unsure / Sure reveal the answer; "Did you get it?" for
  self-graded cards; feedback with the source page; a practice test ending in a score per topic and a round of the
  missed ones; night-before sheet + quick review; exam-morning warm-up; a problem's steps one at a time. With the
  app's network blocked, sessions and a practice test ran with no error, and 63 answers synced on reconnect. The
  owner's screens and data are unchanged (137 cards incl. the 77 imported, 142 reviews). App tests (15) and backend
  tests (incl. sign-in codes) pass.
- On 1.4.1 (normal sizes), every student screen was audited on the HONOR with a screenshot and a text check (no
  %, $, delete, setup jargon or error text): the intro (3), home, Help (2), a question, its revealed answer, the next
  card, exam morning, night-before and its sheet, a practice question, the practice end screen and the missed round.
  Repeated on 1.4.2 (photos of work removed) in Arabic and in English: no flags.

## Verification (2026-10-13, college)
- Backend: 24 Django tests (accounts and isolation incl. media by hash, caps, users command, uploads with resume and
  type checks, material → structure → syllabus proposals → preparation → verified problems → sheets → grading, batch
  mode, page dedupe). Migration 0003 rehearsed on a copy of the production rows, then run in production after a DB +
  media backup; afterwards the owner's 60 cards (FSRS state), 142 reviews, cert, settings and jobs were compared field by
  field with the pre-migration copy: identical.
- Live AI runs on the sample material (test student `qa-student`): MATH106 notes (279 pp, syllabus → 5 proposed
  assessments), Discrete Math slidebook (383 pp → 12 lectures), Arabic GS111 (74 pp), CS 112 slides (PDF and a real
  .pptx), English units, a photographed page, a past quiz (→ professor profile with formats and traps). Prepared:
  CS quiz (107 cards, $1.32), MATH quiz through the Batch API (82 cards, 48 problems all SymPy-verified, $0.67),
  Arabic quiz (232 cards, $3.16, which led to the estimate/page fixes), English quiz from the phone (23 cards, $0.26
  against a $0.43 estimate). Model mix measured (DECISIONS.md → College).
- App: 15 logic tests (modes, triage by format and expected marks, sprint loop, partial credit, rubric/numeric
  scoring, cloze/LaTeX/bidi text) + end-to-end sync, restore and account-switch tests against a local backend.
- On the HONOR Magic8 Lite (Android 16): 1.2.2 → 1.3.x keeps the owner's deck; switching to the student and back
  (wrong token changes nothing); Arabic UI right-to-left; uploads from the phone's file picker; syllabus proposal
  confirmed and its scope suggested from the course plan; a 15-minute sprint (triage, misses coming back, a
  misconception); practice exam in the professor's format with fresh AI questions and AI grading of written answers;
  night-before sheet; exam-morning check; reminders scheduled (daily plan, eve of the exam, exam morning); preparing
  an assessment from the phone with the cost estimate; offline study with the app's network blocked, synced on
  reconnect; the forced update installing 1.3.1, 1.3.2 and 1.3.3 by itself. Then (1.3.3 → 1.3.4): a page photo
  chosen from the gallery (5 sections read from it); the professor's hints typed on the phone re-ranking the
  priorities (the hinted points rose to the top); a problem self-graded "Partly" offline, synced as a review with
  score 0.5; the monthly cap refusing AI work, with the message in Arabic, then restored. On 1.3.5: the Calculus formula sheet
  in the English UI (display and inline LaTeX), after the problem cards in the Arabic UI; switching the phone from the
  student back to the owner (English, 6 tabs, the AWS deck with its exam date and readiness). On 1.3.6 the student
  sees only College and Settings and opens a course's 107 cards from the course; the owner keeps all 6 tabs. iOS was not tested on a
  device (at the user's request); the iOS project builds the same code with `app/build-ios.sh`.
