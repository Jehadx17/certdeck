"""Sign-in (Google / Apple), the guardian's consent for under-18s, signing out, deleting the account, and billing
endpoints. docs/DARB-PROTOCOL.md → Accounts."""
import hashlib
import html
import logging
import secrets

from django.conf import settings
from django.core.exceptions import ValidationError
from django.core import signing
from django.core.mail import send_mail
from django.core.validators import validate_email
from django.http import HttpResponse, JsonResponse
from django.utils.timezone import now as tz_now
from django.views.decorators.csrf import csrf_exempt
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response

from . import billing, ingest, jobs, limits, signin
from .auth import ApiError
from .models import Account, Device

log = logging.getLogger(__name__)


def account_json(a):
    return {"id": a.public_id, "name": a.name, "email": a.email, "birth_year": a.birth_year,
            "premium": billing.is_premium(a), "premium_until": a.premium_until.isoformat() if a.premium_until else None,
            "guardian": ("pending" if signin.needs_guardian(a) else "ok" if signin.is_minor(a) else "not_needed"),
            "guardian_email": a.guardian_email}


def _body(request):
    if not isinstance(request.data, dict):
        raise ApiError(400, "JSON object expected")
    return request.data


@api_view(["POST"])
@permission_classes([AllowAny])
def sign_in(request, provider):
    """POST auth/google | auth/apple {id_token, platform, birth_year (new accounts), name?, authorization_code?}."""
    if provider not in signin.PROVIDERS:
        raise ApiError(404, "not found")
    body = _body(request)
    limits.hit("signin_ip", limits.client_ip(request))
    claims = signin.verify(provider, body.get("id_token"))
    field = f"{provider}_sub"
    account = Account.objects.filter(**{field: claims["sub"]}).first()
    new = account is None
    if new:
        birth_year = signin.check_birth_year(body.get("birth_year"))
        limits.hit("signup_ip", limits.client_ip(request))
        name = str(body.get("name") or claims.get("name") or "").strip()[:120]  # Apple sends the name to the app once
        account = Account.objects.create(**{field: claims["sub"]}, email=(claims.get("email") or "")[:254], name=name,
                                         birth_year=birth_year)
        log.info("new account %s via %s (minor=%s)", account.public_id, provider, signin.is_minor(account))
    if not account.active:
        raise ApiError(403, f"This account is paused. If you think this is a mistake, write to {settings.DARB_SUPPORT_EMAIL} "
                            "and we will check it.", code="suspended")
    if provider == "apple" and (rt := signin.apple_refresh_token(body.get("authorization_code"))):
        Account.objects.filter(pk=account.pk).update(apple_refresh_token=rt)
    _, token = Device.issue(account, str(body.get("platform") or ""))
    return Response({"token": token, "account": account_json(account), "new": new})


@api_view(["POST"])
def sign_out(request):
    request.device.delete()
    return Response({"ok": True})


@api_view(["GET", "DELETE"])
def account(request):
    """GET: the account. DELETE: the account and everything in it, now (App Store 5.1.1(v), Play account deletion)."""
    a = request.account
    if request.method == "GET":
        return Response(account_json(a))
    delete_account(a)
    return Response({"deleted": True})


def delete_account(a):
    ingest.delete_account_files(a)
    signin.apple_revoke(a.apple_refresh_token)
    billing.forget(a)
    log.info("account %s deleted", a.public_id)
    a.delete()  # cascades: devices, docs, reviews, jobs; AI call rows keep only the cost (user set to null)


# ---------- guardian consent (docs/DARB-PDPL.md) ----------

def _consent_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


@api_view(["POST"])
def guardian(request):
    """POST account/guardian {email}: a minor names their guardian; the guardian gets a link to confirm."""
    a = request.account
    if not signin.is_minor(a):
        raise ApiError(400, "not needed")
    email = str(_body(request).get("email") or "").strip().lower()
    try:
        validate_email(email)
    except ValidationError:
        raise ApiError(400, "Enter your guardian's email address.", code="email")
    if email == (a.email or "").lower():
        raise ApiError(400, "Use your guardian's email, not yours.", code="email")
    limits.hit("guardian_account", a.pk)
    token = secrets.token_urlsafe(32)
    Account.objects.filter(pk=a.pk).update(guardian_email=email, guardian_token_hash=_consent_hash(token))
    link = f"https://{settings.DARB_DOMAIN}/consent/{token}"
    send_mail(
        "درب: طلب موافقة ولي الأمر / Darb: guardian consent",
        f"{a.name or a.email} يريد استخدام تطبيق درب للدراسة. للاطلاع والموافقة: {link}\n\n"
        f"{a.name or a.email} wants to use the Darb study app. Read what Darb does and confirm here: {link}\n\n"
        f"If you don't know this student, ignore this email. Questions: {settings.DARB_SUPPORT_EMAIL}",
        None, [email])
    return Response(account_json(Account.objects.get(pk=a.pk)))


PAGE = """<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>درب | Darb</title>
<style>body{{font-family:system-ui,sans-serif;max-width:640px;margin:24px auto;padding:0 16px;line-height:1.6;
color:#14201f;background:#f6faf9}}@media(prefers-color-scheme:dark){{body{{color:#e6efed;background:#101615}}}}
button{{font-size:1rem;padding:12px 20px;margin:8px 4px;border-radius:10px;border:0;cursor:pointer}}
.ok{{background:#0f766e;color:#fff}}.no{{background:#ccc}}.en{{direction:ltr;text-align:left;opacity:.85}}</style>
</head><body>{body}</body></html>"""


def _page(body, status=200):
    return HttpResponse(PAGE.format(body=body), status=status)


@csrf_exempt  # the unguessable token in the URL is the credential; there are no cookies to forge
def consent_page(request, token):
    """GET/POST /consent/<token>: the guardian reads what Darb does and confirms (or declines, which deletes the
    account; a later visit can withdraw consent the same way)."""
    a = Account.objects.filter(guardian_token_hash=_consent_hash(token)).first() if token else None
    if not a:
        return _page("<h2>الرابط غير صالح أو منتهي.</h2><p class=en>This link is not valid any more.</p>", 404)
    who = html.escape(a.name or a.email or "")
    privacy = f"https://{settings.DARB_DOMAIN}/privacy"
    if request.method == "POST":
        action = request.POST.get("action")
        if action == "confirm":
            Account.objects.filter(pk=a.pk).update(guardian_ok_at=tz_now(),
                                                   guardian_weekly=request.POST.get("weekly") == "on")
            log.info("guardian confirmed for %s", a.public_id)
            if request.POST.get("weekly") == "on":
                jobs.enqueue("guardian_weekly", a, delay=WEEK)
            return _page(f"<h2>شكرًا، تمت الموافقة.</h2><p>يمكن لـ {who} الآن استخدام درب.</p>"
                         f"<p class=en>Thank you. {who} can now use Darb. Keep this email: the same link withdraws "
                         "consent at any time.</p>")
        if action in ("decline", "withdraw"):
            delete_account(a)
            return _page("<h2>تم حذف الحساب وكل بياناته.</h2><p class=en>The account and all its data were deleted.</p>")
        return _page("<h2>طلب غير صالح</h2>", 400)
    if a.guardian_ok_at:
        form = ("<p>وافقت على استخدام {who} لدرب. لسحب الموافقة وحذف الحساب:</p>"
                "<p class=en>You consented. To withdraw consent and delete the account:</p>"
                "<form method=post><button class=no name=action value=withdraw>سحب الموافقة وحذف الحساب / Withdraw and delete</button></form>")
    else:
        form = ("<form method=post><label><input type=checkbox name=weekly> أرسلوا لي ملخصًا أسبوعيًا عن دراسته "
                "/ send me a weekly study summary</label><br>"
                "<button class=ok name=action value=confirm>أوافق / I agree</button>"
                "<button class=no name=action value=decline>لا أوافق (يُحذف الحساب) / I don't agree (deletes the account)</button></form>")
    return _page(f"""<h2>موافقة ولي الأمر على تطبيق درب</h2>
<p>{who} يريد استخدام <b>درب</b>، تطبيق للمذاكرة (قدرات، تحصيلي، مواد المدرسة). نحفظ الحد الأدنى: الاسم والبريد من
حساب Google أو Apple، سنة الميلاد، وسجل المذاكرة. لا إعلانات ولا تتبع. شرح الأسئلة بالذكاء الاصطناعي يرسل نص السؤال
وإجابة الطالب إلى Anthropic دون الاسم أو البريد. البيانات محفوظة في ألمانيا. التفاصيل في <a href="{privacy}">سياسة الخصوصية</a>.</p>
<p class=en>{who} wants to use <b>Darb</b>, a study app (Qudurat, Tahsili, school subjects). We keep the minimum: name and
email from their Google or Apple account, birth year, and their study history. No ads, no tracking. AI explanations send
the question text and the student's answer to Anthropic, never their name or email. Data is stored in Germany.
Details: <a href="{privacy}">privacy policy</a>.</p>
{form.format(who=who)}""")


# ---------- billing ----------

@csrf_exempt
def revenuecat_webhook(request):
    if request.method != "POST":
        return JsonResponse({"error": "POST only"}, status=405)
    status, body = billing.webhook(request)
    return JsonResponse(body, status=status)


@api_view(["POST"])
def billing_refresh(request):
    """The app just bought or restored: re-read the entitlement from RevenueCat now instead of waiting for the webhook."""
    billing.refresh(request.account)
    return Response(account_json(request.account))


# ---------- the guardian's weekly summary (asked for on the consent page) ----------

WEEK = 7 * 86400


def weekly_stats(a, days=7):
    """Days studied (Riyadh dates), questions answered and how many were right in the last [days] days."""
    from django.db import connection
    with connection.cursor() as c:
        c.execute("""SELECT count(DISTINCT (to_timestamp(ts / 1000.0) AT TIME ZONE 'Asia/Riyadh')::date), count(*),
                            count(*) FILTER (WHERE flags & 1 = 1)
                     FROM core_review WHERE account_id = %s AND ts >= (extract(epoch FROM now()) - %s) * 1000""",
                  [a.pk, days * 86400])
        return c.fetchone()


def send_weekly(a):
    studied, answered, right = weekly_stats(a)
    pct = round(100 * right / answered) if answered else 0
    who = a.name or a.email
    stop = f"https://{settings.DARB_DOMAIN}/weekly-off/{signing.dumps(a.public_id, salt='weekly-off')}"
    send_mail(
        f"درب: ملخص الأسبوع لـ {who} / Darb: {who}'s week",
        f"ذاكر {who} في {studied} من آخر ٧ أيام، وأجاب عن {answered} سؤالًا، صحيح منها {pct}٪.\n"
        f"لإيقاف هذه الرسالة: {stop}\n\n"
        f"{who} studied on {studied} of the last 7 days and answered {answered} questions, {pct}% right.\n"
        f"To stop these emails: {stop}\nQuestions: {settings.DARB_SUPPORT_EMAIL}",
        None, [a.guardian_email])


@csrf_exempt
def weekly_off(request, token):
    """GET /weekly-off/<signed id>: one click stops the weekly summary (the link is signed, never guessable)."""
    try:
        public_id = signing.loads(token, salt="weekly-off")
    except signing.BadSignature:
        return _page("<h2>الرابط غير صالح.</h2><p class=en>This link is not valid.</p>", 404)
    Account.objects.filter(public_id=public_id).update(guardian_weekly=False)
    return _page("<h2>تم إيقاف الملخص الأسبوعي.</h2><p class=en>The weekly summary is off.</p>")
