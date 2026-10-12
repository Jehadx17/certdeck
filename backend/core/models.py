import time

from django.db import models, transaction


def now_ms():
    return int(time.time() * 1000)


class Counter(models.Model):
    """Single row (pk=1, created by the initial migration) holding the last global seq."""

    value = models.BigIntegerField(default=0)


class Doc(models.Model):
    id = models.CharField(primary_key=True, max_length=64)
    kind = models.CharField(max_length=32, db_index=True)
    data = models.JSONField()
    updated_at = models.BigIntegerField()
    deleted = models.BooleanField(default=False)
    seq = models.BigIntegerField(unique=True)

    def as_json(self):
        return {"id": self.id, "kind": self.kind, "data": self.data, "updated_at": self.updated_at, "deleted": self.deleted}


class AiCall(models.Model):
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


def save_docs(docs):
    """The only writer of Doc rows. Upserts {id, kind, data, updated_at, deleted} dicts with
    last-write-wins (incoming.updated_at >= stored.updated_at) and gives each accepted write a new
    global seq. Locking the counter row serializes writers, so seqs commit in order and a pull
    with a cursor never skips one. Returns the number of accepted docs."""
    if not docs:
        return 0
    with transaction.atomic():
        counter = Counter.objects.select_for_update().get(pk=1)
        stored = dict(Doc.objects.filter(id__in={d["id"] for d in docs}).values_list("id", "updated_at"))
        winners = {}
        for d in docs:
            prev = winners.get(d["id"])
            floor = prev["updated_at"] if prev else stored.get(d["id"])
            if floor is None or d["updated_at"] >= floor:
                winners[d["id"]] = d
        rows = []
        for d in winners.values():
            counter.value += 1
            rows.append(Doc(id=d["id"], kind=d["kind"], data=d["data"], updated_at=d["updated_at"],
                            deleted=bool(d.get("deleted", False)), seq=counter.value))
        Doc.objects.bulk_create(rows, update_conflicts=True, unique_fields=["id"],
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


def known_certs():
    """{code: cert data}: built-in defaults overridden by synced cert docs."""
    certs = dict(DEFAULT_CERTS)
    for doc in Doc.objects.filter(kind="cert", deleted=False):
        if isinstance(doc.data, dict) and doc.data.get("domains"):
            certs[doc.data.get("code") or doc.id] = doc.data
    return certs


def domain_ids(cert):
    return {str(d["id"]) for d in cert.get("domains", [])}
