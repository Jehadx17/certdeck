# Run on the server inside certdeck-api: python manage.py shell < import_cards.py, with /tmp/cards.json (in/ batches merged).
# Adds new cards like POST import does, but skips ids already stored so a re-run never resets study progress.
import json

from core.models import Account, Doc, now_ms, save_docs

user = Account.objects.get(email="genjehad@gmail.com")
src = json.load(open("/tmp/cards.json"))
have = set(Doc.objects.filter(user=user, kind="card", doc_id__in=[c["id"] for c in src]).values_list("doc_id", flat=True))
now, docs = now_ms(), []
for c in src:
    if c["id"] in have:
        continue
    data = dict(c, created_at=now, source="import", new=True)
    data.pop("id")
    docs.append({"id": c["id"], "kind": "card", "data": data, "updated_at": now, "deleted": False})
print("saved", save_docs(user, docs), "of", len(src), "already there", len(have))
