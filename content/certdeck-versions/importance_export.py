# Read-only. Run on the server inside certdeck-api: python manage.py shell < importance_export.py > importance/export.json
# Every live cert card of the owner, per cert, in the text the importance rater sees, with its hash and current score.
import json

from core.importance import _card_text, _hash
from core.models import Account, docs

user = Account.objects.get(email="genjehad@gmail.com")
certs = {d.data.get("id") or d.doc_id: d.data for d in docs(user).filter(kind="cert", deleted=False)}
cards = [d for d in docs(user).filter(kind="card", deleted=False) if not d.data.get("suspended")]
out = {}
for cid, cert in certs.items():
    domains = {str(x.get("id")): x.get("name") for x in cert.get("domains") or []}
    old = docs(user).filter(doc_id=f"importance-{cid}", deleted=False).first()
    old = (old.data.get("scores") or {}) if old else {}
    rows = []
    for d in cards:
        c = d.data
        if cid not in (c.get("certs") or {}):
            continue
        text = _card_text(dict(c, _domain=c["certs"][cid]), domains)
        rows.append({"id": d.doc_id, "text": text, "hash": _hash(text), "tags": c.get("tags") or [], "old": (old.get(d.doc_id) or [None])[0]})
    out[cid] = {"name": cert.get("name"), "domains": cert.get("domains"), "cards": rows}
print(json.dumps(out))
