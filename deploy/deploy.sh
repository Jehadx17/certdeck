#!/usr/bin/env bash
# Ships the committed backend to the VPS and (re)builds it. Usage: deploy/deploy.sh
# Server layout: ~/certdeck/{.env, letsencrypt/, proxy.enabled, src/ (replaced on every deploy)}
set -euo pipefail
HOST=${CERTDECK_HOST:-deploy@217.76.55.241}
cd "$(git rev-parse --show-toplevel)"
git archive --format=tar HEAD backend docs deploy | ssh "$HOST" 'set -e
  cd ~/certdeck && rm -rf src.new && mkdir src.new && tar -x -C src.new && rm -rf src && mv src.new src
  cd src/deploy
  files="-f docker-compose.yml"; [ -f ~/certdeck/proxy.enabled ] && files="$files -f docker-compose.proxy.yml"
  docker compose $files --env-file ~/certdeck/.env up -d --build --remove-orphans
  docker compose $files --env-file ~/certdeck/.env ps --format "{{.Service}}: {{.Status}}"'
