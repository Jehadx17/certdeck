"""Autopilot: tunes each student's study load from their own review log, no student controls.

Rules over stats.metrics move session length, new cards per day and a small retention nudge, each clamped; a change
that was followed by a drop is reverted. (CertDeck's Sonnet supervisor layer is cut in Darb: no runtime Opus/Sonnet.)
Result: one sync doc `autopilot` per user that the app reads (schema in `blank`)."""
import logging
from datetime import date

from . import stats
from .models import Account, docs, now_ms, save_docs

log = logging.getLogger(__name__)

DAY = 86_400_000
STEPS = (5, 10, 15, 20)  # session minutes
RETENTION = (-0.05, 0.03)  # clamp for retention_adj (added to the scheduler's desired retention in the app)
LOAD = (0.8, 1.2)
NEW_PER_DAY = (5, 40)
COOLDOWN = 7 * DAY  # one change per week: long enough to see its effect before the next
MIN_REVIEWS = 30
HISTORY = 8
VALUES = ("session_minutes", "new_per_day", "retention_adj", "load_factor", "reason", "updated_at")

def _clamp(x, lo, hi):
    return max(lo, min(hi, x))


def blank():
    """The autopilot doc's data when there is none: no override anywhere."""
    return {"session_minutes": None, "new_per_day": None, "retention_adj": 0.0, "load_factor": 1.0, "reason": "",
            "updated_at": 0, "history": [], "snapshot": None, "reverted": False}


def current(user):
    d = docs(user).filter(doc_id="autopilot", deleted=False).first()
    return {**blank(), **(d.data if d else {})}


def _setup(user):
    d = docs(user).filter(doc_id="settings", deleted=False).first()
    return d.data if d else {}


def days_to_exam(user, now):
    """Days to the nearest upcoming exam (the onboarding exam/goal date or a confirmed upload assessment), or None."""
    today, days = date.fromtimestamp(now / 1000), []
    sources = [_setup(user).get("exam_date")]
    sources += [d.data.get("date") for d in docs(user).filter(kind="assessment", deleted=False) if d.data.get("status") != "proposed"]
    for iso in sources:
        try:
            n = (date.fromisoformat(str(iso)[:10]) - today).days
        except ValueError:
            continue
        if n >= 0:
            days.append(n)
    return min(days) if days else None


def _snapshot(m):
    buckets = m["recall_by_days_since_last_review"]
    return {"days_active_last_7": m["days_active_last_7"],
            "recall_14d": buckets["14d+"]["accuracy_pct"], "recall_7_14d": buckets["7-14d"]["accuracy_pct"]}


def _dropped(snap, m):
    """True when the metrics got clearly worse than the snapshot taken with the last change."""
    if not snap:
        return False
    now = _snapshot(m)
    if snap.get("days_active_last_7") is not None and snap["days_active_last_7"] - now["days_active_last_7"] >= 3:
        return True
    return any(snap.get(k) is not None and now[k] is not None and snap[k] - now[k] >= 10 for k in ("recall_14d", "recall_7_14d"))


def _with(cur, **changes):
    return {**cur, **changes}


def tune(user, now=None, m=None, cur=None):
    """Layer 1: the next autopilot data, or None when nothing may change yet (inside the weekly cooldown).
    Does not save. First reverts the last change if it was followed by a drop, otherwise applies the activity rules."""
    now = now or now_ms()
    m, cur = m or stats.metrics(user, now), cur or current(user)
    if cur["updated_at"] and now - cur["updated_at"] < COOLDOWN:
        return None
    snap = _snapshot(m)
    if cur["history"] and not cur["reverted"] and _dropped(cur["snapshot"], m):
        prev = cur["history"][-1]
        out = _with(cur, **{k: prev[k] for k in VALUES if k in prev}, history=cur["history"][:-1], reverted=True)
        out.update(reason=f"Reverted: the last change was followed by a drop. {prev.get('reason', '')}".strip(), updated_at=now, snapshot=snap)
        return out

    setup = _setup(user)
    # What the student or owner picked after the last autopilot change is the starting point, not the old override.
    def start(key, default):
        picked = setup.get(key) if (setup.get(key + "_set_at") or 0) > cur["updated_at"] else None
        return picked or cur[key] or setup.get(key) or default

    minutes = start("session_minutes", 10)
    new = start("new_per_day", 20)
    retention, reason = cur["retention_adj"], []
    history_days = (now - m["first_review_ts"]) / DAY if m["first_review_ts"] else 0
    active = m["days_active_last_7"]
    if active <= 2 and history_days >= 7:
        minutes = max((s for s in STEPS if s < minutes), default=STEPS[0])
        new = new * 0.75
        reason.append("few study days last week: shorter sessions, fewer new cards")
    elif active >= 5:
        new = new * 1.2
        reason.append("studying most days: a few more new cards")
    old = m["recall_by_days_since_last_review"]["14d+"]
    if old["reviews"] >= 30 and old["accuracy_pct"] < 75:
        retention += 0.02
        reason.append("long-gap recall is weak: review a little more")
    elif old["reviews"] >= 50 and old["accuracy_pct"] > 93:
        retention -= 0.02
        reason.append("long-gap recall is very strong: review a little less")
    return _with(cur, session_minutes=int(minutes), new_per_day=int(_clamp(round(new), *NEW_PER_DAY)),
                 retention_adj=round(_clamp(retention, *RETENTION), 3), reason="; ".join(reason) or cur["reason"],
                 updated_at=now, snapshot=snap, reverted=False)


def run(user, now=None):
    """Tunes one account and saves its autopilot doc. Returns the doc data, or None when skipped (too few reviews,
    or still in the weekly cooldown)."""
    now = now or now_ms()
    m = stats.metrics(user, now)
    if m["reviews"] < MIN_REVIEWS:
        return None
    cur = current(user)
    new = tune(user, now, m, cur)
    if new is None:
        return None
    if any(new[k] != cur[k] for k in VALUES[:4]) and not new["reverted"]:  # a revert already popped its history
        new["history"] = (cur["history"] + [{k: cur[k] for k in VALUES}])[-HISTORY:]
    save_docs(user, [{"id": "autopilot", "kind": "autopilot", "data": new, "updated_at": now, "deleted": False}])
    log.info("autopilot %s: %s", user, {k: new[k] for k in VALUES[:5]})
    return new
