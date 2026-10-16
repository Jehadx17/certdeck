"""Subscriptions: RevenueCat sells (App Store / Google Play), the backend decides who is premium.

The app never tells the backend it paid. A webhook from RevenueCat (shared-secret header) or the app's "I just bought"
ping only makes the backend re-read the subscriber from RevenueCat's REST API, and account.premium_until is set from
that. Without the REST key (local development), the webhook event's own expiration is used."""
import hmac
import json
import logging
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

from django.conf import settings
from django.utils.timezone import now as tz_now

from .auth import ApiError
from .models import Account

log = logging.getLogger(__name__)

API = "https://api.revenuecat.com/v1/subscribers/"
GRANTS = {"INITIAL_PURCHASE", "RENEWAL", "PRODUCT_CHANGE", "UNCANCELLATION", "NON_RENEWING_PURCHASE",
          "SUBSCRIPTION_EXTENDED", "TEMPORARY_ENTITLEMENT_GRANT", "EXPIRATION", "REFUND_REVERSED"}


def is_premium(account):
    return account.premium_until is not None and account.premium_until > tz_now()


def require_premium(account):
    if not is_premium(account):
        raise ApiError(403, "This is part of Darb Plus.", code="premium")


def _parse(iso):
    return datetime.fromisoformat(iso.replace("Z", "+00:00")) if iso else None


def _rc(method, app_user_id):
    req = urllib.request.Request(API + urllib.parse.quote(app_user_id, safe=""), method=method,
                                 headers={"Authorization": f"Bearer {settings.DARB_REVENUECAT_API_KEY}",
                                          "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read() or b"{}")


def entitlement_expiry(subscriber):
    """When the premium entitlement ends, from a RevenueCat subscriber object (None = not entitled; far future for a
    lifetime grant). The grace period after a billing problem counts as entitled."""
    e = (subscriber.get("entitlements") or {}).get(settings.DARB_ENTITLEMENT)
    if not e:
        return None
    if e.get("expires_date") is None:
        return datetime(9999, 1, 1, tzinfo=timezone.utc)
    ends = [d for d in (_parse(e.get("expires_date")), _parse(e.get("grace_period_expires_date"))) if d]
    return max(ends)


def refresh(account):
    """Re-reads the account's entitlement from RevenueCat and saves it. Returns premium_until."""
    if not settings.DARB_REVENUECAT_API_KEY:
        return account.premium_until
    try:
        sub = _rc("GET", account.public_id).get("subscriber") or {}
    except (urllib.error.URLError, ValueError) as e:
        log.warning("revenuecat refresh %s failed: %s", account.public_id, e)
        raise ApiError(503, "couldn't check the subscription, try again")
    account.premium_until = entitlement_expiry(sub)
    Account.objects.filter(pk=account.pk).update(premium_until=account.premium_until)
    return account.premium_until


def webhook(request):
    """POST billing/revenuecat. Returns (status, body)."""
    expected = settings.DARB_REVENUECAT_WEBHOOK_AUTH
    given = request.headers.get("Authorization", "")
    if not expected or not hmac.compare_digest(given.encode(), expected.encode()):
        return 401, {"error": "unauthorized"}
    try:
        event = json.loads(request.body)["event"]
    except (ValueError, KeyError, TypeError):
        return 400, {"error": "bad event"}
    ids = {event.get("app_user_id"), event.get("original_app_user_id"), *(event.get("aliases") or []),
           *(event.get("transferred_to") or []), *(event.get("transferred_from") or [])} - {None}
    accounts = list(Account.objects.filter(public_id__in=ids))
    for account in accounts:
        if settings.DARB_REVENUECAT_API_KEY:
            refresh(account)
        elif event.get("type") in GRANTS and event.get("expiration_at_ms"):  # development without the REST key
            until = datetime.fromtimestamp(event["expiration_at_ms"] / 1000, timezone.utc)
            Account.objects.filter(pk=account.pk).update(premium_until=until)
        elif event.get("type") == "CANCELLATION" and event.get("cancel_reason") == "CUSTOMER_SUPPORT":  # a refund
            Account.objects.filter(pk=account.pk).update(premium_until=tz_now())
        if (event.get("product_id") or "").startswith("darb_annual"):
            schedule_reminder(account, event.get("type"))
    log.info("revenuecat %s %s env=%s accounts=%d", event.get("type"), event.get("product_id"),
             event.get("environment"), len(accounts))
    return 200, {"ok": True}  # unknown users too: RevenueCat must not retry forever


REMIND_DAYS = 3


def schedule_reminder(account, kind):
    """Annual plans: an email 3 days before the renewal charge (DARB-COMPETITORS.md #4). Re-scheduled on every
    purchase or renewal; turning off auto-renew or expiring drops it."""
    from .jobs import enqueue
    from .models import Job
    Job.objects.filter(kind="renewal_reminder", account=account).delete()
    if kind not in ("INITIAL_PURCHASE", "RENEWAL", "UNCANCELLATION", "PRODUCT_CHANGE"):
        return
    until = Account.objects.get(pk=account.pk).premium_until
    if until and until.year < 9999:
        enqueue("renewal_reminder", account, delay=max(0, (until - tz_now()).total_seconds() - REMIND_DAYS * 86400))


def send_reminder(account):
    """The job: still premium and renewing within the next 4 days (a refund or an expiry would have dropped it)."""
    from django.core.mail import send_mail
    left = account.premium_until and (account.premium_until - tz_now()).total_seconds() / 86400
    if not (account.active and account.email and left and 0 < left <= REMIND_DAYS + 1):
        return
    day = account.premium_until.strftime("%Y-%m-%d")
    send_mail(
        "درب: يتجدد اشتراكك السنوي قريبًا / Darb: your annual plan renews soon",
        f"يتجدد اشتراك درب بلس السنوي يوم {day}. لإلغائه: الإعدادات ← إدارة أو إلغاء في التطبيق، أو من حسابك في المتجر.\n\n"
        f"Your Darb Plus annual plan renews on {day}. To cancel: Settings → Manage or cancel in the app, or your "
        f"App Store / Google Play account.\nQuestions: {settings.DARB_SUPPORT_EMAIL}",
        None, [account.email])


def forget(account):
    """Account deletion: remove the subscriber from RevenueCat (their purchase records stay with the stores)."""
    if settings.DARB_REVENUECAT_API_KEY:
        try:
            _rc("DELETE", account.public_id)
        except (urllib.error.URLError, ValueError) as e:
            log.warning("revenuecat delete %s failed: %s", account.public_id, e)
