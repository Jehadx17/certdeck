"""Pack files and keys (docs/DARB-PACKS.md).

A built pack is `DPK1 | nonce (12) | AES-256-GCM(gzip(JSON))`, the AAD binding it to `darb:<slug>:<version>`. Each
version gets a fresh random key, kept in the database only wrapped with DARB_PACK_KEK. The file lives on the CDN; the key
goes only to a subscribed account's device (rate-limited, logged), together with a per-account watermark seed the app
uses to make its copy unique. This raises the cost of scraping; it cannot stop someone who roots a phone."""
import base64
import gzip
import hashlib
import hmac
import json
import os
from datetime import timedelta

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from django.conf import settings
from django.utils.timezone import now as tz_now

from .auth import ApiError
from .models import Pack, PackGrant, PackItem

MAGIC = b"DPK1"
KEYS_PER_DEVICE_DAY = 40  # every pack a student could use, a few times over


def _kek():
    raw = base64.b64decode(settings.DARB_PACK_KEK or "")
    if len(raw) != 32:
        raise ApiError(503, "pack keys are not configured on the server")
    return AESGCM(raw)


def wrap(slug, key):
    nonce = os.urandom(12)
    return base64.b64encode(nonce + _kek().encrypt(nonce, key, slug.encode())).decode()


def unwrap(slug, wrapped):
    raw = base64.b64decode(wrapped)
    return _kek().decrypt(raw[:12], raw[12:], slug.encode())


def card(pack, item):
    """The card as the app stores it: id "<slug>:<n>", the pack's slug, its topic as the study "domain" (the app's
    weighted queue, readiness and mock tests run on topics), and the item's content."""
    return {**item.data, "id": f"{pack.slug}:{item.n}", "pack": pack.slug,
            "certs": {pack.slug: item.data.get("topic") or "t1"}}


def build(pack):
    """Encrypts the pack's verified items as a new version. Returns (file bytes, sample bytes); the caller uploads both
    to storage, and the pack row (version, size, sha256, wrapped key) is saved here."""
    items = list(PackItem.objects.filter(pack=pack, status="verified").order_by("n"))
    if not items:
        raise ValueError(f"{pack.slug}: no verified items")
    version = pack.version + 1
    meta = {"slug": pack.slug, "version": version, "title_ar": pack.title_ar, "title_en": pack.title_en,
            "subject": pack.subject, "exams": pack.exams, "topics": pack.topics}
    body = gzip.compress(json.dumps({**meta, "cards": [card(pack, i) for i in items]}, ensure_ascii=False).encode())
    key, nonce = AESGCM.generate_key(bit_length=256), os.urandom(12)
    blob = MAGIC + nonce + AESGCM(key).encrypt(nonce, body, f"darb:{pack.slug}:{version}".encode())
    sample = gzip.compress(json.dumps({**meta, "sample": True, "cards": [card(pack, i) for i in items[:pack.sample_size]]},
                                      ensure_ascii=False).encode())
    pack.version, pack.items, pack.size = version, len(items), len(blob)
    pack.sha256, pack.key_wrapped = hashlib.sha256(blob).hexdigest(), wrap(pack.slug, key)
    pack.save()
    return blob, sample


def decrypt(slug, version, key, blob):
    """The app's side, for tests and the restore check: file + key -> the pack's JSON."""
    if blob[:4] != MAGIC:
        raise ValueError("not a Darb pack")
    return json.loads(gzip.decompress(AESGCM(key).decrypt(blob[4:16], blob[16:], f"darb:{slug}:{version}".encode())))


def cdn(path):
    return f"https://cdn.{settings.DARB_DOMAIN}/packs/{path}"


def manifest():
    return [{"slug": p.slug, "title_ar": p.title_ar, "title_en": p.title_en, "segments": p.segments, "exams": p.exams,
             "grades": p.grades, "subject": p.subject, "topics": p.topics, "version": p.version, "items": p.items, "size": p.size,
             "sha256": p.sha256, "url": cdn(f"{p.slug}/{p.version}.dpk"), "sample_url": cdn(f"{p.slug}/sample-{p.version}.json.gz")}
            for p in Pack.objects.filter(published=True).order_by("slug")]


def watermark_seed(account):
    """Stable per account, unguessable: the app derives each card's option order and an invisible marker from it, so a
    leaked copy points back to its account (docs/DARB-PACKS.md → Watermark)."""
    return hmac.new(settings.SECRET_KEY.encode(), f"wm:{account.public_id}".encode(), hashlib.sha256).hexdigest()[:32]


def issue_key(account, device, slug, ip=None):
    """A pack key for a subscribed account's device."""
    from .billing import require_premium

    require_premium(account)
    pack = Pack.objects.filter(slug=slug, published=True).first()
    if not pack:
        raise ApiError(404, "no such pack")
    if PackGrant.objects.filter(device=device, created__gte=tz_now() - timedelta(days=1)).count() >= KEYS_PER_DEVICE_DAY:
        raise ApiError(429, "Too many downloads today. Try again tomorrow.", code="rate")
    PackGrant.objects.create(account=account, device=device, pack=pack, version=pack.version, ip=ip)
    return {"slug": pack.slug, "version": pack.version, "key": base64.b64encode(unwrap(pack.slug, pack.key_wrapped)).decode(),
            "seed": watermark_seed(account)}
