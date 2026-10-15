"""Rate limits per account, device and IP (Cloudflare's free plan has one rule, nginx limits per IP only), and the
anomaly rules that suspend scraping-like accounts automatically (docs/DARB-SECURITY.md). A suspended student sees the
support address to appeal; the admin restores the account."""
import logging
import time
from datetime import timedelta

from django.db import connection
from django.db.models import Count
from django.utils.timezone import now as tz_now

from .auth import ApiError
from .models import Account, PackGrant, Rate

log = logging.getLogger(__name__)

# name: (max requests, window seconds). Generous for a real student, tight for a script.
LIMITS = {
    "signin_ip": (20, 3600),        # sign-in attempts per IP per hour (schools share IPs: not lower)
    "signup_ip": (8, 86400),        # new accounts per IP per day
    "guardian_account": (5, 86400),  # guardian emails sent per account per day
    "report_account": (30, 86400),  # mistake reports per account per day
    "upload_account": (600, 3600),  # upload chunks per account per hour
    "unattested_ai": (20, 86400),   # AI calls per day from a device that couldn't attest (stricter, not blocked)
}


def hit(name, who, limit=None, window=None):
    """Counts one request for [who]; raises 429 past the limit."""
    lim, win = LIMITS[name] if limit is None else (limit, window)
    bucket = int(time.time()) // win
    with connection.cursor() as c:
        c.execute("INSERT INTO core_rate (key, bucket, n) VALUES (%s, %s, 1) ON CONFLICT (key, bucket) "
                  "DO UPDATE SET n = core_rate.n + 1 RETURNING n", [f"{name}:{who}", bucket])
        n = c.fetchone()[0]
    if n > lim:
        raise ApiError(429, "Too many tries. Please wait a while.", code="rate")


def client_ip(request):
    return request.META.get("HTTP_CF_CONNECTING_IP") or request.META.get("REMOTE_ADDR") or "?"


def cleanup():
    Rate.objects.filter(bucket__lt=int(time.time()) // 86400 - 2).delete()  # only daily buckets can be this old


# ---------- anomaly rules (the worker runs them hourly) ----------

RULES = {
    "pack keys on more than 5 devices in a day": 5,
    "pack keys from more than 12 IP addresses in a day": 12,
    "more than 20,000 reviews in a day": 20000,
}


def suspend(account, why):
    Account.objects.filter(pk=account.pk, active=True).update(active=False, suspended=why[:200])
    log.warning("account %s suspended: %s", account.public_id, why)


def anomalies():
    """Suspends accounts that look like scraping or sharing. Returns [(account, reason)]."""
    since = tz_now() - timedelta(days=1)
    found = []
    grants = PackGrant.objects.filter(created__gte=since, account__active=True)
    for row in grants.values("account").annotate(devices=Count("device", distinct=True), ips=Count("ip", distinct=True)):
        reason = ("pack keys on more than 5 devices in a day" if row["devices"] > RULES["pack keys on more than 5 devices in a day"]
                  else "pack keys from more than 12 IP addresses in a day" if row["ips"] > RULES["pack keys from more than 12 IP addresses in a day"]
                  else None)
        if reason:
            found.append((Account.objects.get(pk=row["account"]), reason))
    day_ms = int((time.time() - 86400) * 1000)
    with connection.cursor() as c:
        c.execute("SELECT account_id FROM core_review WHERE ts > %s GROUP BY account_id HAVING count(*) > %s",
                  [day_ms, RULES["more than 20,000 reviews in a day"]])
        for (aid,) in c.fetchall():
            found.append((Account.objects.get(pk=aid), "more than 20,000 reviews in a day"))
    for account, reason in found:
        suspend(account, f"automatic: {reason}")
    return found
