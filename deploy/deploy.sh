#!/usr/bin/env bash
# Ships the committed backend to the server and (re)builds it. Usage: deploy/deploy.sh
# Server layout: /opt/certdeck/{.env, src/ (replaced on every deploy)}
set -euo pipefail
HOST=${CERTDECK_HOST:-$(cat "$(dirname "$0")/.host" 2>/dev/null)}; : "${HOST:?set CERTDECK_HOST or put user@host in deploy/.host}"
cd "$(git rev-parse --show-toplevel)"
git archive --format=tar HEAD backend docs deploy | ssh "$HOST" 'set -e
  cd /opt/certdeck && rm -rf src.new && mkdir src.new && tar -x -C src.new && rm -rf src && mv src.new src
  cd src/deploy
  docker compose --env-file /opt/certdeck/.env up -d --build --remove-orphans
  docker compose --env-file /opt/certdeck/.env ps --format "{{.Service}}: {{.Status}}"'
