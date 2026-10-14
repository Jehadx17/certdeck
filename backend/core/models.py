import hashlib
import secrets
import time

from django.db import models, transaction


def now_ms():
    return int(time.time() * 1000)


LOGIN_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


class Account(models.Model):
    """A person with their own token and data. owner = me (certs + college); student = college only."""

    name = models.CharField(max_length=64, unique=True)
    role = models.CharField(max_length=16, default="student")
    token_hash = models.CharField(max_length=64, unique=True, null=True)  # sha256 hex of the bearer token
    cap_usd = models.DecimalField(max_digits=8, decimal_places=2, null=True, blank=True)  # monthly AI budget; null = none
    active = models.BooleanField(default=True)
    created = models.DateTimeField(auto_now_add=True)
    login_code_hash = models.CharField(max_length=64, null=True, blank=True)  # one-time sign-in code (sha256), see new_login_code
    login_code_expires = models.DateTimeField(null=True, blank=True)

    def new_token(self):
        """Sets and returns a fresh token (only its hash is stored)."""
        token = secrets.token_urlsafe(32)
        self.token_hash = token_hash(token)
        return token

    def new_login_code(self, hours=24):
        """Sets and returns a one-time sign-in code: 8 characters a child can type (no 0/O, 1/I/L), valid for [hours]."""
        from django.utils import timezone

        code = "".join(secrets.choice(LOGIN_CODE_ALPHABET) for _ in range(8))
        self.login_code_hash = token_hash(code)
        self.login_code_expires = timezone.now() + timezone.timedelta(hours=hours)
        return code

    def __str__(self):
        return self.name


class Counter(models.Model):
    """Single row (pk=1, created by the initial migration) holding the last global seq."""

    value = models.BigIntegerField(default=0)


class Doc(models.Model):
    """One sync document. Ids are unique per user (`settings`, cert codes and other fixed ids repeat across users)."""

    user = models.ForeignKey(Account, on_delete=models.CASCADE, related_name="docs")
    doc_id = models.CharField(max_length=64)
    kind = models.CharField(max_length=32, db_index=True)
    data = models.JSONField()
    updated_at = models.BigIntegerField()
    deleted = models.BooleanField(default=False)
    seq = models.BigIntegerField(unique=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["user", "doc_id"], name="doc_user_doc_id")]

    def as_json(self):
        return {"id": self.doc_id, "kind": self.kind, "data": self.data, "updated_at": self.updated_at,
                "deleted": self.deleted}


class Media(models.Model):
    """Who may read a content-addressed file. Files are stored once; access is per user."""

    user = models.ForeignKey(Account, on_delete=models.CASCADE)
    name = models.CharField(max_length=80)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["user", "name"], name="media_user_name")]


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


def docs(user):
    """Every Doc query goes through here: a user only ever sees their own documents."""
    return Doc.objects.filter(user=user)


def save_docs(user, items):
    """The only writer of Doc rows. Upserts {id, kind, data, updated_at, deleted} dicts for one user with
    last-write-wins (incoming.updated_at >= stored.updated_at) and gives each accepted write a new
    global seq. Locking the counter row serializes writers, so seqs commit in order and a pull
    with a cursor never skips one. Returns the number of accepted docs."""
    if not items:
        return 0
    with transaction.atomic():
        counter = Counter.objects.select_for_update().get(pk=1)
        stored = dict(docs(user).filter(doc_id__in={d["id"] for d in items}).values_list("doc_id", "updated_at"))
        winners = {}
        for d in items:
            prev = winners.get(d["id"])
            floor = prev["updated_at"] if prev else stored.get(d["id"])
            if floor is None or d["updated_at"] >= floor:
                winners[d["id"]] = d
        rows = []
        for d in winners.values():
            counter.value += 1
            rows.append(Doc(user=user, doc_id=d["id"], kind=d["kind"], data=d["data"], updated_at=d["updated_at"],
                            deleted=bool(d.get("deleted", False)), seq=counter.value))
        Doc.objects.bulk_create(rows, update_conflicts=True, unique_fields=["user", "doc_id"],
                                update_fields=["kind", "data", "updated_at", "deleted", "seq"])
        counter.save(update_fields=["value"])
    return len(rows)


def _cert(code, name, kind, domains):
    return {"code": code, "name": name, "exam": {"kind": kind},
            "domains": [{"id": str(i), "name": n, "weight": w} for i, (n, w) in enumerate(domains, 1)]}


# Used until the app syncs its own `cert` docs (which take precedence per code).
DEFAULT_CERTS = {c["code"]: c for c in [
    _cert("DVA-C02", "AWS Certified Developer - Associate", "mcq", [
        ("Development with AWS Services", 0.32), ("Security", 0.26), ("Deployment", 0.24),
        ("Troubleshooting and Optimization", 0.18)]),
    _cert("SAA-C03", "AWS Certified Solutions Architect - Associate", "mcq", [
        ("Design Secure Architectures", 0.30), ("Design Resilient Architectures", 0.26),
        ("Design High-Performing Architectures", 0.24), ("Design Cost-Optimized Architectures", 0.20)]),
    _cert("CKAD", "Certified Kubernetes Application Developer", "performance", [
        ("Application Design and Build", 0.20), ("Application Deployment", 0.20),
        ("Application Observability and Maintenance", 0.15),
        ("Application Environment, Configuration and Security", 0.25), ("Services and Networking", 0.20)]),
]}


def known_certs(user):
    """{code: cert data}: built-in defaults overridden by the user's synced cert docs."""
    certs = dict(DEFAULT_CERTS)
    for doc in docs(user).filter(kind="cert", deleted=False):
        if isinstance(doc.data, dict) and doc.data.get("domains"):
            certs[doc.data.get("code") or doc.doc_id] = doc.data
    return certs


def domain_ids(cert):
    return {str(d["id"]) for d in cert.get("domains", [])}
