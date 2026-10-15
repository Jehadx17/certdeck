# Darb (درب)

A subscription study app for Saudi students, built from CertDeck's code as a separate app (`sa.darbedu.app`) with its
own backend. CertDeck (`../app`, `../backend`, `../deploy`) is untouched. Spec: [../docs/GOAL-DARB.md](../docs/GOAL-DARB.md).
Docs: `../docs/DARB-*.md` (protocol, devices, infra, stores, PDPL, phases, and what I need from you).

```
app/      Flutter 3.35.7 app (Android API 24+, iOS 13+)
backend/  Django + DRF + Postgres (one DATABASE_URL), job queue worker
deploy/   Docker stack: nginx, api pool, slow pool (AI + uploads), worker, Postgres + PgBouncer + pgBackRest
```

## Backend
```bash
cd darb/backend
~/.local/bin/uv venv --python 3.12 .venv
~/.local/bin/uv pip install --python .venv/bin/python --index-strategy unsafe-best-match -r requirements.txt
export DATABASE_URL=postgres://postgres@127.0.0.1:5432/darb DJANGO_DEBUG=true
.venv/bin/python manage.py migrate
.venv/bin/python manage.py test core            # Postgres needed (the review table is partitioned)
.venv/bin/python manage.py users create me@example.com   # a dev account + device token
.venv/bin/python manage.py runserver 127.0.0.1:8765
.venv/bin/python manage.py worker               # the job queue (uploads, autopilot, re-teach, maintenance)
```

## App
```bash
export JAVA_HOME=~/opt/jdk17 PATH=~/opt/jdk17/bin:~/FlutterSDK/flutter-3.35.7/bin:$PATH
cd darb/app
flutter test
flutter run --dart-define=DARB_API=http://10.0.2.2:8765    # emulator -> local backend (debug: dev-token field)
DARB_TEST_URL=http://127.0.0.1:8765 DARB_TEST_TOKEN=<t1> DARB_TEST_TOKEN2=<t2> flutter test test/sync_test.dart
```

## Stack
```bash
cd darb/deploy && cp .env.example .env    # fill in secrets
docker compose --env-file .env up -d --build --scale api=2
```
CI (`.github/workflows/darb.yml`) runs the backend tests, the Flutter tests and an APK build, the whole Docker stack
with a sync round trip through nginx and PgBouncer, and (run it by hand) an iOS simulator build that launches the app.
