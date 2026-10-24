# Run on the server inside certdeck-api: python manage.py shell < tags_import.py, with card-tags.json (all tags/bN.json merged) at /tmp.
# Sets only data.tags on live owner card docs whose tags change; bumps updated_at so phones pull it.
import json
import time

from core.models import Account, Doc, save_docs

user = Account.objects.get(email="genjehad@gmail.com")
want = {r["card_id"]: r["tags"] for r in json.load(open("/tmp/card-tags.json"))}
now = int(time.time() * 1000)
docs = []
for d in Doc.objects.filter(user=user, kind="card", deleted=False, doc_id__in=want):
    if (d.data.get("tags") or []) != want[d.doc_id]:
        docs.append({"id": d.doc_id, "kind": "card", "updated_at": now, "deleted": False, "data": dict(d.data, tags=want[d.doc_id])})
print("wanted", len(want), "changed", len(docs), "saved", save_docs(user, docs))
