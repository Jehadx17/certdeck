# CertDeck

Personal, offline-first, AI-powered spaced-repetition app for certification exams (DVA-C02 → SAA-C03 → CKAD).
Flutter Android app + Django backend. The spec is in [SPEC.md](SPEC.md); design decisions are in [DECISIONS.md](DECISIONS.md).

```
app/        Flutter app (Android): local SQLite, FSRS, all card types, study/exam/AI screens
backend/    Django + DRF: sync/backup, media, AI endpoints (Claude), FSRS optimizer, import/export
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
```

Updating the app = bump `version:` in `app/pubspec.yaml`, rebuild, `adb install -r` (data is kept).

No USB? Upload the APK and open the link on the phone (nginx serves `/opt/certdeck/dl/` at `/dl/`, no listing):
`scp app/build/app/outputs/flutter-apk/app-release.apk root@169.58.7.222:/opt/certdeck/dl/certdeck-<random>.apk`
→ `https://certdeck.mithaqstay.com/dl/certdeck-<random>.apk`.

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
.venv/bin/python manage.py test                  # 11 tests, Anthropic calls mocked
CERTDECK_API_TOKEN=devtoken .venv/bin/python manage.py runserver 127.0.0.1:8765
```
Without `POSTGRES_DB` it uses SQLite. Env vars: see [backend/.env.example](backend/.env.example).

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
dc exec certdeck-api python manage.py optimize_fsrs
curl -s 127.0.0.1:18765/api/health
```

### Change the API token
```bash
ssh root@169.58.7.222
NEW=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
sed -i "s/^CERTDECK_API_TOKEN=.*/CERTDECK_API_TOKEN=$NEW/" /opt/certdeck/.env && echo "$NEW"
cd /opt/certdeck/src/deploy && docker compose --env-file /opt/certdeck/.env up -d certdeck-api
```
Then in the app: Settings → API token → Save & sync. Change the Anthropic key (`ANTHROPIC_API_KEY`) the same way.

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
