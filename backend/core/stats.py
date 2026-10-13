"""Weakness-analysis stats and FSRS (retrievability, parameter optimization)."""
import logging
from collections import Counter
from datetime import date, datetime, timezone
from statistics import mean

from fsrs import Card, Rating, ReviewLog, Scheduler, State
from fsrs.scheduler import DEFAULT_PARAMETERS

from .models import docs, now_ms, save_docs

log = logging.getLogger(__name__)

CONFIDENCE = ("guess", "unsure", "sure")
# py-fsrs's Optimizer returns the defaults unless it sees >= 512 cross-day reviews (its mini_batch_size).
MIN_REVIEWS = 512


def _dt(ms):
    return datetime.fromtimestamp(ms / 1000, timezone.utc)


def scheduler(user):
    doc = docs(user).filter(doc_id="fsrs_params", deleted=False).first()
    try:
        return Scheduler(parameters=doc.data["parameters"]) if doc else Scheduler()
    except (KeyError, TypeError, ValueError):
        return Scheduler()


def retrievability(sched, fsrs, now):
    """Recall probability now, or None for a never-reviewed card. Card fsrs times are ms."""
    if not isinstance(fsrs, dict) or not fsrs.get("stability") or not fsrs.get("last_review"):
        return None
    card = Card(card_id=0, state=State.Review, stability=float(fsrs["stability"]), last_review=_dt(fsrs["last_review"]))
    return sched.get_card_retrievability(card, now)


def _pct(part, total):
    return round(100 * part / total, 1) if total else None


def _blank():
    return {"cards": 0, "new": 0, "reviews": 0, "correct": 0, "lapses": 0, "misconception_reviews": 0,
            "misconceptions_flagged": 0, "leeches": 0, "exam_questions": 0, "exam_correct": 0,
            "confidence": {c: [0, 0] for c in CONFIDENCE}, "_r": []}


def _final(s):
    r = s.pop("_r")
    s["accuracy_pct"] = _pct(s["correct"], s["reviews"])
    s["exam_accuracy_pct"] = _pct(s["exam_correct"], s["exam_questions"])
    s["mean_retrievability"] = round(mean(r), 3) if r else None
    s["confidence"] = {k: {"reviews": n, "accuracy_pct": _pct(ok, n)} for k, (n, ok) in s["confidence"].items()}
    return s


def cert_stats(user, code, cert):
    """Returns (stats for the prompt, {card_id: {domain, r, data}} for the cert's non-deleted cards)."""
    now = datetime.now(timezone.utc)
    sched = scheduler(user)
    domains = {str(d["id"]): d for d in cert.get("domains", [])}
    per = {i: _blank() for i in domains}
    overall = _blank()

    cards = {}
    for d in docs(user).filter(kind="card", deleted=False):
        dom = (d.data.get("certs") or {}).get(code)
        if dom is None:
            continue
        c = cards[d.doc_id] = {"domain": str(dom), "r": retrievability(sched, d.data.get("fsrs"), now), "data": d.data}
        for s in (per.setdefault(c["domain"], _blank()), overall):
            s["cards"] += 1
            s["new"] += bool(d.data.get("new", not d.data.get("fsrs")))
            s["lapses"] += int(d.data.get("lapses") or 0)
            s["misconceptions_flagged"] += bool(d.data.get("misconception"))
            s["leeches"] += bool(d.data.get("leech"))
            if c["r"] is not None:
                s["_r"].append(c["r"])

    misconceptions = Counter()
    for r in docs(user).filter(kind="review", deleted=False).values_list("data", flat=True):
        c = cards.get(r.get("card_id"))
        if not c:
            continue
        ok = bool(r.get("correct"))
        misconceptions[r["card_id"]] += bool(r.get("misconception"))
        for s in (per[c["domain"]], overall):
            s["reviews"] += 1
            s["correct"] += ok
            s["misconception_reviews"] += bool(r.get("misconception"))
            if r.get("confidence") in CONFIDENCE:
                s["confidence"][r["confidence"]][0] += 1
                s["confidence"][r["confidence"]][1] += ok

    exams = []
    for e in docs(user).filter(kind="exam", deleted=False).values_list("data", flat=True):
        if e.get("cert") != code:
            continue
        exams.append({k: e.get(k) for k in ("finished_at", "score_pct", "passed", "minutes")}
                     | {"questions": len(e.get("questions") or [])})
        for q in e.get("questions") or []:
            dom = str(q.get("domain") or cards.get(q.get("card_id"), {}).get("domain") or "")
            for s in (per.get(dom), overall):
                if s:
                    s["exam_questions"] += 1
                    s["exam_correct"] += bool(q.get("correct"))
    exams.sort(key=lambda e: e.get("finished_at") or 0)

    def badness(cid):
        d = cards[cid]["data"]
        return (3 * bool(d.get("misconception")) + 2 * bool(d.get("leech")) + 0.5 * min(int(d.get("lapses") or 0), 10)
                + misconceptions[cid])

    worst = sorted((cid for cid in cards if badness(cid) > 0), key=badness, reverse=True)[:25]
    exam_date = cert.get("exam_date")
    try:
        days_left = (date.fromisoformat(exam_date) - now.date()).days if exam_date else None
    except ValueError:
        days_left = None
    stats = {
        "cert": code, "name": cert.get("name", ""), "today": now.date().isoformat(),
        "exam_date": exam_date, "days_until_exam": days_left, "exam_format": cert.get("exam"),
        "overall": _final(overall),
        "domains": [{"id": i, "name": domains.get(i, {}).get("name", "(not in cert)"),
                     "weight": domains.get(i, {}).get("weight"), **_final(s)} for i, s in per.items()],
        "exam_simulations": exams[-10:],
        "worst_cards": [{
            "id": cid, "domain": cards[cid]["domain"], "type": cards[cid]["data"].get("type"),
            "question": " ".join(str(cards[cid]["data"].get("question", "")).split())[:150],
            "lapses": int(cards[cid]["data"].get("lapses") or 0), "leech": bool(cards[cid]["data"].get("leech")),
            "misconception": bool(cards[cid]["data"].get("misconception")),
            "misconception_reviews": misconceptions[cid],
            "retrievability": None if cards[cid]["r"] is None else round(cards[cid]["r"], 3),
        } for cid in worst],
    }
    return stats, cards


def optimize(user):
    """Fit FSRS parameters to the user's review docs; writes their fsrs_params doc when there is enough data."""
    rows = []
    for r in docs(user).filter(kind="review", deleted=False).values_list("data", flat=True):
        try:
            rows.append((int(r["ts"]), str(r["card_id"]), Rating(int(r["rating"])), r.get("duration_ms")))
        except (KeyError, TypeError, ValueError):
            continue
    rows.sort()
    ids = {}  # string card id -> int, in order of first review (the optimizer orders cards by id)
    logs = [ReviewLog(card_id=ids.setdefault(cid, len(ids) + 1), rating=rating, review_datetime=_dt(ts),
                      review_duration=int(dur) if isinstance(dur, (int, float)) else None)
            for ts, cid, rating, dur in rows]
    defaults = {"parameters": list(DEFAULT_PARAMETERS), "optimized_at": None, "review_count": len(logs)}
    if len(logs) < MIN_REVIEWS:
        log.info("fsrs optimize %s skipped: %d reviews < %d", user, len(logs), MIN_REVIEWS)
        return defaults

    from fsrs import Optimizer  # imports torch; keep it off the request path of other endpoints

    params = [float(p) for p in Optimizer(logs).compute_optimal_parameters()]
    if params == list(DEFAULT_PARAMETERS):  # not enough cross-day reviews for the optimizer
        log.info("fsrs optimize: optimizer kept defaults (%d reviews)", len(logs))
        return defaults
    now = now_ms()
    data = {"parameters": params, "optimized_at": now, "review_count": len(logs)}
    save_docs(user, [{"id": "fsrs_params", "kind": "fsrs_params", "data": data, "updated_at": now, "deleted": False}])
    log.info("fsrs optimize %s: %d reviews -> %s", user, len(logs), params)
    return data
