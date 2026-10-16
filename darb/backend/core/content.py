"""Offline content pipeline (docs/DARB-PACKS.md). Opus/Sonnet run here only, never for students.

blueprint -> generate (Opus, Batch API: original items per topic) -> checks (shape, SymPy for computable answers,
near-duplicates) -> blind solve (Sonnet: an independent model answers without the key; disagreement = quarantine;
non-MCQ answers compared by Haiku) -> audit (Opus at high effort on a random sample: the measured error rate with a 95%
interval) -> build (encrypted file + sample, core.packs). Every step reads the database, so `manage.py packs run <slug>`
resumes after any interruption."""
import difflib
import json
import logging
import math
import random
import re
from pathlib import Path

from django.conf import settings
from django.db.models import Count

from . import ai, verify
from .ai import BOOL, INT, S, SL, _null, _obj
from .models import ContentBatch, Pack, PackItem

log = logging.getLogger(__name__)

GEN_MODEL, SOLVE_MODEL, AUDIT_MODEL, EQUIV_MODEL = "claude-opus-5-5", "claude-sonnet-5-5", "claude-opus-5-5", ai.MODEL
PER_REQUEST = 15  # items per generation request
SOLVE_PER_REQUEST = 10
AUDIT_SAMPLE = 60
MAX_ERROR_RATE = 0.02  # a pack ships only if the audited error rate is at most this (else it's listed for the owner)
BLUEPRINTS = Path(settings.BASE_DIR).parent / "content" / "blueprints"
DUP = 0.88

CHECK = _obj(kind={"type": "string", "enum": list(verify.KINDS)}, expr=S, value=S, var=_null(S))
ITEM = _obj(type={"type": "string", "enum": ["mcq", "basic"]}, question=S, options=_null(SL),
            correct=_null({"type": "array", "items": INT}), answer=_null(S), explanation=S, hint=S,
            difficulty=INT, skill=S, check=_null(CHECK))
GEN_SCHEMA = _obj(items={"type": "array", "items": ITEM})
SOLVE_SCHEMA = _obj(answers={"type": "array", "items": _obj(i=INT, choice=_null(INT), answer=_null(S), confidence=INT,
                                                            flawed=BOOL, reason=S)})
EQUIV_SCHEMA = _obj(same={"type": "array", "items": _obj(i=INT, same=BOOL)})
AUDIT_SCHEMA = _obj(results={"type": "array", "items": _obj(i=INT, error=BOOL, kind=S, note=S)})

GEN_PROMPT = """You write ORIGINAL practice items for Darb, a study app for Saudi students, following the official exam format and the Ministry of Education curriculum described below.
Rules:
- Every item is your own: never reproduce or closely paraphrase a real exam question, a textbook exercise, or any copyrighted text. Use the official format, style and difficulty only.
- Exactly one correct answer. mcq: 4 plausible options (no "all/none of the above"), correct = [index of the right option]. basic: answer = the short exact answer, options and correct null.
- explanation: why the right answer is right and why the tempting wrong ones are wrong, briefly, with the shortcut or rule a strong student uses. hint: one line that nudges toward the method without giving the answer away.
- difficulty 1 (easy) to 3 (hard), following the requested mix. skill: the sub-skill tested, a few words.
- check: whenever the answer is a computable number or expression, give a SymPy check whose value is exactly the correct answer (kind numeric: expr evaluates to value; equivalent: expr equals value; solutions: roots of expr == value). Otherwise null.
- Language: Modern Standard Arabic as Saudi textbooks write it (or English for the English subject). Correct, current, culturally appropriate for students aged 12-18. Use Western or Arabic-Indic digits consistently within an item.
- Never repeat an existing item (listed with the request)."""

SOLVE_PROMPT = """You are an independent expert checking practice items for Saudi students. Solve each item yourself, carefully, without assuming the item is correct.
For a multiple-choice item, return choice = the index of the single correct option. If no option is correct, more than one is, the question is ambiguous or broken, set flawed = true and explain in reason. For other items return your answer (short) in answer. confidence 1-5."""

EQUIV_PROMPT = """For each pair, decide whether the student's answer and the key mean the same thing (same value or same term; ignore formatting, digit style, units written differently)."""

AUDIT_PROMPT = """You are the final quality auditor of a question bank for Saudi students. Check each item thoroughly: is the answer key right, is the question correct, unambiguous and solvable, is the explanation correct, is the language correct, is it appropriate for students aged 12-18, and is it plausibly original (not a famous verbatim exam item)? error = true if any of these fails in a way a student would notice. kind: key | question | explanation | language | other | none."""

DIGITS = str.maketrans("٠١٢٣٤٥٦٧٨٩٫", "0123456789.")


def norm(text):
    return " ".join(re.sub(r"[^\w]+", " ", str(text).translate(DIGITS).lower()).split())


def blueprint(slug):
    return json.loads((BLUEPRINTS / f"{slug}.json").read_text())


def ensure_pack(bp):
    pack, _ = Pack.objects.update_or_create(slug=bp["slug"], defaults=dict(
        title_ar=bp["title_ar"], title_en=bp["title_en"], segments=bp.get("segments", []), exams=bp.get("exams", []),
        grades=bp.get("grades", []), subject=bp.get("subject", ""),
        topics=[{"id": t["id"], "title_ar": t["title_ar"], "title_en": t.get("title_en", ""), "weight": t.get("weight") or
                 t["count"] / max(1, sum(x["count"] for x in bp["topics"]))} for t in bp["topics"]],
        sources=[{"source": s["url"], "kind": "official blueprint (format and topics only)", "rights": "facts, no text copied",
                  "note": s.get("what", "")} for s in bp.get("sources", [])] + [{
                  "source": f"{GEN_MODEL} (original items)", "kind": "generated", "rights": "ours", "note": ""}]))
    return pack


def _offline(system, content, schema, model, max_tokens, effort):
    return {"model": model, "max_tokens": max_tokens, "system": [{"type": "text", "text": system,
                                                                  "cache_control": {"type": "ephemeral"}}],
            "messages": [{"role": "user", "content": content}],
            "output_config": {"effort": effort, "format": {"type": "json_schema", "schema": schema}}}


def _pending(pack, stage):
    return ContentBatch.objects.filter(pack=pack, stage=stage, status="submitted").exists()


def _submit(pack, stage, reqs):
    """reqs: [(custom id, params, ctx)] -> one batch (the Batch API halves every token)."""
    if not reqs:
        return 0
    batch = ai._batches().create(requests=[{"custom_id": cid, "params": p} for cid, p, _ in reqs])
    ContentBatch.objects.create(pack=pack, stage=stage, batch_id=batch.id, ctx={cid: ctx for cid, _, ctx in reqs})
    log.info("%s %s: batch %s with %d requests", pack.slug, stage, batch.id, len(reqs))
    return len(reqs)


# ---------- generate ----------

def generate_requests(pack, bp):
    have = dict(PackItem.objects.filter(pack=pack).exclude(status="rejected").values_list("data__topic").annotate(n=Count("id")))
    tries = {}  # generation requests already made per topic: a topic that can't fill up stops after 1.5x its share
    for ctx in ContentBatch.objects.filter(pack=pack, stage="generate").values_list("ctx", flat=True):
        for c in ctx.values():
            tries[c["topic"]] = tries.get(c["topic"], 0) + 1
    reqs = []
    for t in bp["topics"]:
        missing = t["count"] - (have.get(t["id"]) or 0)
        if tries.get(t["id"], 0) >= math.ceil(t["count"] / PER_REQUEST) * 1.5 + 1:
            continue
        stems = [norm(q)[:90] for q in PackItem.objects.filter(pack=pack, data__topic=t["id"]).values_list("data__question", flat=True)][-150:]
        head = (f"Pack: {bp['title_ar']} / {bp['title_en']}. Subject: {bp.get('subject')}. Official format: {bp.get('format')}.\n"
                f"Topic: {t['title_ar']} / {t.get('title_en', '')} (unit: {t.get('unit', '')}). Skills: {t.get('notes', '')}.\n"
                f"Allowed item types: {', '.join(t.get('item_types') or ['mcq'])}. Difficulty mix: 30% easy, 50% medium, 20% hard.")
        for k in range(0, max(0, missing), PER_REQUEST):
            n = min(PER_REQUEST, missing - k)
            text = (f"{head}\n\nExisting items of this topic (don't repeat):\n" + ("\n".join(f"- {s}" for s in stems) or "(none)")
                    + f"\n\nWrite {n} new items.")
            reqs.append((f"g-{t['id']}-{k}", _offline(GEN_PROMPT, text, GEN_SCHEMA, GEN_MODEL, 32000, "high"), {"topic": t["id"]}))
    return reqs


def _numbers(text):
    return [float(x) for x in re.findall(r"-?\d+(?:\.\d+)?", str(text).translate(DIGITS))]


def clean_item(raw, topic):
    """A generated item -> card data, or (None, reason)."""
    q, expl = (raw.get("question") or "").strip(), (raw.get("explanation") or "").strip()
    if not q or not expl or raw.get("type") not in ("mcq", "basic"):
        return None, "invalid"
    card = {"type": raw["type"], "question": q, "explanation": expl, "hint": (raw.get("hint") or "").strip(),
            "difficulty": max(1, min(3, int(raw.get("difficulty") or 2))), "skill": (raw.get("skill") or "").strip()[:60],
            "topic": topic}
    if raw["type"] == "mcq":
        opts, correct = raw.get("options") or [], raw.get("correct") or []
        if len(opts) != 4 or len(correct) != 1 or not 0 <= correct[0] < 4 or len({norm(o) for o in opts}) != 4:
            return None, "invalid"
        card.update(options=opts, correct=correct)
        key_text = opts[correct[0]]
    else:
        if not (raw.get("answer") or "").strip():
            return None, "invalid"
        card["answer"] = raw["answer"].strip()
        key_text = card["answer"]
    check = raw.get("check")
    if check:
        if not verify.check(check):
            return None, "check failed"
        want, key_nums = _numbers(check.get("value")), _numbers(key_text)
        if want and key_nums and not any(abs(w - k) < 1e-6 for w in want for k in key_nums):
            return None, "check does not match the key"
        card["check"], card["verified_math"] = check, True
    return card, None


def ingest_generated(pack, results, ctxs, source=f"ai:{GEN_MODEL}", status="draft"):
    seen = [norm(q) for q in PackItem.objects.filter(pack=pack).values_list("data__question", flat=True)]
    n = (PackItem.objects.filter(pack=pack).order_by("-n").values_list("n", flat=True).first() or 0)
    stats = {"added": 0, "invalid": 0, "duplicate": 0, "check failed": 0, "check does not match the key": 0}
    for cid, out in results.items():
        for raw in (out or {}).get("items", []) if isinstance(out, dict) else []:
            card, why = clean_item(raw, ctxs[cid]["topic"])
            if not card:
                stats[why] = stats.get(why, 0) + 1
                continue
            q = norm(card["question"])
            m = difflib.SequenceMatcher(None, "", q)
            if any(m.set_seq1(s) or (m.quick_ratio() >= DUP and m.ratio() >= DUP) for s in seen):
                stats["duplicate"] += 1
                continue
            seen.append(q)
            n += 1
            PackItem.objects.create(pack=pack, n=n, data=card, status=status, source=source)
            stats["added"] += 1
    return stats


def import_items(slug, path):
    """Items written offline (Claude Code, one JSON object per line, same shape as generated items plus "topic") ->
    the pack, through the same code checks and duplicate filter. They count as verified: the author's own blind solve
    replaces the API one (docs/DARB-PACKS.md)."""
    pack = ensure_pack(blueprint(slug))
    topics = {t["id"] for t in pack.topics}
    rows = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
    ok = {f"l{k}": r for k, r in enumerate(rows) if r.get("topic") in topics}
    stats = ingest_generated(pack, {c: {"items": [r]} for c, r in ok.items()}, {c: {"topic": r["topic"]} for c, r in ok.items()},
                             source=f"claude-code:{Path(path).name}"[:120], status="verified")
    stats["unknown topic"] = len(rows) - len(ok)
    return stats


# ---------- blind solve ----------

def _item_text(i, d, with_key=False):
    lines = [f"[{i}] {d['question']}"]
    lines += [f"  ({k}) {o}" for k, o in enumerate(d.get("options") or [])]
    if with_key:
        lines.append(f"  KEY: {d['options'][d['correct'][0]] if d['type'] == 'mcq' else d['answer']}")
        lines.append(f"  EXPLANATION: {d['explanation']}")
    return "\n".join(lines)


def solve_requests(pack):
    todo = list(PackItem.objects.filter(pack=pack, status="draft", checks__solve__isnull=True).order_by("n"))
    reqs = []
    for k in range(0, len(todo), SOLVE_PER_REQUEST):
        group = todo[k:k + SOLVE_PER_REQUEST]
        text = "Items:\n\n" + "\n\n".join(_item_text(it.n, it.data) for it in group)
        reqs.append((f"s-{group[0].n}", _offline(SOLVE_PROMPT, text, SOLVE_SCHEMA, SOLVE_MODEL, 32000, "high"),
                     {"ns": [it.n for it in group]}))
    return reqs


def ingest_solved(pack, results, ctxs):
    """MCQ: the solver must pick the keyed option. Other items: same text = verified, else they go to the
    equivalence check. Flawed or different = quarantined."""
    stats = {"verified": 0, "quarantined": 0, "to compare": 0}
    for cid, out in results.items():
        answers = {a["i"]: a for a in (out or {}).get("answers", [])} if isinstance(out, dict) else {}
        for it in PackItem.objects.filter(pack=pack, n__in=ctxs[cid]["ns"]):
            a = answers.get(it.n)
            checks = {**it.checks, "solve": a or {"missing": True}}
            if not a or a.get("flawed"):
                status = "quarantined"
            elif it.data["type"] == "mcq":
                status = "verified" if a.get("choice") == it.data["correct"][0] else "quarantined"
            elif norm(a.get("answer")) == norm(it.data["answer"]):
                status = "verified"
            else:
                status = "draft"  # the equivalence check decides
                checks["compare"] = True
                stats["to compare"] += 1
            if status != "draft":
                stats[status] += 1
            PackItem.objects.filter(pk=it.pk).update(status=status, checks=checks)
    return stats


def equiv_requests(pack):
    todo = list(PackItem.objects.filter(pack=pack, status="draft", checks__compare=True, checks__same__isnull=True))
    if not todo:
        return []
    text = "\n".join(f"[{it.n}] key: {it.data['answer']} | student: {it.checks['solve'].get('answer')}" for it in todo)
    return [("e-0", _offline(EQUIV_PROMPT, text, EQUIV_SCHEMA, EQUIV_MODEL, 8000, "low"), {"ns": [it.n for it in todo]})]


def ingest_equiv(pack, results, ctxs):
    stats = {"verified": 0, "quarantined": 0}
    for cid, out in results.items():
        same = {s["i"]: s["same"] for s in (out or {}).get("same", [])} if isinstance(out, dict) else {}
        for it in PackItem.objects.filter(pack=pack, n__in=ctxs[cid]["ns"]):
            status = "verified" if same.get(it.n) else "quarantined"
            stats[status] += 1
            PackItem.objects.filter(pk=it.pk).update(status=status, checks={**it.checks, "same": bool(same.get(it.n))})
    return stats


# ---------- audit ----------

def wilson(errors, n, z=1.96):
    """95% Wilson interval of an error rate."""
    if not n:
        return (0.0, 1.0)
    p = errors / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    r = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (max(0.0, (c - r) / d), min(1.0, (c + r) / d))


def audit_requests(pack, sample=AUDIT_SAMPLE, seed=None):
    verified = list(PackItem.objects.filter(pack=pack, status="verified", checks__audit__isnull=True))
    if PackItem.objects.filter(pack=pack, checks__audit__isnull=False).count() >= sample or not verified:
        return []
    picked = random.Random(seed).sample(verified, min(sample, len(verified)))
    reqs = []
    for k in range(0, len(picked), 10):
        group = picked[k:k + 10]
        text = "Items:\n\n" + "\n\n".join(_item_text(it.n, it.data, with_key=True) for it in group)
        reqs.append((f"a-{group[0].n}", _offline(AUDIT_PROMPT, text, AUDIT_SCHEMA, AUDIT_MODEL, 32000, "max"),
                     {"ns": [it.n for it in group]}))
    return reqs


def ingest_audit(pack, results, ctxs):
    for cid, out in results.items():
        res = {r["i"]: r for r in (out or {}).get("results", [])} if isinstance(out, dict) else {}
        for it in PackItem.objects.filter(pack=pack, n__in=ctxs[cid]["ns"]):
            r = res.get(it.n) or {"error": True, "kind": "other", "note": "no audit result"}
            PackItem.objects.filter(pk=it.pk).update(checks={**it.checks, "audit": r})
    audited = list(PackItem.objects.filter(pack=pack, checks__audit__isnull=False).values_list("checks__audit__error", flat=True))
    errors = sum(bool(e) for e in audited)
    lo, hi = wilson(errors, len(audited))
    pack.error_rate, pack.error_ci = errors / len(audited), f"{lo:.1%}-{hi:.1%} (n={len(audited)})"
    pack.save(update_fields=["error_rate", "error_ci"])
    # Items the audit caught are not shipped.
    PackItem.objects.filter(pack=pack, checks__audit__error=True).update(status="rejected")
    return {"audited": len(audited), "errors": errors}


INGEST = {"generate": ingest_generated, "solve": ingest_solved, "equiv": ingest_equiv, "audit": ingest_audit}


def collect(pack):
    """Finishes every ended batch of [pack]. Returns {stage: stats}."""
    done = {}
    for b in ContentBatch.objects.filter(pack=pack, status="submitted"):
        if ai._batches().retrieve(b.batch_id).processing_status != "ended":
            continue
        results, usd = {}, 0.0
        for r in ai._batches().results(b.batch_id):
            if r.result.type == "succeeded":
                try:
                    results[r.custom_id] = ai.parse(r.result.message)
                except ai.ApiError:
                    results[r.custom_id] = None
                usd += ai.cost_usd(r.result.message.model, r.result.message.usage, batch=True)
            else:
                results[r.custom_id] = None
        done[b.stage] = INGEST[b.stage](pack, results, b.ctx)
        b.status, b.cost_usd = "done", usd
        b.save(update_fields=["status", "cost_usd"])
    return done


def advance(slug):
    """One pass over a pack: collect ended batches, then submit the next stage's work. Returns a status line."""
    bp = blueprint(slug)
    pack = ensure_pack(bp)
    collected = collect(pack)
    for stage, make in (("generate", lambda: generate_requests(pack, bp)), ("solve", lambda: solve_requests(pack)),
                        ("equiv", lambda: equiv_requests(pack)), ("audit", lambda: audit_requests(pack))):
        if _pending(pack, stage):
            return f"{slug}: waiting for {stage} ({collected})"
        n = _submit(pack, stage, make())
        if n:
            return f"{slug}: submitted {n} {stage} requests ({collected})"
    return f"{slug}: complete, error rate {pack.error_rate} [{pack.error_ci}] ({collected})"


def summary(pack):
    counts = dict(PackItem.objects.filter(pack=pack).values_list("status").annotate(n=Count("id")))
    cost = sum(ContentBatch.objects.filter(pack=pack).values_list("cost_usd", flat=True))
    ok = pack.error_rate is not None and pack.error_rate <= MAX_ERROR_RATE
    return {"slug": pack.slug, "title": pack.title_ar, **{s: counts.get(s, 0) for s in PackItem.STATUSES},
            "error_rate": pack.error_rate, "error_ci": pack.error_ci, "cost_usd": float(cost or 0),
            "tutor_reviewed": pack.tutor_reviewed, "ships": ok}
