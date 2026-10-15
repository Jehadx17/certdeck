#!/usr/bin/env bash
# Backup + restore test (docs/DARB-RESTORE.md): seed data, full encrypted pgBackRest backup (a separate repository
# volume here, R2 in production), more writes + WAL archive, destroy the database volume, restore, and compare every row.
# Run from darb/deploy with a filled .env (ARCHIVE_MODE=on and the PGBACKREST_* settings). Prints a report; exits
# non-zero if anything differs.
set -euo pipefail
cd "$(dirname "$0")/.."
DC="docker compose --env-file .env -f docker-compose.yml -f tests/docker-compose.restore.yml"
REVIEWS=${REVIEWS:-500000}
t() { date +%s.%N; }
sql() { $DC exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"; }
set -a; . ./.env; set +a

$DC up -d --build db pgbouncer migrate api nginx
for i in $(seq 1 60); do curl -fsS localhost:${HTTP_PORT:-80}/api/health >/dev/null 2>&1 && break; sleep 2; done
TOKEN=$($DC exec -T api python manage.py users create restore@example.com | sed 's/Token: //')

echo "== seed: $REVIEWS reviews + docs"
T0=$(t)
ACC=$(sql "SELECT id FROM core_account WHERE email='restore@example.com'")
sql "INSERT INTO core_review (account_id, seq, ts, card, rating, flags, duration_ms)
     SELECT $ACC, g, (extract(epoch from now())*1000)::bigint - (g % 200)::bigint * 86400000 - g, 'qudurat-verbal:' || (g % 1200), 1 + g % 4, g % 64, 4000
     FROM generate_series(1, $REVIEWS) g" >/dev/null
for i in $(seq 1 20); do
  curl -fsS -X POST localhost:${HTTP_PORT:-80}/api/sync -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"docs\":[{\"id\":\"d$i\",\"kind\":\"session\",\"data\":{\"n\":$i},\"updated_at\":$i}]}" >/dev/null
done
SEED_S=$(echo "$(t) - $T0" | bc)

checksum() { sql "SELECT count(*) || ' ' || md5(string_agg(account_id || ':' || ts || ':' || card || ':' || rating, ',' ORDER BY account_id, ts, card)) FROM core_review"; }
docsum() { sql "SELECT count(*) || ' ' || md5(string_agg(doc_id || ':' || data::text, ',' ORDER BY doc_id)) FROM core_doc"; }

echo "== full backup"
$DC exec -T -u postgres db pgbackrest --stanza=darb stanza-create
T0=$(t); $DC exec -T -u postgres db pgbackrest --stanza=darb --type=full backup; BACKUP_S=$(echo "$(t) - $T0" | bc)
SIZE=$($DC exec -T -u postgres db pgbackrest --stanza=darb info --output=json | python3 -c 'import json,sys; b=json.load(sys.stdin)[0]["backup"][-1]["info"]; print(b["repository"]["delta"], b["size"])')

echo "== writes after the backup (recovered from the WAL archive)"
sql "INSERT INTO core_review (account_id, seq, ts, card, rating, flags, duration_ms)
     SELECT $ACC, $REVIEWS + g, (extract(epoch from now())*1000)::bigint - g, 'after:' || g, 3, 0, 1000 FROM generate_series(1, 10000) g" >/dev/null
BEFORE_REV=$(checksum); BEFORE_DOC=$(docsum)
sql "SELECT pg_switch_wal()" >/dev/null
$DC exec -T -u postgres db pgbackrest --stanza=darb check

echo "== disaster: the database volume is gone"
$DC stop api pgbouncer db >/dev/null
$DC rm -f -v db >/dev/null
docker volume rm darb_pgdata

echo "== restore"
T0=$(t)
$DC run --rm --no-deps -u postgres --entrypoint pgbackrest db --stanza=darb restore
$DC up -d db
for i in $(seq 1 120); do [ "$(sql 'SELECT pg_is_in_recovery()' 2>/dev/null)" = "f" ] && break; sleep 1; done
RESTORE_S=$(echo "$(t) - $T0" | bc)
AFTER_REV=$(checksum); AFTER_DOC=$(docsum)

echo
echo "RESTORE REPORT"
echo "reviews seeded: $REVIEWS (+10000 after the backup, from the WAL archive)"
echo "backup (delta, size bytes): $SIZE"
echo "seed s: $SEED_S  backup s: $BACKUP_S  restore + recovery s: $RESTORE_S"
echo "reviews before: $BEFORE_REV"
echo "reviews after:  $AFTER_REV"
echo "docs before:    $BEFORE_DOC"
echo "docs after:     $AFTER_DOC"
[ "$BEFORE_REV" = "$AFTER_REV" ] && [ "$BEFORE_DOC" = "$AFTER_DOC" ] && echo "RESULT: identical" || { echo "RESULT: DIFFERENT"; exit 1; }
