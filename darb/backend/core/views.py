import json

from django.db.models import Sum
from django.http import FileResponse
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import exception_handler as drf_exception_handler

from . import ai, college, ingest, jobs
from .auth import ApiError
from .models import REVIEW_MAX_AGE_MS, AiCall, docs, now_ms, reviews_after, save_docs

PAGE = 1000  # docs (and, separately, reviews) per sync response
PUSH_MAX = 500  # docs (and reviews) per sync request; the app sends at most this many
DOC_MAX_BYTES = 64 * 1024  # documents stay small: big content belongs in packs, not in the sync table


def exception_handler(exc, context):
    response = drf_exception_handler(exc, context)
    if response is not None:
        response.data = {"error": str(getattr(exc, "detail", exc))}
        if getattr(exc, "error_code", None):
            response.data["code"] = exc.error_code
    return response


def _body(request):
    if not isinstance(request.data, dict):
        raise ApiError(400, "JSON object expected")
    return request.data


@api_view(["GET"])
@permission_classes([AllowAny])
def health(request):
    """Liveness; with ?deep=1 (the uptime monitor) also the database round trip."""
    if request.query_params.get("deep"):
        from django.db import connection
        with connection.cursor() as c:
            c.execute("SELECT 1")
    return Response({"ok": True})


def _doc(d):
    """Validates one incoming sync doc."""
    if not (isinstance(d, dict) and isinstance(d.get("id"), str) and 0 < len(d["id"]) <= 64
            and isinstance(d.get("kind"), str) and 0 < len(d["kind"]) <= 32 and isinstance(d.get("data"), dict)
            and isinstance(d.get("updated_at"), int) and not isinstance(d.get("updated_at"), bool)
            and isinstance(d.get("deleted", False), bool)):
        raise ApiError(400, "each doc needs id (<=64 chars), kind, data (object), updated_at (int ms), deleted (bool)")
    if len(json.dumps(d["data"], ensure_ascii=False).encode()) > DOC_MAX_BYTES:
        raise ApiError(413, f"doc {d['id']} is larger than {DOC_MAX_BYTES // 1024} KB")
    return d


def _review(r, now):
    """Validates one incoming review (docs/DARB-PROTOCOL.md)."""
    ok = (isinstance(r, dict) and type(r.get("ts")) is int and abs(now - r["ts"]) < REVIEW_MAX_AGE_MS
          and isinstance(r.get("card_id"), str) and 0 < len(r["card_id"]) <= 64 and r.get("rating") in (1, 2, 3, 4)
          and type(r.get("duration_ms", 0)) is int and isinstance(r.get("score"), (int, float, type(None)))
          and isinstance(r.get("error_type"), (str, type(None))))
    if not ok:
        raise ApiError(400, "each review needs ts (int ms, within 400 days), card_id, rating 1-4")
    return {**r, "duration_ms": max(0, min(r.get("duration_ms") or 0, 3_600_000)),
            "error_type": (r.get("error_type") or "")[:40] or None}


def _int_arg(body, key):
    v = body.get(key, 0)
    if type(v) is not int or v < 0:
        raise ApiError(400, f"{key} must be a non-negative int")
    return v


def _queue_work(account, incoming, reviews):
    """Slow work a sync implies goes to the job queue (the worker), never into this request."""
    if reviews:  # an active student: autopilot + re-teach, at most every 6 hours
        jobs.enqueue("daily", account, delay=6 * 3600)
    changed = {d["id"] for d in incoming if d["kind"] == "assessment"}
    if changed:  # edited hints of an already prepared assessment: re-score 2 minutes after the last edit
        prepared = set(docs(account).filter(kind="prio", deleted=False).values_list("data__assessment_id", flat=True))
        for aid in changed & prepared:
            jobs.enqueue("prio", account, aid, delay=120)


@api_view(["POST"])
def sync(request):
    """Push changed docs and new reviews, pull everything after the two cursors (one per stream)."""
    body, now = _body(request), now_ms()
    cursor, rcursor = _int_arg(body, "cursor"), _int_arg(body, "review_cursor")
    incoming, reviews = body.get("docs") or [], body.get("reviews") or []
    if not isinstance(incoming, list) or not isinstance(reviews, list):
        raise ApiError(400, "docs and reviews must be lists")
    if len(incoming) > PUSH_MAX or len(reviews) > PUSH_MAX:
        raise ApiError(413, f"at most {PUSH_MAX} docs and {PUSH_MAX} reviews per request")
    save_docs(request.account, [_doc(d) for d in incoming], [_review(r, now) for r in reviews])
    _queue_work(request.account, incoming, reviews)
    rows = list(docs(request.account).filter(seq__gt=cursor).order_by("seq")[:PAGE + 1])
    revs = reviews_after(request.account, rcursor, PAGE + 1)
    more = len(rows) > PAGE or len(revs) > PAGE
    rows, revs = rows[:PAGE], revs[:PAGE]
    return Response({"docs": [r.as_json() for r in rows], "cursor": rows[-1].seq if rows else cursor,
                     "reviews": [r for _, r in revs], "review_cursor": revs[-1][0] if revs else rcursor, "more": more})


@api_view(["POST"])
def explain(request):
    return Response(ai.explain(request.account, _body(request)))


def budget(user):
    """This calendar month's (UTC) AI spend against the user's cap."""
    month = AiCall.objects.filter(user=user, created__gte=ai.month_start())
    usd = float(month.aggregate(usd=Sum("cost_usd"))["usd"] or 0)
    cap = None if user.cap_usd is None else float(user.cap_usd)
    return {"month": ai.month_start().strftime("%Y-%m"), "usd": round(usd, 6), "cap_usd": cap,
            "remaining_usd": None if cap is None else round(max(0.0, cap - usd), 6)}


@api_view(["GET"])
def me(request):
    """Who is signed in, plus this month's AI budget."""
    a = request.account
    return Response({"id": a.public_id, "name": a.name, "email": a.email, **budget(a)})


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
