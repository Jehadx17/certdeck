"""Postgres-backed job queue (no Redis/Celery). One pending row per (kind, account, ref); workers claim rows with
FOR UPDATE SKIP LOCKED, so any number of worker processes share the queue and a slow job never touches the API pool.

A claimed job is leased (run_at moves LEASE ahead): if its worker dies, another one re-runs it after the lease.
A handler returns None (done: the row is deleted) or a delay in seconds (run again later, e.g. a batch still running).
Enqueueing a job that is already running marks it `again`, so it runs once more after the current run."""
import logging
import time

from django.db import close_old_connections, connection, transaction

log = logging.getLogger(__name__)

LEASE = 15 * 60  # seconds a claimed job may run before another worker takes it over
MAX_ATTEMPTS = 5
HANDLERS = {}  # kind -> fn(account, ref) -> None | delay seconds


def handler(kind):
    def register(fn):
        HANDLERS[kind] = fn
        return fn
    return register


def enqueue(kind, account, ref="", delay=0):
    """Schedules [kind] for [account]/[ref] in [delay] seconds (earlier wins if it is already pending)."""
    with connection.cursor() as c:
        c.execute("""
            INSERT INTO core_job (kind, account_id, ref, run_at, attempts, running, again)
            VALUES (%s, %s, %s, now() + make_interval(secs => %s), 0, false, false)
            ON CONFLICT (kind, account_id, ref) DO UPDATE SET
              run_at = CASE WHEN core_job.running THEN core_job.run_at ELSE LEAST(core_job.run_at, EXCLUDED.run_at) END,
              again = core_job.running""", [kind, account.pk, ref, delay])


def _claim():
    with transaction.atomic(), connection.cursor() as c:
        c.execute("""
            UPDATE core_job SET running = true, attempts = attempts + 1, run_at = now() + make_interval(secs => %s)
            WHERE id = (SELECT id FROM core_job WHERE run_at <= now() ORDER BY run_at
                        FOR UPDATE SKIP LOCKED LIMIT 1)
            RETURNING id, kind, account_id, ref, attempts""", [LEASE])
        return c.fetchone()


def _finish(job_id, delay):
    with connection.cursor() as c:
        if delay is None:  # done, unless it was enqueued again while running
            c.execute("DELETE FROM core_job WHERE id = %s AND NOT again", [job_id])
            delay = 0
        c.execute("UPDATE core_job SET running = false, again = false, attempts = 0,"
                  " run_at = now() + make_interval(secs => %s) WHERE id = %s", [delay, job_id])


def run_one():
    """Claims and runs one due job. Returns True if there was one."""
    from .models import Account

    row = _claim()
    if not row:
        return False
    job_id, kind, account_id, ref, attempts = row
    t0 = time.monotonic()
    try:
        account = Account.objects.get(pk=account_id)
        delay = HANDLERS[kind](account, ref)
    except Exception:
        log.exception("job %s %s/%s failed (attempt %d)", kind, account_id, ref, attempts)
        with connection.cursor() as c:  # retry after the lease, give up after MAX_ATTEMPTS
            if attempts >= MAX_ATTEMPTS:
                c.execute("DELETE FROM core_job WHERE id = %s", [job_id])
            else:
                c.execute("UPDATE core_job SET running = false WHERE id = %s", [job_id])
        return True
    _finish(job_id, delay)
    log.info("job %s %s/%s done in %.1fs%s", kind, account_id, ref, time.monotonic() - t0,
             "" if delay is None else f", again in {delay}s")
    return True


def work(once=False):
    """The worker loop: due jobs first, then the periodic maintenance (see core.tasks)."""
    from . import tasks  # registers the handlers

    while True:
        close_old_connections()
        did = run_one()
        tasks.periodic()
        if once:
            return did
        if not did:
            time.sleep(2)
