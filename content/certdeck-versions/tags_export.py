# Read-only. Run on the server inside certdeck-api: python manage.py shell < tags_export.py > card-tags.json
# Prints {id, tags, certs, course} for every live owner card doc.
import json

from core.models import Account, Doc

user = Account.objects.get(email="genjehad@gmail.com")
rows = [{"id": d.doc_id, "tags": d.data.get("tags") or [], "certs": d.data.get("certs") or {}, "course": d.data.get("course")}
        for d in Doc.objects.filter(user=user, kind="card", deleted=False)]
print(json.dumps(rows))
