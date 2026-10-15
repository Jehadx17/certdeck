import os
from pathlib import Path
from urllib.parse import parse_qsl, unquote, urlsplit

BASE_DIR = Path(__file__).resolve().parent.parent

# Load backend/.env if present; real environment variables win.
_env_file = BASE_DIR / ".env"
if _env_file.exists():
    for _line in _env_file.read_text().splitlines():
        _line = _line.strip()
        if _line and not _line.startswith("#") and "=" in _line:
            _k, _v = _line.split("=", 1)
            os.environ.setdefault(_k.strip(), _v.strip().strip("'\""))

env = os.environ.get


def _flag(name, default="false"):
    return env(name, default).lower() in ("1", "true", "yes")


def _list(name, default=""):
    return [x.strip() for x in env(name, default).split(",") if x.strip()]


DEBUG = _flag("DJANGO_DEBUG")
SECRET_KEY = env("DJANGO_SECRET_KEY") or ("dev-only-insecure-key" if DEBUG or env("DARB_TESTING") else "")
if not SECRET_KEY:
    raise RuntimeError("DJANGO_SECRET_KEY is required when DJANGO_DEBUG is off")
# The one domain value (README: may not be owned yet). API: https://<domain>/api/, packs: https://cdn.<domain>/.
DARB_DOMAIN = env("DARB_DOMAIN", "darbedu.sa")
ALLOWED_HOSTS = _list("DJANGO_ALLOWED_HOSTS", f"{DARB_DOMAIN},localhost,127.0.0.1")

ANTHROPIC_API_KEY = env("ANTHROPIC_API_KEY", "")
# Load tests only: AI answers come from a stub after this many ms (ignored whenever a real key is set).
DARB_AI_STUB_MS = int(env("DARB_AI_STUB_MS", "0"))
# Course uploads (PDF/photos) live on the worker server's disk: <dir>/<account id>/<material id>/
DARB_UPLOAD_DIR = Path(env("DARB_UPLOAD_DIR") or BASE_DIR / "uploads")

# Sign-in (docs/DARB-PROTOCOL.md → Accounts). Client ids are public; the Apple key (.p8) is a secret file.
DARB_GOOGLE_CLIENT_IDS = _list("DARB_GOOGLE_CLIENT_IDS")  # the server (web) client id + the iOS client id
DARB_APPLE_BUNDLE_ID = env("DARB_APPLE_BUNDLE_ID", "sa.darbedu.app")
DARB_APPLE_AUDIENCES = _list("DARB_APPLE_AUDIENCES", DARB_APPLE_BUNDLE_ID)
DARB_APPLE_TEAM_ID = env("DARB_APPLE_TEAM_ID", "")
DARB_APPLE_KEY_ID = env("DARB_APPLE_KEY_ID", "")
DARB_APPLE_KEY = Path(env("DARB_APPLE_KEY_FILE")).read_text() if env("DARB_APPLE_KEY_FILE") else ""
DARB_MIN_AGE = 12
DARB_GUARDIAN_CONSENT = _flag("DARB_GUARDIAN_CONSENT", "true")  # under-18s need a guardian's confirmation

# Billing: RevenueCat decides nothing by itself; its webhook and REST API feed account.premium_until.
DARB_REVENUECAT_WEBHOOK_AUTH = env("DARB_REVENUECAT_WEBHOOK_AUTH", "")
DARB_REVENUECAT_API_KEY = env("DARB_REVENUECAT_API_KEY", "")  # secret (v1) key, for GET/DELETE subscriber
DARB_ENTITLEMENT = "premium"

# Packs: built files are on the CDN (https://cdn.<domain>/packs/...); their keys are wrapped with this 32-byte key
# (base64). Generate: python -c "import base64,os; print(base64.b64encode(os.urandom(32)).decode())"
DARB_PACK_KEK = env("DARB_PACK_KEK", "")
DARB_CDN_URL = env("DARB_CDN_URL", f"https://cdn.{DARB_DOMAIN}")  # a local file server in development

# Email (guardian consent, deletion confirmations): any SMTP provider. Unset host = printed to the log (development).
EMAIL_HOST = env("EMAIL_HOST", "")
EMAIL_PORT = int(env("EMAIL_PORT", "587"))
EMAIL_HOST_USER = env("EMAIL_HOST_USER", "")
EMAIL_HOST_PASSWORD = env("EMAIL_HOST_PASSWORD", "")
EMAIL_USE_TLS = _flag("EMAIL_USE_TLS", "true")
EMAIL_BACKEND = ("django.core.mail.backends.smtp.EmailBackend" if EMAIL_HOST
                 else "django.core.mail.backends.console.EmailBackend")
DEFAULT_FROM_EMAIL = env("DEFAULT_FROM_EMAIL", f"Darb <no-reply@{DARB_DOMAIN}>")
DARB_SUPPORT_EMAIL = env("DARB_SUPPORT_EMAIL", f"support@{DARB_DOMAIN}")

# The admin (account lookup, entitlement, quota reset, AI spend, caps) is Django's own; everything else is the API.
INSTALLED_APPS = ["django.contrib.admin", "django.contrib.auth", "django.contrib.contenttypes", "django.contrib.sessions",
                  "django.contrib.messages", "django.contrib.staticfiles", "core"]
MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]
TEMPLATES = [{
    "BACKEND": "django.template.backends.django.DjangoTemplates", "APP_DIRS": True,
    "OPTIONS": {"context_processors": ["django.template.context_processors.request",
                                       "django.contrib.auth.context_processors.auth",
                                       "django.contrib.messages.context_processors.messages"]},
}]
STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR / "static"
# A path that isn't /admin/ (bots scan it). In production Cloudflare Access sits in front of it (docs/DARB-OPS.md).
DARB_ADMIN_PATH = env("DARB_ADMIN_PATH", "darb-admin/")
SESSION_COOKIE_SECURE = CSRF_COOKIE_SECURE = not DEBUG
CSRF_TRUSTED_ORIGINS = [f"https://{DARB_DOMAIN}"]
ROOT_URLCONF = "darb.urls"
WSGI_APPLICATION = "darb.wsgi.application"
APPEND_SLASH = False


def database(url):
    """postgres://user:pass@host:port/name?opt=v -> Django DATABASES entry. One setting, so the database can move
    (another VPS, a managed service) with only a dump/restore and a new URL."""
    u = urlsplit(url)
    if u.scheme not in ("postgres", "postgresql"):
        raise RuntimeError("DATABASE_URL must be postgres://user:password@host:port/name")
    return {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": unquote(u.path.lstrip("/")), "USER": unquote(u.username or ""), "PASSWORD": unquote(u.password or ""),
        "HOST": u.hostname or "", "PORT": str(u.port or 5432),
        # PgBouncer in transaction mode: no server-side cursors, no prepared statements, short-lived connections.
        "DISABLE_SERVER_SIDE_CURSORS": True, "CONN_MAX_AGE": int(env("DB_CONN_MAX_AGE", "0")),
        "OPTIONS": {"prepare_threshold": None, **dict(parse_qsl(u.query))},
    }


DATABASES = {"default": database(env("DATABASE_URL", "postgres://postgres@127.0.0.1:5432/darb"))}
if env("DATABASE_REPLICA_URL"):  # optional read replica for admin and reports (sync always reads the primary)
    DATABASES["replica"] = database(env("DATABASE_REPLICA_URL"))

REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [],
    "DEFAULT_PERMISSION_CLASSES": ["core.auth.BearerToken"],
    "UNAUTHENTICATED_USER": None,
    "DEFAULT_RENDERER_CLASSES": ["rest_framework.renderers.JSONRenderer"],
    "DEFAULT_PARSER_CLASSES": ["rest_framework.parsers.JSONParser"],
    "EXCEPTION_HANDLER": "core.views.exception_handler",
}

SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
DATA_UPLOAD_MAX_MEMORY_SIZE = 16 * 1024 * 1024

USE_TZ = True
TIME_ZONE = "UTC"
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "handlers": {"console": {"class": "logging.StreamHandler"}},
    "root": {"handlers": ["console"], "level": "INFO"},
}
