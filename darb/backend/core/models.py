import hashlib
from decimal import Decimal
import secrets
import time
from datetime import datetime, timezone

from django.db import connection, models, transaction


def now_ms():
    return int(time.time() * 1000)


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def new_public_id():
    return secrets.token_urlsafe(12)


class Account(models.Model):
    """A student. Signs in with Google or Apple only; each phone gets its own token (Device)."""

    public_id = models.CharField(max_length=24, unique=True, default=new_public_id)  # shown outside (RevenueCat id)
    name = models.CharField(max_length=120, blank=True)
    email = models.EmailField(blank=True, db_index=True)  # from the provider; may be an Apple relay address
    google_sub = models.CharField(max_length=255, unique=True, null=True, blank=True)
    apple_sub = models.CharField(max_length=255, unique=True, null=True, blank=True)
    birth_year = models.SmallIntegerField(null=True, blank=True)  # the age gate asks for the year only
    guardian_email = models.EmailField(blank=True)  # under 18: who confirms (docs/DARB-PDPL.md)
    guardian_token_hash = models.CharField(max_length=64, blank=True, db_index=True)
    guardian_ok_at = models.DateTimeField(null=True, blank=True)
    guardian_weekly = models.BooleanField(default=False)  # the guardian asked for a weekly study summary
    apple_refresh_token = models.TextField(blank=True)  # only to revoke it when the account is deleted
    seq = models.BigIntegerField(default=0)  # last sync seq given to this account's writes (per-user cursor)
    premium_until = models.DateTimeField(null=True, blank=True)  # set from RevenueCat by the backend only
    cap_usd = models.DecimalField(max_digits=8, decimal_places=2, null=True, blank=True)  # null = the tier's cap
    quota_reset_at = models.DateTimeField(null=True, blank=True)  # admin "reset quota": spend counts from here
    active = models.BooleanField(default=True)
    suspended = models.CharField(max_length=200, blank=True)  # why, when the anomaly rules or I suspended it
    created = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.email or self.public_id


class Device(models.Model):
    """One signed-in phone: its own bearer token (only the hash is stored)."""

    account = models.ForeignKey(Account, on_delete=models.CASCADE, related_name="devices")
    token_hash = models.CharField(max_length=64, unique=True)
    platform = models.CharField(max_length=16, blank=True)
    created = models.DateTimeField(auto_now_add=True)
    last_seen = models.DateTimeField(null=True, blank=True)

    @classmethod
    def issue(cls, account, platform=""):
        """A new device for [account]; returns (device, token). The token is shown once."""
        token = secrets.token_urlsafe(32)
        return cls.objects.create(account=account, token_hash=token_hash(token), platform=platform[:16]), token


class Doc(models.Model):
    """One sync document. Ids are unique per user (`settings` and other fixed ids repeat across users)."""

    user = models.ForeignKey(Account, on_delete=models.CASCADE, related_name="docs")
    doc_id = models.CharField(max_length=64)
    kind = models.CharField(max_length=32)
    data = models.JSONField()
    updated_at = models.BigIntegerField()
    deleted = models.BooleanField(default=False)
    seq = models.BigIntegerField()

    class Meta:
        constraints = [models.UniqueConstraint(fields=["user", "doc_id"], name="doc_user_doc_id")]
        indexes = [models.Index(fields=["user", "seq"], name="doc_user_seq"),
                   models.Index(fields=["user", "kind"], name="doc_user_kind")]

    def as_json(self):
        return {"id": self.doc_id, "kind": self.kind, "data": self.data, "updated_at": self.updated_at,
                "deleted": self.deleted}


class AiCall(models.Model):
    user = models.ForeignKey(Account, null=True, on_delete=models.SET_NULL)
    endpoint = models.CharField(max_length=32)
    model = models.CharField(max_length=64)
    input_tokens = models.IntegerField(default=0)
    output_tokens = models.IntegerField(default=0)
    cache_read_tokens = models.IntegerField(default=0)
    cache_creation_tokens = models.IntegerField(default=0)
    duration_ms = models.IntegerField(default=0)
    cost_usd = models.DecimalField(max_digits=10, decimal_places=6, default=0)
    batch = models.BooleanField(default=False)
    ok = models.BooleanField(default=False)
    error = models.TextField(blank=True)
    created = models.DateTimeField(auto_now_add=True)

    class Meta:
        indexes = [models.Index(fields=["user", "created"], name="aicall_user_created")]


class Config(models.Model):
    """What I change from the admin without an app update (one row)."""

    free_cap_usd = models.DecimalField(max_digits=6, decimal_places=3, default=Decimal("0.03"))
    paid_cap_usd = models.DecimalField(max_digits=6, decimal_places=3, default=Decimal("0.50"))
    free_daily_ai = models.IntegerField(default=10)  # AI calls per day
    paid_daily_ai = models.IntegerField(default=200)
    daily_spend_alert_usd = models.DecimalField(max_digits=8, decimal_places=2, default=Decimal("20"))

    class Meta:
        verbose_name = verbose_name_plural = "config"

    @classmethod
    def get(cls):
        return cls.objects.get_or_create(pk=1)[0]


class AiCache(models.Model):
    """An AI answer every student can reuse (same feature, same card content, same language, same prompt version)."""

    key = models.CharField(max_length=64, unique=True)
    value = models.JSONField()
    hits = models.IntegerField(default=0)
    created = models.DateTimeField(auto_now_add=True)


def docs(user):
    """Every Doc query goes through here: a user only ever sees their own documents."""
    return Doc.objects.filter(user=user)


def _reserve(user, n):
    """Reserves n sync seqs for [user] and returns the first. Must run inside the writer's transaction: the row lock on
    the account serializes this user's writers (only theirs), so their seqs commit in order and a pull with a cursor
    never skips one."""
    with connection.cursor() as c:
        c.execute("UPDATE core_account SET seq = seq + %s WHERE id = %s RETURNING seq", [n, user.pk])
        return c.fetchone()[0] - n + 1


def save_docs(user, items, reviews=()):
    """The only writer of Doc rows (and, with [reviews], of review rows). Upserts {id, kind, data, updated_at,
    deleted} dicts for one user with last-write-wins (incoming.updated_at >= stored.updated_at), each accepted write
    getting the user's next seq. Returns the number of accepted docs."""
    if not items and not reviews:
        return 0
    with transaction.atomic():
        stored = dict(docs(user).filter(doc_id__in={d["id"] for d in items}).values_list("doc_id", "updated_at"))
        winners = {}
        for d in items:
            prev = winners.get(d["id"])
            floor = prev["updated_at"] if prev else stored.get(d["id"])
            if floor is None or d["updated_at"] >= floor:
                winners[d["id"]] = d
        seq = _reserve(user, len(winners) + len(reviews))
        rows = []
        for i, d in enumerate(winners.values()):
            rows.append(Doc(user=user, doc_id=d["id"], kind=d["kind"], data=d["data"], updated_at=d["updated_at"],
                            deleted=bool(d.get("deleted", False)), seq=seq + i))
        Doc.objects.bulk_create(rows, update_conflicts=True, unique_fields=["user", "doc_id"],
                                update_fields=["kind", "data", "updated_at", "deleted", "seq"])
        if reviews:
            _insert_reviews(user, reviews, seq + len(rows))
    return len(rows)


# ---------- review log: compact rows in a table partitioned by month (created by migration 0001) ----------
# A review is {ts, card_id, rating 1-4, correct, confidence, misconception, study_first, duration_ms, source, score,
# error_type}. The booleans and small enums are packed into `flags`; the free-text answer stays on the phone.

CONFIDENCE = (None, "guess", "unsure", "sure")
SOURCES = ("study", "exam", "cram", "other")
REVIEW_MAX_AGE_MS = 400 * 86_400_000  # older (or future) timestamps are a broken clock: rejected


def pack_flags(r):
    conf = CONFIDENCE.index(r.get("confidence")) if r.get("confidence") in CONFIDENCE else 0
    src = SOURCES.index(r.get("source")) if r.get("source") in SOURCES else 3
    return (bool(r.get("correct")) | bool(r.get("misconception")) << 1 | bool(r.get("study_first")) << 2
            | conf << 3 | src << 5)


def unpack_flags(f):
    return {"correct": bool(f & 1), "misconception": bool(f & 2), "study_first": bool(f & 4),
            "confidence": CONFIDENCE[(f >> 3) & 3], "source": SOURCES[(f >> 5) & 3]}


def _insert_reviews(user, reviews, first_seq):
    rows = [(user.pk, first_seq + i, r["ts"], r["card_id"], r["rating"], pack_flags(r), r.get("duration_ms") or 0,
             r.get("score"), r.get("error_type")) for i, r in enumerate(reviews)]
    with connection.cursor() as c:
        c.executemany("INSERT INTO core_review (account_id, seq, ts, card, rating, flags, duration_ms, score, error_type)"
                      " VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING", rows)


REVIEW_COLS = "seq, ts, card, rating, flags, duration_ms, score, error_type"


def review_json(row):
    seq, ts, card, rating, flags, duration_ms, score, error_type = row
    return {"ts": ts, "card_id": card, "rating": rating, **unpack_flags(flags), "duration_ms": duration_ms,
            "score": score, "error_type": error_type}


def reviews_after(user, cursor, limit):
    """[(seq, review dict)] of this user's reviews with seq > cursor, oldest first."""
    with connection.cursor() as c:
        c.execute(f"SELECT {REVIEW_COLS} FROM core_review WHERE account_id = %s AND seq > %s ORDER BY seq LIMIT %s",
                  [user.pk, cursor, limit])
        return [(row[0], review_json(row)) for row in c.fetchall()]


def all_reviews(user):
    """Every review of [user] as dicts, by time (stats, the FSRS optimizer)."""
    with connection.cursor() as c:
        c.execute(f"SELECT {REVIEW_COLS} FROM core_review WHERE account_id = %s ORDER BY ts", [user.pk])
        return [review_json(row) for row in c.fetchall()]


def _month(ms):
    d = datetime.fromtimestamp(ms / 1000, timezone.utc)
    return d.year, d.month


def ensure_review_partitions(now=None, back=14, ahead=2):
    """Creates the monthly partitions from [back] months ago to [ahead] months ahead (idempotent; the worker runs it
    daily). Returns how many it created."""
    y, m = _month(now or now_ms())
    made = 0
    with connection.cursor() as c:
        for k in range(-back, ahead + 1):
            yy, mm = divmod((y * 12 + m - 1) + k, 12)
            start = int(datetime(yy, mm + 1, 1, tzinfo=timezone.utc).timestamp() * 1000)
            ny, nm = divmod(yy * 12 + mm + 1, 12)
            end = int(datetime(ny, nm + 1, 1, tzinfo=timezone.utc).timestamp() * 1000)
            name = f"core_review_{yy}{mm + 1:02d}"
            c.execute("SELECT to_regclass(%s)", [name])
            if c.fetchone()[0] is None:
                c.execute(f"CREATE TABLE {name} PARTITION OF core_review FOR VALUES FROM ({start}) TO ({end})")
                made += 1
    return made


class Job(models.Model):
    """A queued piece of slow work (core.jobs): one pending row per (kind, account, ref)."""

    kind = models.CharField(max_length=32)
    account = models.ForeignKey(Account, on_delete=models.CASCADE)
    ref = models.CharField(max_length=64, blank=True)
    run_at = models.DateTimeField(db_index=True)
    attempts = models.SmallIntegerField(default=0)
    running = models.BooleanField(default=False)
    again = models.BooleanField(default=False)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["kind", "account", "ref"], name="job_kind_account_ref")]
