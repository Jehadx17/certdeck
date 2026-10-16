"""What the worker runs: job handlers (core.jobs) and periodic maintenance."""
import logging
import time

from . import autopilot, college, limits, reteach
from .auth import ApiError
from .jobs import enqueue, handler
from .models import docs, ensure_review_partitions

log = logging.getLogger(__name__)


@handler("material")
def material(account, material_id):
    """A material's uploads are complete: convert, map sections, read a syllabus / past paper."""
    college.process_material(account, material_id)
    m = docs(account).filter(doc_id=material_id, deleted=False).first()
    if m and m.data.get("kind") == "past_exam":  # a new professor profile changes what matters most
        for p in docs(account).filter(kind="prio", deleted=False):
            enqueue("prio", account, p.data.get("assessment_id") or "")


@handler("prep")
def prep(account, prep_doc_id):
    return college.advance(account, prep_doc_id)


@handler("prio")
def prio(account, assessment_id):
    """Hints or past papers changed after an assessment was prepared: re-score its knowledge points."""
    try:
        college.reprioritize(account, {"assessment_id": assessment_id})
    except ApiError as e:  # over budget or nothing to score: drop it, the next change re-queues it
        log.info("re-prioritize %s skipped: %s", assessment_id, e.detail)


@handler("daily")
def daily(account, ref):
    """Per active account (queued by its syncs, at most every few hours): autopilot, then re-teach."""
    autopilot.run(account)
    reteach.run(account)


_last = {}


def every(name, seconds, fn):
    """Runs fn at most once per [seconds] in this process (each worker process keeps its own clock; the tasks are
    idempotent, so several workers doing them is harmless)."""
    if time.monotonic() - _last.get(name, -1e12) >= seconds:
        _last[name] = time.monotonic()
        try:
            fn()
        except Exception:
            log.exception("periodic %s failed", name)


PENDING_GUARDIAN_DAYS = 30


def drop_unconfirmed_minors():
    """Under-18 accounts whose guardian never confirmed: deleted after 30 days (minimum data, docs/DARB-PDPL.md)."""
    from datetime import timedelta

    from django.utils.timezone import now as tz_now

    from .accounts import delete_account
    from .models import Account
    from .signin import needs_guardian

    old = Account.objects.filter(guardian_ok_at__isnull=True, birth_year__isnull=False,
                                 created__lt=tz_now() - timedelta(days=PENDING_GUARDIAN_DAYS))
    for a in old:
        if needs_guardian(a):
            delete_account(a)


def spend_alert():
    """The last 24 hours of AI spend over the admin's threshold: an error log line, which Sentry turns into an alert."""
    from datetime import timedelta

    from django.db.models import Sum
    from django.utils.timezone import now as tz_now

    from .models import AiCall, Config

    usd = float(AiCall.objects.filter(created__gte=tz_now() - timedelta(days=1)).aggregate(s=Sum("cost_usd"))["s"] or 0)
    limit = float(Config.get().daily_spend_alert_usd)
    if usd > limit:
        log.error("AI spend alert: $%.2f in the last 24 h (threshold $%.2f)", usd, limit)
    return usd


def periodic():
    every("partitions", 3600, ensure_review_partitions)
    every("rate-cleanup", 86400, limits.cleanup)
    every("anomalies", 3600, limits.anomalies)
    every("unconfirmed-minors", 86400, drop_unconfirmed_minors)
    every("spend-alert", 3600, spend_alert)
