"""Re-teach: when a card is a leech or a flagged misconception, write two new cards for it once (the model's own words):
one atomic card on the single fact that keeps being missed (with a different explanation, an analogy or mnemonic) and
one contrast card against what it is usually confused with. Marker docs `reteach-<card id>` (kind `reteach`) record that
a card was done, so the student's own card doc is never touched (no sync conflicts)."""
import json
import logging

from . import ai
from .auth import ApiError
from .models import docs, now_ms, save_docs

log = logging.getLogger(__name__)

PER_DAY = 3  # cards re-taught per account per day (each costs a few cents at most)
COPY = ("course", "section", "kp_ids")  # college fields: keep the new cards in the same exam scope

RETEACH_TASK = """This card keeps being failed (a leech) or answered "sure" and wrong (a misconception). Write exactly 2 NEW cards of the same concept:
1. an ATOMIC card: the one smallest fact or step the student most likely misses, asked directly. Its explanation must teach it a DIFFERENT way than the original's explanation: a concrete analogy, a mnemonic, or a short worked example.
2. a CONTRAST card: asks the student to tell this concept apart from the thing it is most commonly confused with (an mcq whose options include that confusable, or a basic card "X vs Y"), and explains the difference.
Use the same language as the original card."""
RETEACH_PROMPT = """You write study cards for Darb, a spaced-repetition study app for Saudi students. A new card tests the SAME concept as the original from a different angle, so remembering the original's answer or option order doesn't help."""
RETEACH_SCHEMA = ai._obj(variants={"type": "array", "items": ai.CARD})


def candidates(user, now):
    """Leech/misconception cards not yet re-taught, worst first; none when today's quota is used."""
    marks = {d.doc_id: d.data.get("done_at", 0) for d in docs(user).filter(kind="reteach")}
    if sum(t > now - 86_400_000 for t in marks.values()) >= PER_DAY:
        return []
    out = [d for d in docs(user).filter(kind="card", deleted=False)
           if (d.data.get("leech") or d.data.get("misconception")) and not d.data.get("suspended")
           and f"reteach-{d.doc_id}" not in marks]
    out.sort(key=lambda d: (bool(d.data.get("leech")), int(d.data.get("lapses") or 0)), reverse=True)
    return out[:PER_DAY - sum(t > now - 86_400_000 for t in marks.values())]


def reteach_request(card):
    system = [{"type": "text", "text": f"{RETEACH_PROMPT}\n\n{ai.CARD_RULES}"},
              {"type": "text", "text": "Original card (JSON):\n" + json.dumps(card, ensure_ascii=False)}]
    return ai.params(system, [{"role": "user", "content": RETEACH_TASK}], RETEACH_SCHEMA, max_tokens=3000)


def reteach(user, card_doc, now=None):
    """Writes the new cards and the marker for one card doc; returns how many cards were kept."""
    now, card = now or now_ms(), dict(card_doc.data, id=card_doc.doc_id)
    out = ai.call(user, "reteach", reteach_request(card), estimate=0.01)
    new_docs = []
    for raw in out.get("variants", [])[:2]:
        v = ai.clean_card(raw)
        if not v:
            continue
        v.update(tags=card.get("tags") or ai._tags(raw), source=f"ai:reteach {raw.get('topic', '')}".strip(),
                 variant_of=card_doc.doc_id, new=True, created_at=now, **{k: card[k] for k in COPY if card.get(k) is not None})
        new_docs.append(ai._card_doc(v, now))
    marker = {"id": f"reteach-{card_doc.doc_id}", "kind": "reteach", "updated_at": now, "deleted": False,
              "data": {"card_id": card_doc.doc_id, "done_at": now, "new_card_ids": [d["id"] for d in new_docs]}}
    save_docs(user, new_docs + [marker])
    return len(new_docs)


def run(user, now=None):
    now, made = now or now_ms(), 0
    for card_doc in candidates(user, now):
        try:
            made += reteach(user, card_doc, now)
        except ApiError as e:  # over budget or AI down: nothing written, so it is tried again tomorrow
            log.info("reteach %s skipped: %s", card_doc.doc_id, e.detail)
            break
    return made
