#!/usr/bin/env bash
# Ships the committed Darb backend to the shared host and (re)builds it. Usage: darb/deploy/deploy.sh
# Server layout: /opt/darb/{.env (chmod 600), src/ (replaced on every deploy), backups/, edge/}. CertDeck's
# /opt/certdeck is never touched.
set -euo pipefail
HOST=${DARB_HOST:-root@169.58.7.222}
cd "$(git rev-parse --show-toplevel)"
git archive --format=tar HEAD darb/backend darb/deploy | ssh "$HOST" 'set -e
  cd /opt/darb && rm -rf src.new && mkdir src.new && tar -x -C src.new && rm -rf src && mv src.new src
  cd src/darb/deploy && cp /opt/darb/.env .env
  docker compose -p darb --env-file /opt/darb/.env -f docker-compose.yml -f shared-host.compose.yml up -d --build --remove-orphans
  docker compose -p darb --env-file /opt/darb/.env -f docker-compose.yml -f shared-host.compose.yml ps --format "{{.Service}}: {{.Status}}"'
