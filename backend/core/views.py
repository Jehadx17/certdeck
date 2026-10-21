import base64
import binascii
import functools
import hashlib
import json
import os
import re
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import jsonschema
from django.conf import settings
from django.core.exceptions import ValidationError
from django.core.validators import validate_email
from django.db.models import Count, Sum
from django.http import FileResponse
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import exception_handler as drf_exception_handler

from . import ai, college, ingest, stats
from .auth import ApiError
from .models import Account, AiCall, Media, docs, now_ms, save_docs

PAGE = 1000
MEDIA_NAME = re.compile(r"([0-9a-f]{64})\.(png|jpg|jpeg|webp|gif)")
MEDIA_TYPES = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "gif": "image/gif"}


def exception_handler(exc, context):
    response = drf_exception_handler(exc, context)
    if response is not None:
        response.data = {"error": str(getattr(exc, "detail", exc))}
    return response


def _body(request):
    if not isinstance(request.data, dict):
        raise ApiError(400, "JSON object expected")
    return request.data


@api_view(["GET"])
@permission_classes([AllowAny])
def health(request):
    return Response({"ok": True})


LOGIN_FAILURES = 10  # wrong passwords per email per 10 minutes, then 429
DEFAULT_CAP = Decimal("10")  # monthly AI budget of a self-registered student


def _credentials(request):
    body = _body(request)
    email, password = str(body.get("email", "")).strip().lower(), str(body.get("password", ""))
    try:
        validate_email(email)
    except ValidationError:
        raise ApiError(400, "Enter a valid email address.")
    return email, password


def _signed_in(account):
    account.save()
    token = account.new_token()  # one per device: signing in on another phone keeps this one signed in
    return Response({"token": token, "name": account.name, "role": account.role})


@api_view(["POST"])
@permission_classes([AllowAny])
def signup(request):
    from .models import Account

    email, password = _credentials(request)
    if len(password) < 8:
        raise ApiError(400, "The password needs at least 8 characters.")
    if Account.objects.filter(email=email).exists() or Account.objects.filter(name=email).exists():
        raise ApiError(400, "That email already has an account. Sign in instead.")
    account = Account(name=email, email=email, cap_usd=DEFAULT_CAP)
    account.set_password(password)
    return _signed_in(account)


@api_view(["POST"])
@permission_classes([AllowAny])
def login(request):
    from django.core.cache import cache

    from .models import Account

    email, password = _credentials(request)
    key = "login_failures:" + hashlib.sha256(email.encode()).hexdigest()
    if cache.get(key, 0) >= LOGIN_FAILURES:
        raise ApiError(429, "Too many tries. Wait 10 minutes.")
    account = Account.objects.filter(email=email, active=True).first()
    if not (account and account.check_password(password)):
        cache.add(key, 0, 600)
        cache.incr(key)
        raise ApiError(400, "Wrong email or password.")
    return _signed_in(account)


def _doc(d):
    """Validates one incoming sync doc."""
    if not (isinstance(d, dict) and isinstance(d.get("id"), str) and 0 < len(d["id"]) <= 64
            and isinstance(d.get("kind"), str) and 0 < len(d["kind"]) <= 32 and isinstance(d.get("data"), dict)
            and isinstance(d.get("updated_at"), int) and not isinstance(d.get("updated_at"), bool)
            and isinstance(d.get("deleted", False), bool)):
        raise ApiError(400, "each doc needs id (<=64 chars), kind, data (object), updated_at (int ms), deleted (bool)")
    return d


@api_view(["POST"])
def sync(request):
    body = _body(request)
    cursor, incoming = body.get("cursor", 0), body.get("docs") or []
    if not isinstance(cursor, int) or not isinstance(incoming, list):
        raise ApiError(400, "cursor (int) and docs (list) required")
    save_docs(request.account, [_doc(d) for d in incoming])
    rows = list(docs(request.account).filter(seq__gt=cursor).order_by("seq")[:PAGE + 1])
    more = len(rows) > PAGE
    rows = rows[:PAGE]
    return Response({"docs": [r.as_json() for r in rows], "cursor": rows[-1].seq if rows else cursor, "more": more})


def _media_path(name):
    if not MEDIA_NAME.fullmatch(name):
        raise ApiError(400, "media name must be <sha256 hex>.(png|jpg|jpeg|webp|gif)")
    return settings.CERTDECK_MEDIA_DIR / name


def write_media(user, name, data):
    """Stores a content-addressed file once and lets [user] read it."""
    path = _media_path(name)
    if hashlib.sha256(data).hexdigest() != name.split(".")[0]:
        raise ApiError(400, f"{name}: sha256 of the bytes doesn't match the name")
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f".{name}.{uuid.uuid4().hex}.tmp")
        tmp.write_bytes(data)
        os.replace(tmp, path)
    Media.objects.get_or_create(user=user, name=name)


def _own_media(user, name):
    """The file, if [user] uploaded it (or it was made for them); a hash alone never grants access."""
    path = _media_path(name)
    if not path.exists() or not Media.objects.filter(user=user, name=name).exists():
        raise ApiError(404, "media not found")
    return path


@api_view(["GET", "PUT"])
def media(request, name):
    if request.method == "PUT":
        write_media(request.account, name, request.body)
        return Response({"ok": True})
    path = _own_media(request.account, name)
    return FileResponse(path.open("rb"), content_type=MEDIA_TYPES[name.rsplit(".", 1)[1]])


@api_view(["GET"])
def app_latest(request):
    """The newest published Android build: {version_code, version_name, sha256}. The app updates itself to it."""
    path = settings.CERTDECK_RELEASE_DIR / "latest.json"
    if not path.exists():
        raise ApiError(404, "no app release published")
    return Response(json.loads(path.read_text()))


@api_view(["GET"])
def app_apk(request):
    path = settings.CERTDECK_RELEASE_DIR / "certdeck.apk"
    if not path.exists():
        raise ApiError(404, "no app release published")
    return FileResponse(path.open("rb"), content_type="application/vnd.android.package-archive")


@api_view(["POST"])
def generate(request):
    return Response(ai.generate(request.account, _body(request)))


@api_view(["POST"])
def explain(request):
    return Response(ai.explain(request.account, _body(request)))


@api_view(["POST"])
def variants(request):
    return Response(ai.variants(request.account, _body(request)))


@api_view(["POST"])
def analyze(request):
    return Response(ai.analyze(request.account, _body(request)))


def budget(user):
    """This calendar month's (UTC) AI spend against the user's cap."""
    month = AiCall.objects.filter(user=user, created__gte=ai.month_start())
    usd = float(month.aggregate(usd=Sum("cost_usd"))["usd"] or 0)
    cap = None if user.cap_usd is None else float(user.cap_usd)
    return {"month": ai.month_start().strftime("%Y-%m"), "usd": round(usd, 6), "cap_usd": cap,
            "remaining_usd": None if cap is None else round(max(0.0, cap - usd), 6)}


@api_view(["GET"])
def me(request):
    """Who the token belongs to: the app shows certs only to the owner. Plus this month's budget."""
    a = request.account
    return Response({"name": a.name, "role": a.role, **budget(a)})


@api_view(["GET"])
def usage(request):
    """The caller's AI spend from the AiCall log: this calendar month (UTC) and all time."""
    user = request.account
    month = AiCall.objects.filter(user=user, created__gte=ai.month_start())
    agg = month.aggregate(calls=Count("id"))
    return Response({
        **budget(user), "calls": agg["calls"], "batch_calls": month.filter(batch=True).count(),
        "by_endpoint": {r["endpoint"]: float(r["usd"]) for r in month.values("endpoint").annotate(usd=Sum("cost_usd"))},
        "all_time_usd": float(AiCall.objects.filter(user=user).aggregate(usd=Sum("cost_usd"))["usd"] or 0),
    })


@api_view(["GET"])
def metrics(request):
    """Study metrics for the caller; the owner can read a student's with ?user=<name>."""
    user = request.account
    name = request.query_params.get("user")
    if name:
        if user.role != "owner":
            raise ApiError(403, "Only the owner can read another account's metrics")
        user = Account.objects.filter(name=name).first()
        if not user:
            raise ApiError(404, "No such account")
    return Response(stats.metrics(user))


@api_view(["POST"])
def optimize(request):
    return Response(stats.optimize(request.account))


@functools.cache
def cards_schema():
    return jsonschema.Draft202012Validator(json.loads(settings.CARDS_SCHEMA_PATH.read_text()))


def _card_media(card):
    names = list(card.get("question_images") or []) + list(card.get("answer_images") or [])
    return names + [card["image"]] if card.get("image") else names


@api_view(["GET"])
def export(request):
    user = request.account
    cards = [dict(d.data, id=d.doc_id) for d in docs(user).filter(kind="card", deleted=False).order_by("seq")]
    owned = set(Media.objects.filter(user=user).values_list("name", flat=True))
    media = {}
    for name in {n for c in cards for n in _card_media(c) if isinstance(n, str) and n in owned}:
        path = settings.CERTDECK_MEDIA_DIR / name
        if MEDIA_NAME.fullmatch(name) and path.exists():
            media[name] = base64.b64encode(path.read_bytes()).decode()
    return Response({
        "format": "certdeck", "version": 1, "exported_at": datetime.now(timezone.utc).isoformat(),
        "certs": [d.data for d in docs(user).filter(kind="cert", deleted=False).order_by("doc_id")],
        "cards": cards, "media": media,
    })


@api_view(["POST"])
def import_(request):
    body = _body(request)
    error = next(iter(sorted(cards_schema().iter_errors(body), key=lambda e: list(e.path))), None)
    if error:
        raise ApiError(400, f"invalid export file at /{'/'.join(map(str, error.path))}: {error.message}")
    media = {}
    for name, b64 in (body.get("media") or {}).items():
        try:
            media[name] = base64.b64decode(b64, validate=True)
        except (binascii.Error, ValueError):
            raise ApiError(400, f"{name}: invalid base64")
        _media_path(name)
        if hashlib.sha256(media[name]).hexdigest() != name.split(".")[0]:
            raise ApiError(400, f"{name}: sha256 of the bytes doesn't match the name")
    now, new = now_ms(), []
    for card in body["cards"]:
        card = dict(card)
        card_id = card.pop("id", None) or str(uuid.uuid4())
        if len(card_id) > 64:
            raise ApiError(400, f"card id too long: {card_id[:80]}")
        card.setdefault("created_at", now)
        card.setdefault("source", "import")
        card.setdefault("new", "fsrs" not in card)
        new.append({"id": card_id, "kind": "card", "data": card, "updated_at": now, "deleted": False})
    for name, data in media.items():
        write_media(request.account, name, data)
    save_docs(request.account, new)
    return Response({"imported": len(new)})


# ---------- college ----------

@api_view(["GET", "PUT"])
def upload(request, material_id, n):
    """Resumable upload of file n of a material: PUT ?offset=<bytes the server has> with the next chunk."""
    if request.method == "GET":
        return Response(ingest.upload_status(request.account, material_id, n))
    try:
        offset = int(request.query_params.get("offset", ""))
    except ValueError:
        raise ApiError(400, "offset (int) required")
    return Response({"size": ingest.upload_chunk(request.account, material_id, n, offset, request.body)})


@api_view(["POST"])
def upload_done(request, material_id, n):
    return Response(ingest.upload_done(request.account, material_id, n, _body(request).get("sha256")))


@api_view(["GET"])
def page_image(request, material_id, page):
    """One page of a processed material as a PNG (the app shows a card's source page)."""
    path = ingest.page_png(request.account, material_id, page)
    return FileResponse(path.open("rb"), content_type="image/png")


def _college(fn):
    @api_view(["POST"])
    def view(request):
        return Response(fn(request.account, _body(request)))
    view.__name__ = fn.__name__
    return view


process = _college(college.start_processing)
prepare = _college(college.prepare)
suggest_scope = _college(college.suggest_scope)
prioritize = _college(college.reprioritize)
grade = _college(college.grade)
practice = _college(college.practice)
night = _college(college.night_sheet)
