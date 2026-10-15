"""Study metrics from the review log (autopilot input) and per-account FSRS parameter fitting."""
import logging
import math
from collections import Counter
from datetime import datetime, timezone

from fsrs import Card, Rating, ReviewLog, Scheduler
from fsrs.scheduler import DEFAULT_PARAMETERS

from .models import all_reviews, docs, now_ms, save_docs

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


SESSION_GAP_MS = 30 * 60 * 1000
DAY_MS = 86_400_000
GAP_BUCKETS = ((0, 1, "<1d"), (1, 3, "1-3d"), (3, 7, "3-7d"), (7, 14, "7-14d"), (14, float("inf"), "14d+"))


def _pct(part, total):
    return round(100 * part / total, 1) if total else None


def metrics(user, now=None):
    """Baseline study metrics from the review log alone (no app changes): activity, session length, and
    recall by days since the card's previous review. A session is a run of reviews with gaps under 30 min;
    a review's minutes are its duration_ms (capped at the gap to the next review so idle time isn't counted)."""
    now = now or now_ms()
    rows, error_types = [], Counter()
    for r in all_reviews(user):
        try:
            rows.append((int(r["ts"]), str(r["card_id"]), bool(r.get("correct")), r.get("confidence"),
                         r.get("duration_ms"), bool(r.get("misconception")), bool(r.get("study_first"))))
        except (KeyError, TypeError, ValueError):
            continue
        if r.get("error_type"):
            error_types[str(r["error_type"]).strip().lower()[:40]] += 1
    rows.sort()

    sessions, minutes_by_day, active = [], Counter(), set()
    for i, (ts, _, _, _, dur, _, _) in enumerate(rows):
        nxt = rows[i + 1][0] if i + 1 < len(rows) else None
        gap = (nxt - ts) if nxt is not None else SESSION_GAP_MS
        if not sessions or ts - sessions[-1]["end"] >= SESSION_GAP_MS:
            sessions.append({"start": ts, "end": ts, "reviews": 0, "ms": 0})
        s = sessions[-1]
        s["end"], s["reviews"] = ts, s["reviews"] + 1
        ms = min(int(dur), gap, SESSION_GAP_MS) if isinstance(dur, (int, float)) else 0
        s["ms"] += ms
        day = _dt(ts).date()
        minutes_by_day[day] += ms / 60000
        active.add(day)

    today = _dt(now).date()
    last7 = {d for d in active if (today - d).days < 7}
    last28 = {d for d in active if (today - d).days < 28}

    prev, buckets = {}, {label: [0, 0] for _, _, label in GAP_BUCKETS}
    conf = {c: [0, 0, 0] for c in CONFIDENCE}  # reviews, correct, misconception
    for ts, cid, ok, c, _, mis, first in rows:
        if first:  # a new card read first, not answered: not a recall test, not a confidence rating
            prev[cid] = ts
            continue
        if cid in prev:
            days = (ts - prev[cid]) / DAY_MS
            for lo, hi, label in GAP_BUCKETS:
                if lo <= days < hi:
                    buckets[label][0] += 1
                    buckets[label][1] += ok
        prev[cid] = ts
        if c in conf:
            conf[c][0] += 1
            conf[c][1] += ok
            conf[c][2] += mis

    # Sessions the app logged itself: how many ran to the end of their queue (the autopilot's completion signal).
    logged = [d for d in docs(user).filter(kind="session", deleted=False).values_list("data", flat=True)
              if isinstance(d.get("started_at"), (int, float)) and now - d["started_at"] < 28 * DAY_MS]
    n = len(sessions)
    return {
        "session_completion_pct": _pct(sum(bool(d.get("completed")) for d in logged), len(logged)),
        "sessions_logged_last_28": len(logged),
        "reviews": len(rows), "sessions": n, "first_review_ts": rows[0][0] if rows else None,
        "avg_seconds_per_review": round(sum(s["ms"] for s in sessions) / 1000 / len(rows), 1) if rows else None,
        "error_types": dict(error_types.most_common(5)),
        "days_active_last_7": len(last7), "days_active_last_28": len(last28),
        "avg_session_minutes": round(sum(s["ms"] for s in sessions) / 60000 / n, 1) if n else None,
        "avg_session_reviews": round(sum(s["reviews"] for s in sessions) / n, 1) if n else None,
        "minutes_per_active_day_last_28": round(sum(m for d, m in minutes_by_day.items() if d in last28) / len(last28), 1)
        if last28 else None,
        "recall_by_days_since_last_review": {k: {"reviews": t, "accuracy_pct": _pct(ok, t)} for k, (t, ok) in buckets.items()},
        "calibration": {k: {"reviews": t, "accuracy_pct": _pct(ok, t), "misconception_rate_pct": _pct(m, t)}
                        for k, (t, ok, m) in conf.items()},
    }


def _loss(params, rows):
    """Log loss of recall predictions on the last 20% of [(ts, card_id, rating)] (chronological), replaying every
    review with these parameters. Only reviews of a card seen before count."""
    sched = Scheduler(parameters=params, enable_fuzzing=False)
    cards, cut, total, n = {}, int(len(rows) * 0.8), 0.0, 0
    for i, (ts, cid, rating) in enumerate(rows):
        t, card = _dt(ts), cards.get(cid)
        if card is None:
            card = cards[cid] = Card(card_id=len(cards) + 1)
        elif i >= cut:
            p = min(0.99, max(0.01, sched.get_card_retrievability(card, t)))
            total -= math.log(p if rating != Rating.Again else 1 - p)
            n += 1
        cards[cid] = sched.review_card(card, rating, t)[0]
    return total / n if n else None


def optimize(user):
    """Fit FSRS parameters to the user's review log; writes their fsrs_params doc when there is enough data AND the
    fit predicts the last 20% of their reviews better than the parameters they have now (else keeps those)."""
    rows = []
    for r in all_reviews(user):
        try:
            rows.append((int(r["ts"]), str(r["card_id"]), Rating(int(r["rating"])), r.get("duration_ms")))
        except (KeyError, TypeError, ValueError):
            continue
    rows.sort()

    def logs_of(rs):
        ids = {}  # string card id -> int, in order of first review (the optimizer orders cards by id)
        return [ReviewLog(card_id=ids.setdefault(cid, len(ids) + 1), rating=rating, review_datetime=_dt(ts),
                          review_duration=int(dur) if isinstance(dur, (int, float)) else None)
                for ts, cid, rating, dur in rs]

    current = docs(user).filter(doc_id="fsrs_params", deleted=False).first()
    keep = {"parameters": list(scheduler(user).parameters), "optimized_at": (current.data.get("optimized_at") if current else None),
            "review_count": len(rows)}
    if len(rows) < MIN_REVIEWS:
        log.info("fsrs optimize %s skipped: %d reviews < %d", user, len(rows), MIN_REVIEWS)
        return keep

    from fsrs import Optimizer  # imports torch; keep it off the request path of other endpoints

    cut = int(len(rows) * 0.8)
    trial = [float(p) for p in Optimizer(logs_of(rows[:cut])).compute_optimal_parameters()]
    plain = [(ts, cid, rating) for ts, cid, rating, _ in rows]
    new_loss, old_loss = _loss(trial, plain), _loss(keep["parameters"], plain)
    if trial == list(DEFAULT_PARAMETERS) or new_loss is None or new_loss >= old_loss:
        log.info("fsrs optimize %s kept current params (holdout loss new=%s old=%s)", user, new_loss, old_loss)
        return keep
    params = [float(p) for p in Optimizer(logs_of(rows)).compute_optimal_parameters()]  # accepted: refit on everything
    now = now_ms()
    data = {"parameters": params, "optimized_at": now, "review_count": len(rows)}
    save_docs(user, [{"id": "fsrs_params", "kind": "fsrs_params", "data": data, "updated_at": now, "deleted": False}])
    log.info("fsrs optimize %s: %d reviews, holdout loss %.4f -> %.4f", user, len(rows), old_loss, new_loss)
    return data
