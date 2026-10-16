#!/usr/bin/env bash
# Non-destructive restore drill on the live server (docs/DARB-RESTORE.md, quarterly): restores the latest backup plus the
# archived WAL into a throwaway container (no network, repository mounted read-only), then compares row counts of every
# table with the live database. The live database is only read. Run as root from /opt/darb.
set -euo pipefail
LIVE=${LIVE:-darb-db-1}
set -a; . /opt/darb/.env; set +a
counts() {  # <container> <psql args>: "table count" per line for every public table
  docker exec -u postgres "$1" sh -c "psql $2 -U $POSTGRES_USER -d $POSTGRES_DB -tAF' ' -c \"SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1\" |
    while read t; do echo \"\$t \$(psql $2 -U $POSTGRES_USER -d $POSTGRES_DB -tAc \"SELECT count(*) FROM \\\"\$t\\\"\")\"; done"
}
docker rm -f darb-drill >/dev/null 2>&1 || true
trap 'docker rm -f darb-drill >/dev/null 2>&1 || true' EXIT
docker exec "$LIVE" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -qc "SELECT pg_switch_wal()" >/dev/null  # archive the newest WAL
sleep 15
docker run -d --name darb-drill --network none --env-file /opt/darb/.env --tmpfs /drill:uid=999,gid=999 \
  -v /opt/darb/backups:/var/lib/pgbackrest:ro darb-db:latest sleep infinity >/dev/null
T0=$(date +%s)
docker exec -u postgres darb-drill pgbackrest --stanza=darb --pg1-path=/drill/pg --archive-mode=off --log-level-console=warn restore
docker exec -u postgres darb-drill pg_ctl -D /drill/pg -w -t 300 -l /drill/log \
  -o "-c listen_addresses='' -c unix_socket_directories=/drill -c archive_mode=off -c shared_buffers=128MB -c max_connections=200" start >/dev/null \
  || { docker exec darb-drill tail -20 /drill/log; exit 1; }
echo "restore + recovery: $(( $(date +%s) - T0 )) s"
docker exec -u postgres darb-drill pgbackrest --stanza=darb info | grep -E "full backup|diff backup|timestamp start" | tail -2
diff <(counts "$LIVE" "") <(counts darb-drill "-h /drill") && echo "RESULT: every table matches ($(counts "$LIVE" "" | wc -l) tables)"
