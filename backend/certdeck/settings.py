import os
from pathlib import Path

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

SECRET_KEY = env("DJANGO_SECRET_KEY", "dev-only-insecure-key")  # nothing is signed (no sessions/users)
DEBUG = env("DJANGO_DEBUG", "false").lower() in ("1", "true", "yes")
ALLOWED_HOSTS = [h.strip() for h in env("DJANGO_ALLOWED_HOSTS", "localhost,127.0.0.1").split(",") if h.strip()]

CERTDECK_API_TOKEN = env("CERTDECK_API_TOKEN", "")
ANTHROPIC_API_KEY = env("ANTHROPIC_API_KEY", "")
CERTDECK_MODEL = env("CERTDECK_MODEL", "claude-opus-5-5")
# Background diagrams for cards (Batch API, about $0.005 per card checked); "false" turns them off.
CERTDECK_AUTO_DIAGRAMS = env("CERTDECK_AUTO_DIAGRAMS", "true").lower() in ("1", "true", "yes")
CERTDECK_MEDIA_DIR = Path(env("CERTDECK_MEDIA_DIR") or BASE_DIR / "media")
CARDS_SCHEMA_PATH = BASE_DIR.parent / "docs" / "cards.schema.json"

INSTALLED_APPS = ["core"]
MIDDLEWARE = ["django.middleware.security.SecurityMiddleware"]
ROOT_URLCONF = "certdeck.urls"
WSGI_APPLICATION = "certdeck.wsgi.application"
APPEND_SLASH = False

if env("POSTGRES_DB"):
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.postgresql",
            "NAME": env("POSTGRES_DB"),
            "USER": env("POSTGRES_USER", ""),
            "PASSWORD": env("POSTGRES_PASSWORD", ""),
            "HOST": env("POSTGRES_HOST", "127.0.0.1"),
            "PORT": env("POSTGRES_PORT", "5432"),
        }
    }
else:
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.sqlite3",
            "NAME": env("SQLITE_PATH") or BASE_DIR / "db.sqlite3",
            "OPTIONS": {"transaction_mode": "IMMEDIATE"},  # serialize writers like select_for_update does on Postgres
        }
    }

REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [],
    "DEFAULT_PERMISSION_CLASSES": ["core.auth.BearerToken"],
    "UNAUTHENTICATED_USER": None,
    "DEFAULT_RENDERER_CLASSES": ["rest_framework.renderers.JSONRenderer"],
    "DEFAULT_PARSER_CLASSES": ["rest_framework.parsers.JSONParser"],
    "EXCEPTION_HANDLER": "core.views.exception_handler",
}

SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
DATA_UPLOAD_MAX_MEMORY_SIZE = 64 * 1024 * 1024

USE_TZ = True
TIME_ZONE = "UTC"
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "handlers": {"console": {"class": "logging.StreamHandler"}},
    "root": {"handlers": ["console"], "level": "INFO"},
}
