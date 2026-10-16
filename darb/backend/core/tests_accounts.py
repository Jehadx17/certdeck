import json
import re
import time
from datetime import date, timedelta
from types import SimpleNamespace as NS
from unittest import mock

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from django.core import mail
from django.test import TestCase, override_settings
from django.utils.timezone import now as tz_now

from core import signin
from core.models import Account, Device, Doc
from core.tests import make_account

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
GOOGLE_AUD = "server-client.apps.googleusercontent.com"


def id_token(provider="google", sub="g-1", aud=None, exp=3600, key=KEY, **claims):
    iss = "https://accounts.google.com" if provider == "google" else "https://appleid.apple.com"
    now = int(time.time())
    return jwt.encode({"iss": iss, "aud": aud or (GOOGLE_AUD if provider == "google" else "sa.darbedu.app"), "sub": sub,
                       "iat": now, "exp": now + exp, "email": f"{sub}@example.com", "email_verified": True, **claims},
                      key, algorithm="RS256", headers={"kid": "k1"})


class FakeJwks:
    def get_signing_key_from_jwt(self, token):
        return NS(key=KEY.public_key())


@override_settings(DARB_GOOGLE_CLIENT_IDS=[GOOGLE_AUD], DARB_APPLE_AUDIENCES=["sa.darbedu.app"],
                   DARB_REVENUECAT_WEBHOOK_AUTH="Bearer hook-secret", DARB_REVENUECAT_API_KEY="")
class AccountTests(TestCase):
    def setUp(self):
        p = mock.patch("core.signin._jwks", return_value=FakeJwks())
        p.start()
        self.addCleanup(p.stop)
        self.adult = date.today().year - 25
        self.minor = date.today().year - 15

    def post(self, url, body=None, auth=None):
        return self.client.post(url, body or {}, content_type="application/json", **(auth or {}))

    def sign_in(self, provider="google", **kw):
        body = {"id_token": kw.pop("token", None) or id_token(provider, **{k: v for k, v in kw.items() if k in ("sub", "aud", "exp")}),
                "platform": "android", **{k: v for k, v in kw.items() if k not in ("sub", "aud", "exp")}}
        return self.post(f"/api/auth/{provider}", body)

    def test_google_sign_in_creates_then_finds_the_account(self):
        r = self.sign_in(birth_year=self.adult)
        self.assertEqual(r.status_code, 200, r.content)
        first = r.json()
        self.assertTrue(first["new"])
        self.assertEqual((first["account"]["email"], first["account"]["guardian"], first["account"]["premium"]),
                         ("g-1@example.com", "not_needed", False))
        again = self.sign_in().json()  # a second phone: same account, its own token
        self.assertFalse(again["new"])
        self.assertEqual(again["account"]["id"], first["account"]["id"])
        self.assertNotEqual(again["token"], first["token"])
        self.assertEqual(Device.objects.count(), 2)
        auth = {"HTTP_AUTHORIZATION": f"Bearer {first['token']}"}
        self.assertEqual(self.client.get("/api/me", **auth).json()["id"], first["account"]["id"])
        self.assertEqual(self.post("/api/auth/signout", auth=auth).status_code, 200)
        self.assertEqual(self.client.get("/api/me", **auth).status_code, 401)  # that phone's token is gone

    def test_rejected_tokens(self):
        self.assertEqual(self.sign_in(aud="someone-else", birth_year=self.adult).status_code, 401)
        self.assertEqual(self.sign_in(exp=-3600, birth_year=self.adult).status_code, 401)
        forged = id_token(key=rsa.generate_private_key(public_exponent=65537, key_size=2048))
        self.assertEqual(self.sign_in(token=forged, birth_year=self.adult).status_code, 401)
        unverified = id_token(email_verified=False)
        self.assertEqual(self.sign_in(token=unverified, birth_year=self.adult).status_code, 401)
        self.assertEqual(self.post("/api/auth/facebook", {"id_token": "x"}).status_code, 404)
        self.assertFalse(Account.objects.exists())

    def test_age_gate(self):
        r = self.sign_in()  # a new account must give its birth year
        self.assertEqual((r.status_code, r.json()["code"]), (400, "birth_year"))
        r = self.sign_in(birth_year=date.today().year - 10)
        self.assertEqual((r.status_code, r.json()["code"]), (403, "too_young"))
        self.assertFalse(Account.objects.exists())
        self.assertEqual(self.sign_in(birth_year=date.today().year - 12).status_code, 200)  # 11 or 12: allowed

    def test_minor_without_the_guardian_step(self):  # the default (DARB_GUARDIAN_CONSENT off)
        r = self.sign_in("apple", sub="a-1", birth_year=self.minor, name="Sara")
        self.assertEqual(r.json()["account"]["guardian"], "not_needed")
        auth = {"HTTP_AUTHORIZATION": f"Bearer {r.json()['token']}"}
        self.assertEqual(self.post("/api/sync", {"docs": []}, auth).status_code, 200)

    @override_settings(DARB_GUARDIAN_CONSENT=True)
    def test_minor_needs_the_guardian_before_anything_is_stored(self):
        r = self.sign_in("apple", sub="a-1", birth_year=self.minor, name="Sara")
        self.assertEqual(r.json()["account"]["guardian"], "pending")
        auth = {"HTTP_AUTHORIZATION": f"Bearer {r.json()['token']}"}
        blocked = self.post("/api/sync", {"docs": []}, auth)
        self.assertEqual((blocked.status_code, blocked.json()["code"]), (403, "guardian"))
        self.assertEqual(self.client.get("/api/me", **auth).status_code, 200)
        self.assertEqual(self.post("/api/account/guardian", {"email": "a-1@example.com"}, auth).status_code, 400)  # own email
        self.assertEqual(self.post("/api/account/guardian", {"email": "mom@example.com"}, auth).status_code, 200)
        link = re.search(r"https://\S+/consent/(\S+)", mail.outbox[0].body).group(1)
        self.assertEqual(mail.outbox[0].to, ["mom@example.com"])
        page = self.client.get(f"/consent/{link}")
        self.assertContains(page, "Sara")
        self.assertEqual(self.client.get("/consent/wrong").status_code, 404)
        self.client.post(f"/consent/{link}", {"action": "confirm", "weekly": "on"})
        a = Account.objects.get(apple_sub="a-1")
        self.assertTrue(a.guardian_ok_at and a.guardian_weekly)
        self.assertEqual(self.post("/api/sync", {"docs": []}, auth).status_code, 200)
        self.assertEqual(self.client.get("/api/me", **auth).json()["guardian"], "ok")
        # The weekly summary the guardian asked for: queued a week out, sent with this week's numbers, stoppable.
        from core import jobs
        from core.models import Job
        from core.tasks import guardian_weekly
        self.assertTrue(Job.objects.filter(kind="guardian_weekly", account=a).exists())
        now_ms = int(time.time() * 1000)
        self.post("/api/sync", {"reviews": [{"ts": now_ms - 1000, "card_id": "q:1", "rating": 3, "correct": True},
                                            {"ts": now_ms - 900, "card_id": "q:2", "rating": 1}]}, auth)
        mail.outbox.clear()
        self.assertEqual(guardian_weekly(Account.objects.get(pk=a.pk), ""), 7 * 86400)
        self.assertEqual(mail.outbox[0].to, ["mom@example.com"])
        self.assertIn("answered 2 questions, 50% right", mail.outbox[0].body)
        stop = re.search(r"https://\S+(/weekly-off/\S+)", mail.outbox[0].body).group(1)
        self.assertEqual(self.client.get(stop.replace("weekly-off/", "weekly-off/x")).status_code, 404)
        self.client.get(stop)
        self.assertIsNone(guardian_weekly(Account.objects.get(pk=a.pk), ""))  # off: the job ends
        # The same link withdraws consent later: the account and its data are deleted.
        self.assertContains(self.client.get(f"/consent/{link}"), "withdraw")
        self.client.post(f"/consent/{link}", {"action": "withdraw"})
        self.assertFalse(Account.objects.exists())

    def test_delete_account(self):
        a, auth = make_account()
        self.post("/api/sync", {"docs": [{"id": "settings", "kind": "settings", "data": {}, "updated_at": 1}]}, auth)
        with mock.patch("core.billing.forget") as forget, mock.patch("core.signin.apple_revoke") as revoke:
            self.assertEqual(self.client.delete("/api/account", **auth).json(), {"deleted": True})
        forget.assert_called_once()
        revoke.assert_called_once()
        self.assertFalse(Account.objects.exists() or Doc.objects.exists())
        self.assertEqual(self.client.get("/api/me", **auth).status_code, 401)

    def test_subscription_lifecycle_from_webhooks(self):
        a, auth = make_account()
        upload = lambda: self.client.get("/api/upload/0b5c6e1a-8f43-4b8e-9b51-1f6a9f6b9a10/0", **auth)
        self.assertEqual((upload().status_code, upload().json()["code"]), (403, "premium"))

        def hook(kind, expires, auth_header="Bearer hook-secret"):
            event = {"event": {"type": kind, "app_user_id": a.public_id, "aliases": [a.public_id], "product_id": "darb_monthly",
                               "expiration_at_ms": int(expires.timestamp() * 1000), "environment": "SANDBOX"}}
            return self.client.post("/api/billing/revenuecat", json.dumps(event), content_type="application/json",
                                    HTTP_AUTHORIZATION=auth_header)

        self.assertEqual(hook("INITIAL_PURCHASE", tz_now() + timedelta(days=30), "Bearer wrong").status_code, 401)
        self.assertEqual(hook("INITIAL_PURCHASE", tz_now() + timedelta(days=30)).status_code, 200)
        self.assertTrue(self.client.get("/api/me", **auth).json()["premium"])
        self.assertEqual(upload().status_code, 200)
        # The subscription lapses: access ends with it.
        hook("EXPIRATION", tz_now() - timedelta(minutes=1))
        self.assertFalse(self.client.get("/api/me", **auth).json()["premium"])
        self.assertEqual(upload().status_code, 403)

    def test_annual_renewal_reminder_3_days_before(self):
        from core import jobs, tasks  # noqa: F401 (tasks registers the handlers)
        from core.models import Job
        a, _ = make_account()

        def hook(kind, days):
            event = {"event": {"type": kind, "app_user_id": a.public_id, "product_id": "darb_annual",
                               "expiration_at_ms": int((tz_now() + timedelta(days=days)).timestamp() * 1000)}}
            self.client.post("/api/billing/revenuecat", json.dumps(event), content_type="application/json",
                             HTTP_AUTHORIZATION="Bearer hook-secret")

        hook("INITIAL_PURCHASE", 365)
        job = Job.objects.get(kind="renewal_reminder", account=a)
        self.assertAlmostEqual((job.run_at - tz_now()).total_seconds() / 86400, 362, places=2)
        hook("CANCELLATION", 365)  # auto-renew turned off: no reminder
        self.assertFalse(Job.objects.filter(kind="renewal_reminder").exists())
        hook("UNCANCELLATION", 2)  # renews in 2 days: due now
        self.assertTrue(jobs.run_one())
        self.assertEqual(len(mail.outbox), 1)
        self.assertIn("renews on", mail.outbox[0].body)
        self.assertFalse(Job.objects.filter(kind="renewal_reminder").exists())

    @override_settings(DARB_REVENUECAT_API_KEY="sk_test")
    def test_backend_reads_the_entitlement_from_revenuecat(self):
        a, auth = make_account()
        until = (tz_now() + timedelta(days=365)).replace(microsecond=0)
        sub = {"subscriber": {"entitlements": {"premium": {
            "expires_date": until.isoformat().replace("+00:00", "Z"), "grace_period_expires_date": None}}}}
        with mock.patch("core.billing._rc", return_value=sub) as rc:
            r = self.post("/api/billing/refresh", auth=auth)  # the app just bought: no waiting for the webhook
        rc.assert_called_once_with("GET", a.public_id)
        self.assertEqual((r.json()["premium"], r.json()["premium_until"]), (True, until.isoformat()))
        # A webhook only triggers a re-read: its payload's own dates are not trusted when the key is set.
        with mock.patch("core.billing._rc", return_value={"subscriber": {"entitlements": {}}}):
            self.client.post("/api/billing/revenuecat", json.dumps({"event": {"type": "RENEWAL", "app_user_id": a.public_id,
                             "expiration_at_ms": 4102444800000}}), content_type="application/json",
                             HTTP_AUTHORIZATION="Bearer hook-secret")
        self.assertFalse(self.client.get("/api/me", **auth).json()["premium"])


class AgeTests(TestCase):
    def test_bounds(self):
        today = date(2026, 10, 15)
        self.assertEqual(signin.age_bounds(2009, today), (16, 17))  # 16 or 17: a minor either way
        self.assertEqual(signin.age_bounds(2008, today), (17, 18))  # may still be 17: treated as a minor


class CleanupTests(TestCase):
    def test_unconfirmed_minors_are_deleted_after_30_days(self):
        from core import tasks
        from django.utils.timezone import now as tz_now
        minor, _ = make_account("m@example.com", birth_year=date.today().year - 14)
        adult, _ = make_account("a@example.com", birth_year=date.today().year - 30)
        Account.objects.update(created=tz_now() - timedelta(days=31))
        tasks.drop_unconfirmed_minors()
        self.assertEqual(Account.objects.count(), 2)  # the default: no guardian step, so nobody is unconfirmed
        with override_settings(DARB_GUARDIAN_CONSENT=True):
            tasks.drop_unconfirmed_minors()
        self.assertEqual(list(Account.objects.values_list("email", flat=True)), ["a@example.com"])
