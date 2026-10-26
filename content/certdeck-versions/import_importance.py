# Run on the server inside certdeck-api: python manage.py shell < import_importance.py, with importance/scores.json at /tmp/importance.json.
# Replaces each cert's importance doc with the scores rated in Claude Code. Each score carries the card's text hash, so the
# worker's AI rater leaves it alone until the card is edited (then it re-rates that card only).
import json

from core.importance import SCALE, _card_text, _hash
from core.models import Account, docs, now_ms, save_docs

user = Account.objects.get(email="genjehad@gmail.com")
src = json.load(open("/tmp/importance.json"))
cards = {d.doc_id: d.data for d in docs(user).filter(kind="card", deleted=False)}
out = []
for d in docs(user).filter(kind="cert", deleted=False):
    cid, cert = d.data.get("id") or d.doc_id, d.data
    if cid not in src:
        continue
    domains = {str(x.get("id")): x.get("name") for x in cert.get("domains") or []}
    scores, missing = {}, 0
    for card_id, r in src[cid].items():
        c = cards.get(card_id)
        if not c or cid not in (c.get("certs") or {}):
            missing += 1
            continue
        scores[card_id] = [max(1, min(SCALE, int(r["score"]))), _hash(_card_text(dict(c, _domain=c["certs"][cid]), domains))]
    out.append({"id": f"importance-{cid}", "kind": "importance", "updated_at": now_ms(), "deleted": False,
                "data": {"cert": cid, "scores": scores, "guide": _hash(json.dumps(cert.get("domains") or [], sort_keys=True)), "scale": SCALE,
                         "source": "claude-code"}})
    print(cid, "scores", len(scores), "missing cards", missing)
print("saved", save_docs(user, out))
