#!/usr/bin/env bash
# Builds the Flutter web app and ships it to the server. Usage: deploy/deploy-web.sh
set -euo pipefail
HOST=${CERTDECK_HOST:-root@169.58.7.222}
cd "$(git rev-parse --show-toplevel)/app"
flutter build web --release --no-tree-shake-icons
tar -C build/web -c . | ssh "$HOST" 'set -e; rm -rf /opt/certdeck/web.new; mkdir -p /opt/certdeck/web.new; tar -x -C /opt/certdeck/web.new; rm -rf /opt/certdeck/web; mv /opt/certdeck/web.new /opt/certdeck/web'
