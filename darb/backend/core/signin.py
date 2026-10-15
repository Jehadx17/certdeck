"""Google and Apple sign-in: ID tokens verified here (no Firebase), then a per-device Darb token.

A token is accepted only if its signature checks out against the provider's published keys (JWKS), its issuer is the
provider, its audience is one of our client ids, and it hasn't expired."""
import functools
import json
import logging
import time
import urllib.parse
import urllib.request
from datetime import date

import jwt
from django.conf import settings

from .auth import ApiError

log = logging.getLogger(__name__)

PROVIDERS = {
    "google": {"jwks": "https://www.googleapis.com/oauth2/v3/certs",
               "issuers": ["https://accounts.google.com", "accounts.google.com"], "setting": "DARB_GOOGLE_CLIENT_IDS"},
    "apple": {"jwks": "https://appleid.apple.com/auth/keys", "issuers": ["https://appleid.apple.com"],
              "setting": "DARB_APPLE_AUDIENCES"},
}


@functools.cache
def _jwks(provider):
    return jwt.PyJWKClient(PROVIDERS[provider]["jwks"], cache_jwk_set=True, lifespan=3600, timeout=10)


def verify(provider, id_token):
    """The verified claims of [id_token], or ApiError(401)."""
    p = PROVIDERS.get(provider)
    audiences = getattr(settings, p["setting"]) if p else []
    if not p or not audiences:
        raise ApiError(503, f"{provider} sign-in is not configured")
    if not isinstance(id_token, str) or len(id_token) > 8192:
        raise ApiError(400, "id_token required")
    try:
        key = _jwks(provider).get_signing_key_from_jwt(id_token).key
        claims = jwt.decode(id_token, key, algorithms=["RS256"], audience=audiences, issuer=p["issuers"],
                            options={"require": ["exp", "iat", "sub", "aud", "iss"]}, leeway=60)
    except jwt.PyJWKClientConnectionError as e:
        raise ApiError(503, "sign-in provider unreachable, try again") from e
    except jwt.PyJWTError as e:
        log.info("%s id token rejected: %s", provider, e)
        raise ApiError(401, "sign-in failed, try again") from e
    if provider == "google" and claims.get("email") and not claims.get("email_verified", False):
        raise ApiError(401, "verify your Google email first")
    return claims


# ---------- age gate ----------

def age_bounds(birth_year, today=None):
    """(lowest, highest) possible age from a birth year alone (Darb asks for the year only: minimum data)."""
    y = (today or date.today()).year
    return y - birth_year - 1, y - birth_year


def check_birth_year(value):
    """A plausible birth year, and old enough for Darb (12+). Returns it, or raises ApiError."""
    try:
        by = int(value)
    except (TypeError, ValueError):
        raise ApiError(400, "birth_year required", code="birth_year")
    lo, hi = age_bounds(by)
    if hi > 100 or lo < -1:
        raise ApiError(400, "birth_year required", code="birth_year")
    if hi < settings.DARB_MIN_AGE:
        raise ApiError(403, "Darb is for students aged 12 and over.", code="too_young")
    return by


def is_minor(account):
    """Possibly under 18 (Saudi majority): a guardian's consent is needed (docs/DARB-PDPL.md)."""
    return account.birth_year is not None and age_bounds(account.birth_year)[0] < 18


def needs_guardian(account):
    return settings.DARB_GUARDIAN_CONSENT and is_minor(account) and account.guardian_ok_at is None


# ---------- Sign in with Apple: token revocation on account deletion (App Store guideline 5.1.1(v)) ----------

def _apple_client_secret():
    """The ES256 client secret Apple's REST API wants, from the Sign in with Apple key (.p8)."""
    now = int(time.time())
    return jwt.encode({"iss": settings.DARB_APPLE_TEAM_ID, "iat": now, "exp": now + 300, "aud": "https://appleid.apple.com",
                       "sub": settings.DARB_APPLE_BUNDLE_ID}, settings.DARB_APPLE_KEY,
                      algorithm="ES256", headers={"kid": settings.DARB_APPLE_KEY_ID})


def _apple_post(path, fields):
    data = urllib.parse.urlencode({"client_id": settings.DARB_APPLE_BUNDLE_ID, "client_secret": _apple_client_secret(),
                                   **fields}).encode()
    req = urllib.request.Request(f"https://appleid.apple.com{path}", data=data, method="POST",
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=15) as r:
        body = r.read()
    return json.loads(body) if body else {}


def apple_refresh_token(authorization_code):
    """Exchanges the sign-in authorization code for a refresh token (kept only to revoke it later); None when the
    Apple key isn't configured or the exchange fails (sign-in still succeeds)."""
    if not (settings.DARB_APPLE_KEY and authorization_code):
        return None
    try:
        return _apple_post("/auth/token", {"code": authorization_code, "grant_type": "authorization_code"}).get("refresh_token")
    except Exception as e:  # noqa: BLE001 - a failed exchange must not block sign-in
        log.warning("apple code exchange failed: %s", e)
        return None


def apple_revoke(refresh_token):
    if settings.DARB_APPLE_KEY and refresh_token:
        try:
            _apple_post("/auth/revoke", {"token": refresh_token, "token_type_hint": "refresh_token"})
        except Exception as e:  # noqa: BLE001 - deletion goes ahead; logged for a manual revoke
            log.warning("apple revoke failed: %s", e)
