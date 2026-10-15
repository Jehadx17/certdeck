from datetime import timedelta

from django.test import TestCase
from django.utils.timezone import now as tz_now

from core import limits
from core.auth import ApiError
from core.models import Account, Device, Pack, PackGrant
from core.tests import make_account


class LimitTests(TestCase):
    def test_fixed_window_limit(self):
        for _ in range(3):
            limits.hit("x", "1.2.3.4", limit=3, window=60)
        with self.assertRaises(ApiError) as e:
            limits.hit("x", "1.2.3.4", limit=3, window=60)
        self.assertEqual(e.exception.error_code, "rate")
        limits.hit("x", "5.6.7.8", limit=3, window=60)  # another IP has its own count

    def test_reports_are_limited_per_account(self):
        a, auth = make_account()
        for _ in range(limits.LIMITS["report_account"][0]):
            self.client.post("/api/report", {"card_id": "x:1"}, content_type="application/json", **auth)
        r = self.client.post("/api/report", {"card_id": "x:1"}, content_type="application/json", **auth)
        self.assertEqual(r.status_code, 429)

    def test_anomalies_suspend_a_sharing_account_and_it_can_appeal(self):
        sharer, auth = make_account(premium_until=tz_now() + timedelta(days=30))
        honest, _ = make_account("h@example.com", premium_until=tz_now() + timedelta(days=30))
        pack = Pack.objects.create(slug="p", title_ar="p", title_en="p", published=True)
        for i in range(7):  # one account, seven phones fetching keys today
            d, _ = Device.issue(sharer, "android")
            PackGrant.objects.create(account=sharer, device=d, pack=pack, version=1, ip=f"10.0.0.{i}")
        PackGrant.objects.create(account=honest, device=Device.issue(honest)[0], pack=pack, version=1, ip="10.1.0.1")
        found = limits.anomalies()
        self.assertEqual([(a.pk, r) for a, r in found], [(sharer.pk, "pack keys on more than 5 devices in a day")])
        sharer.refresh_from_db()
        self.assertFalse(sharer.active)
        self.assertTrue(Account.objects.get(pk=honest.pk).active)
        r = self.client.get("/api/me", **auth)
        self.assertEqual(r.status_code, 401)  # suspended: the API is closed; sign-in says how to appeal
