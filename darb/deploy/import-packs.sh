#!/usr/bin/env bash
# Loads every authored pack file in /opt/darb/sources into the live DB (run on the server; yours to run).
# Usage: bash /opt/darb/src/darb/deploy/import-packs.sh [slug...]   (no slugs = all)
set -euo pipefail
cd /opt/darb/src/darb/deploy
dc() { docker compose -p darb --env-file /opt/darb/.env -f docker-compose.yml -f shared-host.compose.yml "$@"; }
for f in /opt/darb/sources/*.jsonl; do
  s=$(basename "$f" .jsonl)
  case $s in verbal-items) s=qudurat-verbal ;; quant-items) s=qudurat-quant ;; qk-items) continue ;; esac  # qk is inside quant
  [ $# -eq 0 ] || [[ " $* " == *" $s "* ]] || continue
  dc cp "$f" "api:/tmp/$s.jsonl"
  echo "$s: $(dc exec -T api python manage.py packs import "$s" "/tmp/$s.jsonl")"
done
