import base64
import os
from datetime import timedelta

from cryptography.exceptions import InvalidTag
from django.test import TestCase, override_settings
from django.utils.timezone import now as tz_now

from core import packs
from core.models import Doc, Pack, PackItem, Report
from core.tests import make_account

KEK = base64.b64encode(os.urandom(32)).decode()


def make_pack(slug="qudurat-verbal", n=30):
    p = Pack.objects.create(slug=slug, title_ar="القدرات - لفظي", title_en="Qudurat - verbal", segments=["high"],
                            exams=["qudurat"], published=True, sample_size=5)
    for i in range(n):
        PackItem.objects.create(pack=p, n=i + 1, status="verified" if i % 10 else "quarantined",
                                data={"type": "mcq", "question": f"س{i}", "options": ["أ", "ب", "ج", "د"], "correct": [1]})
    return p


@override_settings(DARB_PACK_KEK=KEK)
class PackTests(TestCase):
    def test_build_encrypts_verified_items_only(self):
        p = make_pack()
        blob, sample = packs.build(p)
        p.refresh_from_db()
        self.assertEqual((p.version, p.items, p.size), (1, 27, len(blob)))  # 3 quarantined items are left out
        key = packs.unwrap(p.slug, p.key_wrapped)
        data = packs.decrypt(p.slug, 1, key, blob)
        self.assertEqual(len(data["cards"]), 27)
        self.assertEqual(data["cards"][0]["id"], "qudurat-verbal:2")
        self.assertNotIn("س", blob.decode("latin-1"))  # nothing readable in the file
        self.assertEqual(len(__import__("json").loads(__import__("gzip").decompress(sample))["cards"]), 5)
        tampered = blob[:-1] + bytes([blob[-1] ^ 1])
        with self.assertRaises(InvalidTag):
            packs.decrypt(p.slug, 1, key, tampered)
        with self.assertRaises(InvalidTag):  # a file can't be passed off as another pack or version
            packs.decrypt(p.slug, 2, key, blob)
        blob2, _ = packs.build(p)  # a rebuild is a new version with a new key
        self.assertNotEqual(packs.unwrap(p.slug, Pack.objects.get(pk=p.pk).key_wrapped), key)

    def test_keys_only_for_subscribers_and_rate_limited(self):
        p = make_pack()
        packs.build(p)
        free, free_auth = make_account()
        r = self.client.post(f"/api/packs/{p.slug}/key", **free_auth)
        self.assertEqual((r.status_code, r.json()["code"]), (403, "premium"))
        manifest = self.client.get("/api/packs", **free_auth).json()
        self.assertEqual(manifest["packs"][0]["sample_url"], "https://cdn.darbedu.sa/packs/qudurat-verbal/sample-1.json.gz")
        paid, auth = make_account("p@example.com", premium_until=tz_now() + timedelta(days=30))
        got = self.client.post(f"/api/packs/{p.slug}/key", **auth).json()
        self.assertEqual(got["version"], 1)
        self.assertEqual(base64.b64decode(got["key"]), packs.unwrap(p.slug, Pack.objects.get(pk=p.pk).key_wrapped))
        self.assertEqual(got["seed"], packs.watermark_seed(paid))
        self.assertNotEqual(got["seed"], packs.watermark_seed(free))
        self.assertEqual(self.client.post("/api/packs/nope/key", **auth).status_code, 404)
        for _ in range(packs.KEYS_PER_DEVICE_DAY - 1):
            self.client.post(f"/api/packs/{p.slug}/key", **auth)
        r = self.client.post(f"/api/packs/{p.slug}/key", **auth)
        self.assertEqual((r.status_code, r.json()["code"]), (429, "rate"))

    def test_report_a_mistake_and_the_fixed_notice(self):
        from django.contrib.auth.models import User
        p = make_pack()
        a, auth = make_account()
        self.client.post("/api/report", {"card_id": f"{p.slug}:3", "note": "المفتاح خطأ"}, content_type="application/json", **auth)
        self.assertEqual(PackItem.objects.get(pack=p, n=3).reports, 1)
        self.client.force_login(User.objects.create_superuser("me", "me@example.com", "x"))
        self.client.post("/darb-admin/core/report/", {"action": "mark_fixed", "_selected_action": [Report.objects.get().pk]})
        notice = Doc.objects.get(user=a, kind="notice")
        self.assertEqual(notice.data["card_id"], f"{p.slug}:3")
