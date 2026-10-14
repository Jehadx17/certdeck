"""How important each cert card is for its exam, 1-10, rated by the AI. Only readiness uses it (important cards count
more); nobody sees it. One `importance-<cert>` doc per cert: {scores: {card id: [score, text hash]}, guide: hash of
the cert's domains, scale: 10}. The college worker re-rates cards that are new or edited, and every card of a cert
whose exam-guide domains changed. College cards don't come here: they use the per-assessment priority scores."""
import hashlib
import json
import logging

from django.conf import settings

from . import ai
from .ai import INT, ApiError, _obj, params
from .models import docs, now_ms, save_docs

log = logging.getLogger(__name__)
SCALE = 10
BATCH = 60  # cards per call
SCHEMA = _obj(scores={"type": "array", "items": INT})
PROMPT = """You rate flashcards by how important they are for passing a certification exam, from 1 (trivia, rarely tested) to 10 (core knowledge the exam tests often and heavily). Use the exam guide's domains and their weights, how often the topic appears on the real exam, and whether it is a fundamental concept that many questions depend on. Use the whole scale. Return one integer per card, in the same order as the numbered list (exactly as many scores as cards)."""


def _hash(text):
    return hashlib.sha256(text.encode()).hexdigest()[:12]


def _card_text(c, domains):
    answer = c.get("answer") or ""
    if c.get("type") == "mcq":
        answer = "; ".join(o for i, o in enumerate(c.get("options") or []) if i in (c.get("correct") or []))
    return f"[{domains.get(str(c.get('_domain')), '?')}] {(c.get('question') or '')[:300]} -> {str(answer)[:160]}"


def rate_cert(user, cert):
    """Rates this cert's unrated or changed cards; returns how many were rated."""
    cid = cert.get("id")
    domains = {str(d.get("id")): d.get("name") for d in cert.get("domains") or []}
    guide = _hash(json.dumps(cert.get("domains") or [], sort_keys=True))
    doc = docs(user).filter(doc_id=f"importance-{cid}", deleted=False).first()
    old = (doc.data if doc else {}) if (doc and doc.data.get("guide") == guide) else {}
    scores = dict(old.get("scores") or {})
    todo = []
    live = set()
    for d in docs(user).filter(kind="card", deleted=False):
        c = d.data
        if c.get("suspended") or cid not in (c.get("certs") or {}):
            continue
        live.add(d.doc_id)
        text = _card_text(dict(c, _domain=c["certs"][cid]), domains)
        h = _hash(text)
        if (scores.get(d.doc_id) or [None, None])[1] != h:
            todo.append((d.doc_id, text, h))
    scores = {k: v for k, v in scores.items() if k in live}
    if not todo and len(scores) == len(old.get("scores") or {}):
        return 0
    guide_text = "\n".join(f"- {d.get('name')}: {round(100 * float(d.get('weight') or 0))}% of the exam" for d in cert.get("domains") or [])
    for i in range(0, len(todo), BATCH):
        chunk = todo[i:i + BATCH]
        listing = "\n".join(f"{n}. {text}" for n, (_, text, _) in enumerate(chunk, 1))
        out = ai.call(user, "cert_importance", params([{"type": "text", "text": PROMPT}], [{"role": "user", "content":
            f"Exam: {cert.get('name')} ({cid})\nExam guide domains:\n{guide_text}\n\nCards:\n{listing}"}],
            SCHEMA, model=settings.CERTDECK_READ_MODEL, effort="low"))
        got = out.get("scores") or []
        if len(got) != len(chunk):  # misaligned: leave these unrated (readiness counts them as average) and retry later
            log.warning("importance %s: %d scores for %d cards", cid, len(got), len(chunk))
            continue
        for (card_id, _, h), sc in zip(chunk, got):
            scores[card_id] = [max(1, min(SCALE, int(sc))), h]
    save_docs(user, [{"id": f"importance-{cid}", "kind": "importance", "updated_at": now_ms(), "deleted": False,
                      "data": {"cert": cid, "scores": scores, "guide": guide, "scale": SCALE}}])
    return len(todo)


def rate_all():
    """Every account's certs (only cards tagged with a cert are rated, so students cost nothing here)."""
    from .models import Doc
    did = 0
    for d in Doc.objects.filter(kind="cert", deleted=False).select_related("user"):
        try:
            did += rate_cert(d.user, dict(d.data, id=d.data.get("id") or d.doc_id))
        except ApiError as e:  # over budget, AI hiccup: next minute
            log.info("importance %s skipped: %s", d.doc_id, e.detail)
    return did
