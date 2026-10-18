#!/usr/bin/env bash
# Dry run of the live import + build on a throwaway DB (run on the server): every file in /opt/darb/sources goes through
# `packs import`, is built with a throwaway key, decrypted back and counted. The live DB and DARB_PACK_KEK are not touched.
# Usage: bash /opt/darb/src/darb/deploy/tests/packs-dryrun.sh
set -euo pipefail
net=darb-dryrun-$$; pw=$(head -c 12 /dev/urandom | base64 | tr -d '/+=')
trap 'docker rm -f "$net-db" >/dev/null 2>&1; docker network rm "$net" >/dev/null 2>&1' EXIT
docker network create "$net" >/dev/null
docker run -d --rm --name "$net-db" --network "$net" -e POSTGRES_PASSWORD="$pw" -e POSTGRES_USER=darb -e POSTGRES_DB=darb darb-db:latest >/dev/null
until docker exec "$net-db" pg_isready -U darb -q; do sleep 1; done
docker run --rm --user 0 --network "$net" -v /opt/darb/sources:/sources:ro --entrypoint sh \
  -e DATABASE_URL="postgres://darb:$pw@$net-db:5432/darb" -e DJANGO_SECRET_KEY=dryrun \
  -e DARB_PACK_KEK="$(head -c 32 /dev/urandom | base64)" darb-api:latest -c '
python manage.py migrate -v0 && python manage.py shell -c "
import glob, json, os
from core import content, packs
from core.models import Pack
alias = {\"verbal-items\": \"qudurat-verbal\", \"quant-items\": \"qudurat-quant\"}
for f in sorted(glob.glob(\"/sources/*.jsonl\")):
    name = os.path.basename(f)[:-6]
    if name == \"qk-items\": continue  # already inside quant-items
    slug = alias.get(name, name)
    lines = sum(1 for l in open(f) if l.strip())
    stats = content.import_items(slug, f)
    p = Pack.objects.get(slug=slug)
    blob, _ = packs.build(p)
    cards = packs.decrypt(slug, p.version, packs.unwrap(slug, p.key_wrapped), blob)[\"cards\"]
    print(slug, lines, \"lines ->\", len(cards), \"cards decrypted,\", len(blob), \"bytes;\", json.dumps(stats, ensure_ascii=False))
"'
