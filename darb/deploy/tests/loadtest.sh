#!/usr/bin/env bash
# Load test of the whole stack (docs/DARB-LOADTEST.md): 2 api containers behind nginx, PgBouncer, Postgres, the slow
# pool with AI stubbed at real latency. Stage 1: 100 students at 1 req/s each for 5 min (the 100k-student peak).
# Stage 2: 300 students for 2 min (launch-day spike). Prints the report; artifacts in tests/out/.
set -euo pipefail
cd "$(dirname "$0")/.."
# Absolute paths: the script cds into tests/. The override makes nginx trust the test's CF-Connecting-IP (each simulated
# student is its own IP, as behind Cloudflare), so the per-IP limits still apply but per student, not to the one CI IP.
DC="docker compose --project-directory $PWD --env-file $PWD/.env -f $PWD/docker-compose.yml -f $PWD/tests/loadtest.compose.yml"
env_get() { grep "^$1=" .env | tail -1 | cut -d= -f2- || true; }  # not sourced: placeholders like <account-id> aren't shell
HTTP_PORT=$(env_get HTTP_PORT); POSTGRES_USER=$(env_get POSTGRES_USER); POSTGRES_DB=$(env_get POSTGRES_DB)
trap 'echo "== FAILED; logs:"; $DC logs --tail 60 db api slow nginx' ERR
mkdir -p tests/out
sed 's#real_ip_header#set_real_ip_from 172.16.0.0/12; real_ip_header#' nginx.conf > tests/out/nginx-loadtest.conf
$DC build
$DC up -d --scale api=2
for i in $(seq 1 60); do curl -fsS localhost:${HTTP_PORT:-80}/api/health >/dev/null 2>&1 && break; sleep 2; done
curl -fsS "localhost:${HTTP_PORT:-80}/api/health?deep=1" >/dev/null  # up, through nginx, PgBouncer and Postgres
$DC exec -T api python manage.py loadtest_seed --accounts 3000 > tests/tokens.txt
cd tests
stats() { docker stats --no-stream --format '{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}}' > "out/docker-$1.txt"; }
( sleep 150; stats steady ) &
locust -f locustfile.py --headless -u 100 -r 20 -t 5m --host http://localhost:${HTTP_PORT:-80} --csv out/steady --only-summary 2>&1 | tail -25
( sleep 60; stats spike ) &
locust -f locustfile.py --headless -u 300 -r 50 -t 2m --host http://localhost:${HTTP_PORT:-80} --csv out/spike --only-summary 2>&1 | tail -25
cd ..
$DC exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT xact_commit, xact_rollback, round(100.0*blks_hit/nullif(blks_hit+blks_read,0),2) AS cache_hit_pct, deadlocks FROM pg_stat_database WHERE datname=current_database()" > tests/out/postgres.txt
$DC exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT relname, n_live_tup, pg_size_pretty(pg_total_relation_size(relid)) FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 6" >> tests/out/postgres.txt
cat tests/out/*.txt
