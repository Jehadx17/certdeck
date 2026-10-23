# Run on the server inside certdeck-api: python manage.py shell < import_notes.py, with /tmp/versions.json (all out/ batches, notes merged).
# Replaces each live version with its out/ copy (matched by card and question), so notes and corrections land; fields the copy lacks stay blanked.
import json
import time

from core.models import Account, Doc, save_docs

CONTENT = ("question", "options", "correct", "option_explanations", "answer", "answer_images", "answer_code", "accepted", "explanation",
           "items", "code", "language", "steps", "rubric", "check", "question_images", "leech_help", "verified")
user = Account.objects.get(email="genjehad@gmail.com")
src = {o["card_id"]: o["versions"] for o in json.load(open("/tmp/versions.json"))}
now, docs, skipped = int(time.time() * 1000), [], 0
for d in Doc.objects.filter(user=user, kind="versions", deleted=False):
    vs = []
    for v in d.data["versions"]:
        new = next((s for s in src.get(d.data["card_id"], []) if s["question"] == v["question"]), None)
        skipped += new is None
        vs.append(dict({k: None for k in CONTENT}, **new) if new else v)
    docs.append({"id": d.doc_id, "kind": "versions", "updated_at": now, "deleted": False, "data": dict(d.data, versions=vs)})
print("saved", save_docs(user, docs), "of", len(docs), "unmatched versions", skipped)
