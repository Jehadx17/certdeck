# Run on the server inside certdeck-api: python manage.py shell < import.py, with versions.json beside it at /tmp.
# One "versions" doc per card (id ver-<card id>), never touching the card docs. Re-running replaces them.
import json
import time

from core.models import Account, Doc, save_docs

user = Account.objects.get(email="genjehad@gmail.com")
cards = set(Doc.objects.filter(user=user, kind="card", deleted=False).values_list("doc_id", flat=True))
items = [o for o in json.load(open("/tmp/versions.json")) if o["card_id"] in cards]
# Blank the original's content fields so app builds before 72cc0a5 don't show its notes/images on a version.
CONTENT = ("question", "options", "correct", "option_explanations", "answer", "answer_images", "answer_code", "accepted", "explanation",
           "items", "code", "language", "steps", "rubric", "check", "question_images", "leech_help", "verified")
for o in items:
    o["versions"] = [dict({k: None for k in CONTENT}, **v) for v in o["versions"]]
now = int(time.time() * 1000)
docs = [{"id": f"ver-{o['card_id']}", "kind": "versions", "updated_at": now, "deleted": False,
         "data": {"id": f"ver-{o['card_id']}", "card_id": o["card_id"], "versions": o["versions"]}} for o in items]
print("saved", save_docs(user, docs), "of", len(docs))
