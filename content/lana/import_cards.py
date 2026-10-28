# Run on the server: docker exec -i certdeck-certdeck-api-1 python manage.py shell < import_cards.py, with /tmp/lana-cards.json:
# {"course": "cs163", "section": "L07", "cards": [{"original": CARD, "versions": [CARD, CARD]}, ...]}
# Card ids are uuid5 of course/section/question + options/answer (several cards share a question), so a re-run skips cards she has instead of adding copies.
import json
import uuid

from core.models import Account, Doc, now_ms, save_docs

lana = Account.objects.get(email="lana@certdeck.app")
f = json.load(open("/tmp/lana-cards.json"))
course, section = f["course"], f"{f['course']}/{f['section']}"
have = set(Doc.objects.filter(user=lana, kind="card", deleted=False).values_list("doc_id", flat=True))
now, docs = now_ms(), []
for item in f["cards"]:
    o = item["original"]
    cid = str(uuid.uuid5(uuid.NAMESPACE_URL, f"lana/{section}/{o['question']}/{o.get('options', o.get('answer'))}"))
    if cid in have:
        continue  # never reset progress on a card she already has
    docs.append({"id": cid, "kind": "card", "updated_at": now, "deleted": False, "data": {
        **o, "id": cid, "course": course, "section": section, "source": "import", "new": True, "created_at": now}})
    docs.append({"id": f"ver-{cid}", "kind": "versions", "updated_at": now, "deleted": False,
                 "data": {"id": f"ver-{cid}", "card_id": cid, "versions": item["versions"]}})
print("saved", save_docs(lana, docs), "docs;", section, "now has",
      Doc.objects.filter(user=lana, kind="card", deleted=False, data__section=section).count(), "cards")
