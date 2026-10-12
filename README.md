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
CERTDECK_TEST_URL=http://127.0.0.1:8765 CERTDECK_TEST_TOKEN=devtoken flutter test test/sync_test.dart
```

Updating the app = bump `version:` in `app/pubspec.yaml`, rebuild, `adb install -r` (data is kept).

First run: **Settings → Backend & sync** → server URL `https://certdeck.mithaqstay.com` + API token →
**Save & sync**. On a new phone this restores everything.

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

### Production (VPS 217.76.55.241, user `deploy`)
Isolated compose project in `~/certdeck` (own Postgres, volumes, network; API on `127.0.0.1:18765`),
reachable at `https://certdeck.mithaqstay.com/api/` through the existing wa-category nginx container (one added
server block, `deploy/nginx-certdeck.conf`) with its own Let's Encrypt cert renewed by its own certbot
container. Details and the reasons behind them are in DECISIONS.md → Deployment.

```
~/certdeck/.env            secrets + settings (chmod 600, never in git)
~/certdeck/proxy.enabled   marker: include docker-compose.proxy.yml (proxy network + certbot)
~/certdeck/letsencrypt/    our certbot state
~/certdeck/src/            code, replaced on every deploy
```

**Update / redeploy** (from the laptop, after committing):
```bash
deploy/deploy.sh          # git archive HEAD → VPS, docker compose up -d --build; migrations run on start
```

Useful on the VPS:
```bash
cd ~/certdeck/src/deploy
alias dc='docker compose -f docker-compose.yml -f docker-compose.proxy.yml --env-file ~/certdeck/.env'
dc ps; dc logs -f certdeck-api          # token usage per AI call is logged ("ai generate ok=True in=… out=…")
dc exec certdeck-api python manage.py optimize_fsrs
curl -s 127.0.0.1:18765/api/health
```

### Change the API token
```bash
ssh deploy@217.76.55.241
NEW=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
sed -i "s/^CERTDECK_API_TOKEN=.*/CERTDECK_API_TOKEN=$NEW/" ~/certdeck/.env && echo "$NEW"
cd ~/certdeck/src/deploy && docker compose -f docker-compose.yml -f docker-compose.proxy.yml --env-file ~/certdeck/.env up -d certdeck-api
```
Then in the app: Settings → API token → Save & sync. The Anthropic key (`ANTHROPIC_API_KEY`) is changed the same way.

### Remove CertDeck from the proxy
Delete `~/wa-category/deploy/nginx/conf.d/certdeck.conf`, run
`docker exec wa-category-nginx-1 nginx -t && docker exec wa-category-nginx-1 nginx -s reload`, then
`docker compose … down` in `~/certdeck/src/deploy`.

## Import / export
Format: [docs/cards.schema.json](docs/cards.schema.json) (JSON Schema). Example:
[examples/cards.example.json](examples/cards.example.json). Images are inlined as base64 under `media`
(name = `sha256.ext`).
- On the phone: Settings → Export cards to a file (share/save) / Import cards from a file.
- Through the backend: Settings → Export from server / Import a file through the server, or directly:
  `curl -H "Authorization: Bearer $TOKEN" https://certdeck.mithaqstay.com/api/export > cards.json` and
  `curl -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data @cards.json https://certdeck.mithaqstay.com/api/import`.
