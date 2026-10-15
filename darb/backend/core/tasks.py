"""What the worker runs: job handlers (core.jobs) and periodic maintenance."""
import logging
import time

from . import autopilot, college, reteach
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


def periodic():
    every("partitions", 3600, ensure_review_partitions)
