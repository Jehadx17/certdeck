from datetime import timedelta
from decimal import Decimal
from types import SimpleNamespace as NS
from unittest import mock

from django.test import TestCase, override_settings
from django.utils.timezone import now as tz_now

from core import ai
from core.models import AiCache, AiCall, Config
from core.tests import make_account, message

CARD = {"type": "mcq", "question": "ما ناتج ٣×٤؟", "options": ["7", "12"], "correct": [1], "explanation": "٣×٤=١٢"}


@override_settings(ANTHROPIC_API_KEY="")
class GatewayTests(TestCase):
    def setUp(self):
        self.a, self.auth = make_account()
        self.sent = []

        def create(**kw):
            self.sent.append(kw)
            return message({"reply": "شرح"})
        p = mock.patch("core.ai._create", side_effect=create)
        p.start()
        self.addCleanup(p.stop)

    def explain(self, messages=None, card=CARD):
        return self.client.post("/api/ai/explain", {"card": card, "messages": messages or []},
                                content_type="application/json", **self.auth)

    def test_haiku_only_safety_first_short_history(self):
        long_chat = [{"role": "user" if i % 2 == 0 else "assistant", "text": f"m{i}"} for i in range(9)]
        self.assertEqual(self.explain(long_chat).json(), {"reply": "شرح"})
        req = self.sent[0]
        self.assertEqual(req["model"], "claude-haiku-5-5")
        self.assertTrue(req["system"][0]["text"].startswith("You are the study helper inside Darb"))
        self.assertLessEqual(len(req["messages"]), ai.HISTORY)  # never the whole conversation
        self.assertLessEqual(req["max_tokens"], 4000)
        self.assertEqual(req["messages"][-1]["content"], "m8")
        with self.assertRaises(ValueError):  # a bigger model can't slip into the runtime path
            ai.call(self.a, "x", ai.params([], [{"role": "user", "content": "hi"}], ai.REPLY_SCHEMA, model="claude-opus-5-5"))

    def test_monthly_cap_then_resets_on_and_admin_reset(self):
        AiCall.objects.create(user=self.a, endpoint="explain", model=ai.MODEL, cost_usd=Decimal("0.03"), ok=True)
        r = self.explain()
        self.assertEqual((r.status_code, r.json()["code"]), (402, "budget"))
        self.assertEqual(r.json()["resets_on"], ai.resets_on().isoformat())
        self.assertEqual(self.sent, [])  # refused before any AI call
        # From the admin: a quota reset, or a bigger free cap, works without an app update.
        self.a.quota_reset_at = tz_now()
        self.a.save()
        self.assertEqual(self.explain().status_code, 200)

    def test_paid_cap_and_daily_quota(self):
        c = Config.get()
        c.free_daily_ai = 2
        c.save()
        for _ in range(2):
            self.assertEqual(self.explain(card={**CARD, "question": f"q{_}"}).status_code, 200)
        r = self.explain(card={**CARD, "question": "q3"})
        self.assertEqual((r.status_code, r.json()["code"]), (402, "daily"))
        self.a.premium_until = tz_now() + timedelta(days=30)  # Plus: the paid limits
        self.a.save()
        self.assertEqual(self.explain(card={**CARD, "question": "q4"}).status_code, 200)
        self.assertEqual(ai.limits(self.a), (0.5, 200))

    def test_too_long_is_refused(self):
        r = self.explain(card={**CARD, "question": "س" * 300_000})
        self.assertEqual((r.status_code, r.json()["code"]), (413, "too_long"))
        self.assertEqual(self.sent, [])

    def test_first_explanation_of_a_card_is_shared(self):
        b, auth_b = make_account("b@example.com")
        self.assertEqual(self.explain().json(), {"reply": "شرح"})
        r = self.client.post("/api/ai/explain", {"card": CARD, "messages": []}, content_type="application/json", **auth_b)
        self.assertEqual(r.json(), {"reply": "شرح"})
        self.assertEqual(len(self.sent), 1)  # the second student got the cached answer: no new call, no cost
        self.assertEqual(AiCache.objects.get().hits, 1)
        self.explain([{"role": "user", "text": "ولماذا؟"}])  # a follow-up question is the student's own: not cached
        self.assertEqual(len(self.sent), 2)

    def test_cost_tracking_uses_the_cheap_tier(self):
        usage = NS(input_tokens=2000, output_tokens=500, cache_read_input_tokens=0, cache_creation_input_tokens=0)
        self.assertAlmostEqual(ai.cost_usd(ai.MODEL, usage), (2000 * 0.10 + 500 * 0.50) / 1e6)
        self.assertAlmostEqual(ai.cost_usd(ai.MODEL, usage, batch=True), (2000 * 0.10 + 500 * 0.50) / 2e6)


class AdminTests(TestCase):
    def test_lookup_spend_and_quota_reset(self):
        from django.contrib.auth.models import User
        admin_user = User.objects.create_superuser("me", "me@example.com", "x")
        self.client.force_login(admin_user)
        a, _ = make_account("student@example.com")
        AiCall.objects.create(user=a, endpoint="explain", model=ai.MODEL, cost_usd=Decimal("0.01"), ok=True)
        r = self.client.get("/darb-admin/core/account/?q=student")
        self.assertContains(r, "student@example.com")
        self.assertContains(r, "$0.0100")
        r = self.client.get("/darb-admin/core/aicall/")
        self.assertContains(r, "This month")
        self.assertContains(r, "explain")
        self.client.post("/darb-admin/core/account/", {"action": "reset_ai_quota", "_selected_action": [a.pk]})
        a.refresh_from_db()
        self.assertIsNotNone(a.quota_reset_at)
        self.assertEqual(ai.spent(a), 0)
        self.assertEqual(self.client.get("/darb-admin/core/config/").status_code, 200)
        self.client.logout()
        self.assertEqual(self.client.get("/darb-admin/core/account/").status_code, 302)  # login required
