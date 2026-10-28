#!/bin/bash
# Imports one lecture's cards for lana: ./import.sh cs163 L01 cards/L01.json
set -e
python3 -c "import json,sys;print(json.dumps({'course':sys.argv[1],'section':sys.argv[2],'cards':json.load(open(sys.argv[3]))}))" "$1" "$2" "$3" |
  ssh -o BatchMode=yes root@169.58.7.222 'docker exec -i certdeck-certdeck-api-1 sh -c "cat > /tmp/lana-cards.json"'
ssh -o BatchMode=yes root@169.58.7.222 'docker exec -i certdeck-certdeck-api-1 python manage.py shell' < "$(dirname "$0")/import_cards.py" | grep -v "objects imported"
