import base64
import binascii
import functools
import hashlib
import json
import os
import re
import uuid
from datetime import datetime, timezone

import jsonschema
from django.conf import settings
from django.db.models import Count, Sum
from django.utils.timezone import now as tz_now
from django.http import FileResponse
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import exception_handler as drf_exception_handler

from . import ai, stats
from .auth import ApiError
from .models import AiCall, Doc, now_ms, save_docs

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
    cursor, docs = body.get("cursor", 0), body.get("docs") or []
    if not isinstance(cursor, int) or not isinstance(docs, list):
        raise ApiError(400, "cursor (int) and docs (list) required")
    save_docs([_doc(d) for d in docs])
    rows = list(Doc.objects.filter(seq__gt=cursor).order_by("seq")[:PAGE + 1])
    more = len(rows) > PAGE
    rows = rows[:PAGE]
    return Response({"docs": [r.as_json() for r in rows], "cursor": rows[-1].seq if rows else cursor, "more": more})


def _media_path(name):
    if not MEDIA_NAME.fullmatch(name):
        raise ApiError(400, "media name must be <sha256 hex>.(png|jpg|jpeg|webp|gif)")
    return settings.CERTDECK_MEDIA_DIR / name


def _write_media(name, data):
    path = _media_path(name)
    if hashlib.sha256(data).hexdigest() != name.split(".")[0]:
        raise ApiError(400, f"{name}: sha256 of the bytes doesn't match the name")
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f".{name}.{uuid.uuid4().hex}.tmp")
        tmp.write_bytes(data)
        os.replace(tmp, path)


@api_view(["GET", "PUT"])
def media(request, name):
    if request.method == "PUT":
        _write_media(name, request.body)
        return Response({"ok": True})
    path = _media_path(name)
    if not path.exists():
        raise ApiError(404, "media not found")
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
    return Response(ai.generate(_body(request)))


@api_view(["POST"])
def explain(request):
    return Response(ai.explain(_body(request)))


@api_view(["POST"])
def variants(request):
    return Response(ai.variants(_body(request)))


@api_view(["POST"])
def analyze(request):
    return Response(ai.analyze(_body(request)))


@api_view(["GET"])
def usage(request):
    """AI spend from the AiCall log: this calendar month (UTC) and all time."""
    since = tz_now().replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    month = AiCall.objects.filter(created__gte=since)
    agg = month.aggregate(usd=Sum("cost_usd"), calls=Count("id"))
    return Response({
        "month": since.strftime("%Y-%m"), "usd": float(agg["usd"] or 0), "calls": agg["calls"],
        "batch_calls": month.filter(batch=True).count(),
        "by_endpoint": {r["endpoint"]: float(r["usd"]) for r in month.values("endpoint").annotate(usd=Sum("cost_usd"))},
        "all_time_usd": float(AiCall.objects.aggregate(usd=Sum("cost_usd"))["usd"] or 0),
    })


@api_view(["POST"])
def optimize(request):
    return Response(stats.optimize())


@functools.cache
def cards_schema():
    return jsonschema.Draft202012Validator(json.loads(settings.CARDS_SCHEMA_PATH.read_text()))


def _card_media(card):
    names = list(card.get("question_images") or []) + list(card.get("answer_images") or [])
    return names + [card["image"]] if card.get("image") else names


@api_view(["GET"])
def export(request):
    cards = [dict(d.data, id=d.id) for d in Doc.objects.filter(kind="card", deleted=False).order_by("seq")]
    media = {}
    for name in {n for c in cards for n in _card_media(c) if isinstance(n, str) and MEDIA_NAME.fullmatch(n)}:
        path = settings.CERTDECK_MEDIA_DIR / name
        if path.exists():
            media[name] = base64.b64encode(path.read_bytes()).decode()
    return Response({
        "format": "certdeck", "version": 1, "exported_at": datetime.now(timezone.utc).isoformat(),
        "certs": [d.data for d in Doc.objects.filter(kind="cert", deleted=False).order_by("id")],
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
    now, docs = now_ms(), []
    for card in body["cards"]:
        card = dict(card)
        card_id = card.pop("id", None) or str(uuid.uuid4())
        if len(card_id) > 64:
            raise ApiError(400, f"card id too long: {card_id[:80]}")
        card.setdefault("created_at", now)
        card.setdefault("source", "import")
        card.setdefault("new", "fsrs" not in card)
        docs.append({"id": card_id, "kind": "card", "data": card, "updated_at": now, "deleted": False})
    for name, data in media.items():
        _write_media(name, data)
    save_docs(docs)
    return Response({"imported": len(docs)})
