#!/bin/sh
# Runs in the `backup` service (shares the database volume): creates the stanza once, then a full backup on Sundays
# and a differential one on other days, at about 02:00 UTC. WAL is archived continuously by Postgres itself
# (archive_command), so the restore point is at most a minute or so behind. Options: PGBACKREST_* env (deploy/.env).
set -eu
pgbackrest --stanza=darb stanza-create || true
while :; do
  now=$(date -u +%H%M)
  if [ "$now" = "0200" ]; then
    if [ "$(date -u +%u)" = "7" ]; then type=full; else type=diff; fi
    pgbackrest --stanza=darb --type=$type backup && pgbackrest --stanza=darb check || echo "BACKUP FAILED" >&2
    sleep 60
  fi
  sleep 30
done
