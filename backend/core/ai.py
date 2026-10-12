"""Anthropic calls, prompts and output schemas for the AI endpoints."""
import base64
import binascii
import difflib
import functools
import json
import logging
import re
import time
import urllib.parse
import uuid
from pathlib import Path

import anthropic
from django.conf import settings

from . import stats
from .auth import ApiError
from .models import AiCall, Doc, domain_ids, known_certs, now_ms, save_docs

log = logging.getLogger(__name__)

# Server-side refusal fallback. If the API ever rejects these, set FALLBACK = {}. Not accepted by the Batch API.
FALLBACK = {"extra_headers": {"anthropic-beta": "server-side-fallback-2026-07-01"}, "extra_body": {"fallbacks": "default"}}
# $ per million tokens: input, 5-minute cache write, cache read, output (platform pricing page, checked 2026-10-12).
PRICES = {"claude-opus-5-5": (4, 5, 0.20, 20), "claude-sonnet-5-5": (2, 2.5, 0.10, 10)}
GUIDES = Path(__file__).parent / "guides"
AI_TYPES = ["basic", "mcq", "cloze", "typed", "code", "ordering"]  # no occlusion: the AI can't draw images
IMAGE_TYPES = {"image/jpeg", "image/png", "image/gif", "image/webp"}
YOUTUBE = "https://www.youtube.com/results?search_query="
DUP_RATIO = 0.85
MAX_EXISTING_LINES = 300  # existing cards shown to the model for dedupe/retag; the difflib filter still checks all


# ---------- the one Anthropic seam ----------

@functools.cache
def _client():
    return anthropic.Anthropic(api_key=settings.ANTHROPIC_API_KEY, timeout=300, max_retries=2)


def _create(**kwargs):
    """Streams one Messages call and returns the final message (tests mock this)."""
    if not settings.ANTHROPIC_API_KEY:
        raise ApiError(503, "ANTHROPIC_API_KEY is not configured on the server")
    with _client().messages.stream(**kwargs) as stream:
        return stream.get_final_message()


def _batches():
    """The Message Batches resource (tests mock this)."""
    if not settings.ANTHROPIC_API_KEY:
        raise ApiError(503, "ANTHROPIC_API_KEY is not configured on the server")
    return _client().messages.batches


def cost_usd(model, usage, batch=False):
    """Dollar cost of one response from its usage; the Batch API bills every token at 50%."""
    p = PRICES.get(model)
    if not p or usage is None:
        return 0.0
    tok = [getattr(usage, k, 0) or 0 for k in
           ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")]
    return round(sum(t * r for t, r in zip(tok, p)) / 1e6 * (0.5 if batch else 1), 6)


def log_call(endpoint, model, msg, ok, error, duration_ms, batch=False):
    u = getattr(msg, "usage", None)
    row = AiCall.objects.create(
        endpoint=endpoint, model=model, ok=ok, error=error or ("" if ok else "unexpected error"), batch=batch,
        input_tokens=getattr(u, "input_tokens", 0) or 0, output_tokens=getattr(u, "output_tokens", 0) or 0,
        cache_read_tokens=getattr(u, "cache_read_input_tokens", 0) or 0,
        cache_creation_tokens=getattr(u, "cache_creation_input_tokens", 0) or 0,
        duration_ms=duration_ms, cost_usd=cost_usd(model, u, batch))
    log.info("ai %s%s ok=%s in=%d out=%d cache_read=%d cache_write=%d $%.4f ms=%d %s", endpoint,
             " (batch)" if batch else "", ok, row.input_tokens, row.output_tokens, row.cache_read_tokens,
             row.cache_creation_tokens, row.cost_usd, row.duration_ms, row.error)


def params(system, messages, schema):
    """Request params shared by streamed calls and batch requests."""
    return dict(model=settings.CERTDECK_MODEL, max_tokens=64000, system=system, messages=messages,
                output_config={"effort": "medium", "format": {"type": "json_schema", "schema": schema}})


def parse(msg):
    """Structured-output message -> dict, or ApiError."""
    if msg.stop_reason in ("refusal", "max_tokens"):
        raise ApiError(502, f"AI response unusable (stop_reason={msg.stop_reason})")
    text = next((b.text for b in msg.content if b.type == "text"), None)
    try:
        out = json.loads(text or "")
    except ValueError:
        raise ApiError(502, "AI returned invalid JSON")
    if not isinstance(out, dict):
        raise ApiError(502, "AI returned invalid JSON")
    return out


def call(endpoint, request):
    """One streamed structured-output call; returns the parsed JSON object. Always logs an AiCall row."""
    t0 = time.monotonic()
    msg, ok, error = None, False, ""
    try:
        msg = _create(**request, **FALLBACK)
        out = parse(msg)
        ok = True
        return out
    except ApiError as e:
        error = str(e.detail)
        raise
    except anthropic.APIConnectionError as e:  # includes APITimeoutError
        error = f"connection: {e}"
        raise ApiError(503, "AI service unreachable or timed out, try again") from e
    except anthropic.RateLimitError as e:
        error = f"rate limited: {e.message}"
        raise ApiError(429, "AI rate limit reached, try again later") from e
    except anthropic.APIStatusError as e:
        error = f"{e.status_code}: {e.message}"
        raise ApiError(502, f"AI service error ({e.status_code})") from e
    except anthropic.AnthropicError as e:
        error = repr(e)
        raise ApiError(502, "AI service error") from e
    finally:
        log_call(endpoint, request["model"], msg, ok, error, int((time.monotonic() - t0) * 1000))


# ---------- output schemas (structured outputs: no recursion, all props required, nullable via anyOf) ----------

def _null(s):
    return {"anyOf": [s, {"type": "null"}]}


def _obj(**props):
    return {"type": "object", "additionalProperties": False, "properties": props, "required": list(props)}


S = {"type": "string"}
SL = {"type": "array", "items": S}
INT = {"type": "integer"}
CARD = _obj(
    type={"type": "string", "enum": AI_TYPES}, question=S, answer=_null(S), options=_null(SL),
    correct=_null({"type": "array", "items": INT}), option_explanations=_null(SL), accepted=_null(SL),
    items=_null(SL), code=_null(S), answer_code=_null(S), language=_null(S), explanation=S,
    certs={"type": "array", "items": _obj(cert=S, domain=S)}, tags=SL, topic=S)
VIDEOS = {"type": "array", "items": _obj(title=S, query=S)}
GENERATE_SCHEMA = _obj(cards={"type": "array", "items": CARD},
                       retag={"type": "array", "items": _obj(card_id=S, cert=S, domain=S)})
REPLY_SCHEMA = _obj(reply=S)
FILL_SCHEMA = _obj(explanation=S, option_explanations=_null(SL))
VARIANTS_SCHEMA = _obj(variants={"type": "array", "items": CARD}, explanation=_null(S), learn=_null(S), videos=VIDEOS)
ANALYZE_SCHEMA = _obj(
    summary=S,
    weak_areas={"type": "array", "items": _obj(rank=INT, domain=S, topic=S, diagnosis=S)},
    actions={"type": "array", "items": _obj(label=S, domain=S, topic=S, count=INT)},
    videos=VIDEOS,
    overrides={"type": "array", "items": _obj(
        card_ids=SL, domain=_null(S), kind={"type": "string", "enum": ["advance", "postpone", "priority"]},
        days=_null(INT), priority=_null(INT), reason=S)})


# ---------- prompts ----------

CARD_RULES = """Card format (set every field a type doesn't use to null):
- basic: question = front, answer = back.
- mcq: question = exam-style scenario stem; options = 4 plausible options (5-6 for multiple response, and say "(Choose 2)"/"(Choose 3)" in the stem); correct = 0-based indices of the correct options; option_explanations = one string per option, same order, saying why that option is right or wrong. No "all/none of the above".
- cloze: question = text with 1-3 blanks written {{answer}} or {{answer::hint}}.
- typed: question = prompt; answer = canonical short answer (CLI command, service/API/field name); accepted = other acceptable forms.
- code: question = task or "what does this do?"; code = snippet shown with the question and/or answer_code = snippet shown with the answer; language = yaml|json|bash|python|...; answer = short markdown answer.
- ordering: question = what to order; items = 3-7 steps in the CORRECT order.
- Every card: explanation = markdown explaining why the right answer is right AND why each wrong option (or the common misconception) is wrong. certs = [{cert, domain}] for EVERY known certification whose official domains the card fits (overlap is common, e.g. Lambda limits fit DVA-C02 domain 1 and SAA-C03 domain 3), using only the codes and domain ids listed below. tags = 1-4 lowercase topic tags (e.g. lambda, iam, kubectl). topic = a few words naming the specific topic.
- Markdown everywhere; fenced code blocks with a language. Be technically accurate and current. One concept per card. Test what the real exam rewards, not trivia."""

GENERATE_PROMPT = f"""You write flashcards for CertDeck, a spaced-repetition app the student uses to pass IT certification exams.
Ground every card in the official exam guide below and in any material the student provides.
Pick the best mix of card types for the material: scenario MCQs for service-selection and design trade-offs, typed for exact commands and names, cloze for key facts and limits, code for policies/templates/manifests, ordering for processes, basic for definitions.

{CARD_RULES}

Never duplicate an existing card (listed with the request) or another new card; target gaps the existing cards don't cover.
retag: list existing cards from OTHER certifications that already teach a domain of the target certification, as {{card_id, cert: target cert code, domain: target domain id}}, so the student isn't re-taught. Only genuine coverage; empty list if none or no target certification."""

MCQ_EXAM_STYLE = """Exam style: write realistic exam scenario questions: a 2-4 sentence scenario with requirements and constraints (cost, least operational overhead, security, performance, availability) followed by the question. Mix single-answer (4 options) and multiple-response "(Choose 2)"/"(Choose 3)" questions (5-6 options). Distractors must be plausible options that each fail one requirement."""

PERFORMANCE_EXAM_STYLE = """Exam style: this exam is performance-based (hands-on tasks in a terminal against live clusters). Phrase each card as an exam task (e.g. "In namespace web, create ..."): typed cards whose answer is the exact imperative command, and code cards whose answer_code is the complete YAML manifest. Mention time-saving flags (e.g. --dry-run=client -o yaml) in explanations."""

TUTOR_PROMPT = """You are an expert, patient tutor helping a student prepare for an IT certification exam with CertDeck flashcards.
The student is asking about the flashcard below. Answer in markdown: precise, concrete and concise, with examples where they help. Explicitly correct misconceptions and relate the answer to how the real exam tests it. If the card itself is wrong or outdated, say so clearly."""

FILL_TASK = """Write this card's explanation in markdown: why the correct answer is right AND why each wrong option (or the most common misconception) is wrong.
If the card is an mcq, also return option_explanations: one string per option in the same order, each saying why that option is right or wrong. Otherwise return null for option_explanations."""

VARIANT_PROMPT = f"""You write variant flashcards for CertDeck, a spaced-repetition app for IT certification exams.
A variant tests the SAME concept as the original card from a different angle: a different scenario, wording, card type or direction (e.g. ask for the service given the requirement instead of the requirement given the service), so remembering the original's answer or option position doesn't help. Do not copy the original's options in the same order.

{CARD_RULES}"""

LEECH_TASK = """This card is a leech: the student keeps failing it. Also return:
- explanation: the concept re-explained a DIFFERENT way than the card's current explanation (an analogy, a step-by-step walkthrough, or a contrast with what it is commonly confused with), in markdown.
- learn: short markdown learning content: key facts to memorize, a mnemonic, the common trap, and pointers to the official docs pages to read.
- videos: 2-3 YouTube searches {title, query} that would teach this concept."""

ANALYZE_PROMPT = """You are a study coach analyzing a student's spaced-repetition data for one certification exam (CertDeck app).
Scheduling is FSRS by default and stays the default. Propose scheduling overrides only when the data clearly justifies them: misconceptions (answered "sure" but wrong), weak domains close to the exam date, or clearly mastered cards (high retrievability, no lapses) whose reviews can be pushed out. Every override needs a specific reason.

Input: per-domain stats (cards, new cards, reviews, accuracy, lapses, misconception reviews and currently flagged cards, leeches, confidence calibration = review accuracy per confidence level guess/unsure/sure, mean FSRS retrievability, exam-simulation accuracy), exam weights, recent exam simulations, days until the exam, and the worst cards.
Calibration: "sure" with low accuracy means overconfidence (dangerous); "guess" with high accuracy means underconfidence.

Return:
- summary: 3-6 sentences: readiness vs. the exam date and the biggest risks.
- weak_areas: ranked (rank 1 = most urgent), each with the domain id, a specific topic and a plain-language diagnosis that cites the numbers. Weigh by exam weight.
- actions: concrete one-tap actions, mainly generating cards for gaps: label (e.g. "Generate 15 cards on SQS visibility timeout"), domain id, topic, count (5-30).
- videos: 2-5 YouTube searches {title, query} for the weakest topics.
- overrides (0-10, each at most 50 cards): kind "advance" (review sooner; days = how many days earlier, or null = due now), "postpone" (days = how many days later, 1-30; only for mastered cards), "priority" (priority -2..2, higher = earlier in the queue). Target card_ids from worst_cards, or set card_ids [] and domain to a domain id to target that domain's cards. Use domain null when card_ids are given.
Be specific and honest; never invent data that isn't in the input."""


# ---------- helpers ----------

@functools.cache
def guide(code):
    path = GUIDES / f"{code}.md"
    return path.read_text() if re.fullmatch(r"[A-Za-z0-9-]+", code or "") and path.exists() else ""


def certs_text(certs):
    return "\n".join(
        f"- {code} ({c.get('name', '')}): " + "; ".join(
            f"domain {d['id']} {d.get('name', '')} ({round(float(d.get('weight') or 0) * 100)}%)"
            for d in c.get("domains", []))
        for code, c in certs.items())


TYPE_FIELDS = {"basic": ["answer"], "mcq": ["options", "correct", "option_explanations"], "cloze": [],
               "typed": ["answer", "accepted"], "code": ["code", "answer_code", "language", "answer"], "ordering": ["items"]}


def clean_card(raw, allowed=AI_TYPES):
    """Semantic validation of one AI card; returns the card content or None (dropped)."""
    t = raw.get("type")
    question, explanation = (raw.get("question") or "").strip(), (raw.get("explanation") or "").strip()
    if t not in allowed or not question or not explanation:
        return None
    card = {"type": t, "question": question, "explanation": explanation}
    card.update({k: raw[k] for k in TYPE_FIELDS[t] if raw.get(k) not in (None, "", [])})
    if t == "mcq":
        opts, correct, expl = card.get("options", []), card.get("correct", []), card.get("option_explanations", [])
        if (len(opts) < 2 or not correct or len(set(correct)) != len(correct) or len(correct) >= len(opts)
                or not all(0 <= i < len(opts) for i in correct) or len(expl) != len(opts)):
            return None
        card["correct"] = sorted(correct)
    elif t == "cloze" and not re.search(r"\{\{[^{}]+\}\}", question):
        return None
    elif t in ("basic", "typed") and not card.get("answer"):
        return None
    elif t == "code" and not (card.get("code") or card.get("answer_code")):
        return None
    elif t == "ordering" and len(card.get("items", [])) < 2:
        return None
    return card


def card_certs(raw, certs):
    """AI [{cert, domain}] -> {cert: domain}, keeping only known cert codes and domain ids."""
    return {x["cert"]: str(x["domain"]) for x in raw.get("certs") or []
            if str(x.get("domain")) in domain_ids(certs.get(x.get("cert"), {}))}


def _tags(raw):
    return [str(t).strip().lower() for t in raw.get("tags") or [] if str(t).strip()][:6]


def _norm(q):
    return " ".join(re.sub(r"[^\w{}]+", " ", str(q).lower()).split())[:400]


def _is_dup(q, seen):
    # ponytail: linear difflib scan over all questions; fine for thousands of cards, use embeddings beyond that.
    m = difflib.SequenceMatcher(None, "", q)
    for s in seen:
        m.set_seq1(s)
        if m.real_quick_ratio() >= DUP_RATIO and m.quick_ratio() >= DUP_RATIO and m.ratio() >= DUP_RATIO:
            return True
    return False


def _int(value, default, lo, hi):
    try:
        return max(lo, min(hi, int(value)))
    except (TypeError, ValueError):
        return default


def _videos(raw):
    return [{"title": v.get("title") or v["query"], "url": YOUTUBE + urllib.parse.quote_plus(v["query"])}
            for v in (raw or [])[:5] if (v.get("query") or "").strip()]


def _card_doc(data, now):
    return {"id": str(uuid.uuid4()), "kind": "card", "data": data, "updated_at": now, "deleted": False}


def _card_arg(body):
    card = body.get("card")
    if not isinstance(card, dict) or not card.get("question"):
        raise ApiError(400, "card (object with question) required")
    return card


def _file_blocks(files):
    if not isinstance(files, list):
        raise ApiError(400, "files must be a list")
    blocks = []
    for f in files:
        if not isinstance(f, dict):
            raise ApiError(400, "files must be [{name, media_type, data}]")
        name, media_type = str(f.get("name") or "file"), str(f.get("media_type") or "")
        try:
            raw = base64.b64decode(f.get("data") or "", validate=True)
        except (binascii.Error, TypeError, ValueError):
            raise ApiError(400, f"{name}: data is not valid base64")
        source = {"type": "base64", "media_type": media_type, "data": f["data"]}
        if media_type == "application/pdf":
            blocks.append({"type": "document", "source": source, "title": name})
        elif media_type in IMAGE_TYPES:
            blocks.append({"type": "image", "source": source})
        elif media_type.startswith("text/"):
            blocks.append({"type": "text", "text": f"File {name}:\n{raw.decode('utf-8', 'replace')}"})
        else:
            raise ApiError(400, f"{name}: unsupported media_type {media_type!r} (pdf, images, text/*)")
    return blocks


# ---------- endpoints ----------

def _words(s):
    return set(re.findall(r"[a-z0-9]{4,}", str(s).lower()))


def relevant_cards(cards, cert, domain, hint):
    """Existing cards worth showing the model, best first: the target cert+domain, the rest of that cert, then other
    certs' cards (retag candidates); each boosted by word overlap with the topic/material. Capped."""
    # ponytail: keyword overlap, not embeddings; fine for dedupe hints since difflib re-checks every card afterwards.
    words = _words(hint)

    def score(d):
        tags = d.data.get("certs") or {}
        rank = 4 if cert in tags and domain and str(tags[cert]) == domain else 2 if cert in tags else 1
        return rank + min(3, len(words & _words(d.data.get("question", "")))), d.data.get("created_at") or 0

    return sorted(cards, key=score, reverse=True)[:MAX_EXISTING_LINES]


def generate_request(body):
    """Validates a generate body -> (request params, ctx). ctx is what generate_finish needs (JSON-safe)."""
    certs = known_certs()
    cert = body.get("cert") or None
    if cert is not None and cert not in certs:
        raise ApiError(400, f"unknown cert {cert!r}")
    domain = str(body["domain"]) if body.get("domain") not in (None, "") else None
    if domain and (not cert or domain not in domain_ids(certs[cert])):
        raise ApiError(400, f"unknown domain {domain!r} for cert {cert!r}")
    topic, text = str(body.get("topic") or "").strip(), str(body.get("text") or "").strip()
    files = _file_blocks(body.get("files") or [])
    if not (cert or topic or text or files):
        raise ApiError(400, "give at least one of cert, topic, text, files")
    count = _int(body.get("count"), 20, 1, 50)
    exam_style = bool(body.get("exam_style"))
    performance = bool(cert) and (certs[cert].get("exam") or {}).get("kind") == "performance"
    types = [t for t in body.get("types") or [] if t in AI_TYPES]
    if not types:
        types = (["typed", "code"] if performance else ["mcq"]) if exam_style else AI_TYPES

    # Stable per cert -> one cached prefix; the per-request card list goes in the user turn, after the cache point.
    system = [{"type": "text", "cache_control": {"type": "ephemeral"},
               "text": f"{GENERATE_PROMPT}\n\nKnown certifications:\n{certs_text(certs)}"
                       + (f"\n\nOfficial exam guide for {cert}:\n{guide(cert)}" if cert else "")}]
    shown = relevant_cards(list(Doc.objects.filter(kind="card", deleted=False)), cert, domain, f"{topic} {text[:2000]}")
    lines = [f"{d.id} | " + (",".join(f"{k}:{v}" for k, v in (d.data.get("certs") or {}).items()) or "-")
             + " | " + " ".join(str(d.data.get("question", "")).split())[:100] for d in shown]
    existing = "Existing cards, most relevant first (id | cert:domain | question start):\n" + ("\n".join(lines) or "(none)")

    task = [f"Generate {count} new flashcards."]
    dname = ""
    if cert:
        dname = next((d.get("name", "") for d in certs[cert]["domains"] if str(d["id"]) == domain), "")
        task.append(f"Target certification: {cert}." + (f" Target domain: {domain} ({dname})." if domain else
                                                         " Spread cards across its domains by exam weight unless the material says otherwise."))
    if topic:
        task.append(f"Topic: {topic}")
    task.append("Allowed card types: " + ", ".join(types) + ". Use the best mix for the material.")
    if exam_style:
        task.append(PERFORMANCE_EXAM_STYLE if performance else MCQ_EXAM_STYLE)
    if files:
        task.append("Base the cards on the attached files.")
    if text:
        task.append(f"Base the cards on this material:\n<material>\n{text}\n</material>")
    request = params(system, [{"role": "user", "content": files + [{"type": "text", "text": existing},
                                                                  {"type": "text", "text": "\n".join(task)}]}],
                     GENERATE_SCHEMA)
    label = topic or dname or (f"{len(files)} file(s)" if files else "notes" if text else cert or "")
    return request, {"cert": cert, "types": types, "count": count, "label": label[:80]}


def generate_finish(out, ctx):
    """Validates, dedupes and saves AI cards; checks retag suggestions. Shared by the streamed and batch paths."""
    certs, cert, types, count = known_certs(), ctx["cert"], ctx["types"], ctx["count"]
    cards = list(Doc.objects.filter(kind="card", deleted=False))
    now = now_ms()
    seen = [_norm(d.data.get("question", "")) for d in cards]
    docs, skipped, dropped = [], 0, 0
    for raw in out.get("cards", [])[:count]:
        card, tags = clean_card(raw, types), card_certs(raw, certs)
        if not card or not tags:
            dropped += 1
            continue
        q = _norm(card["question"])
        if _is_dup(q, seen):
            skipped += 1
            continue
        seen.append(q)
        code = cert if cert in tags else next(iter(tags))
        card.update(certs=tags, tags=_tags(raw), source=f"ai:{code} d{tags[code]} {raw.get('topic', '')}".strip(),
                    new=True, created_at=now)
        docs.append(_card_doc(card, now))

    by_id = {d.id: d for d in cards}
    retag, retagged = [], set()
    for r in out.get("retag", []):
        d, c, dom = by_id.get(r.get("card_id")), r.get("cert"), str(r.get("domain"))
        if (d and d.id not in retagged and c in certs and dom in domain_ids(certs[c]) and (not cert or c == cert)
                and c not in (d.data.get("certs") or {})):
            retagged.add(d.id)
            retag.append({"card_id": d.id, "cert": c, "domain": dom})

    save_docs(docs)
    log.info("generate cert=%s saved=%d skipped_duplicates=%d dropped_invalid=%d retag=%d",
             cert, len(docs), skipped, dropped, len(retag))
    return {"cards": [dict(d["data"], id=d["id"]) for d in docs], "retag": retag,
            "skipped_duplicates": skipped, "dropped_invalid": dropped}


def generate(body):
    request, ctx = generate_request(body)
    return generate_finish(call("generate", request), ctx)


def explain(body):
    card = _card_arg(body)
    fill = body.get("mode") == "fill"
    system = [{"type": "text", "text": TUTOR_PROMPT},
              # Chat follow-ups re-read the card from cache; a one-shot fill would only pay the write surcharge.
              {"type": "text", "text": "The card (JSON):\n" + json.dumps(card, ensure_ascii=False),
               **({} if fill else {"cache_control": {"type": "ephemeral"}})}]
    if fill:
        out = call("explain_fill", params(system, [{"role": "user", "content": FILL_TASK}], FILL_SCHEMA))
        expl = out.get("option_explanations")
        if card.get("type") != "mcq":
            expl = None
        elif not isinstance(expl, list) or len(expl) != len(card.get("options") or []):
            raise ApiError(502, "AI returned option_explanations that don't match the options")
        if not (out.get("explanation") or "").strip():
            raise ApiError(502, "AI returned an empty explanation")
        return {"explanation": out["explanation"], "option_explanations": expl}

    messages = []
    for m in body.get("messages") or []:
        if not isinstance(m, dict) or m.get("role") not in ("user", "assistant") or not str(m.get("text") or "").strip():
            raise ApiError(400, "messages must be [{role: user|assistant, text}]")
        messages.append({"role": m["role"], "content": str(m["text"])})
    if not messages or messages[0]["role"] != "user":
        messages.insert(0, {"role": "user", "content": "Explain this card to me in more depth."})
    if messages[-1]["role"] != "user":
        raise ApiError(400, "the last message must be from the user")
    out = call("explain", params(system, messages, REPLY_SCHEMA))
    if not (out.get("reply") or "").strip():
        raise ApiError(502, "AI returned an empty reply")
    return {"reply": out["reply"]}


def variants(body):
    card = _card_arg(body)
    if not isinstance(card.get("id"), str) or not card["id"]:
        raise ApiError(400, "card.id required")
    count, leech = _int(body.get("count"), 1, 1, 3), bool(body.get("leech"))
    certs = known_certs()
    system = [{"type": "text", "text": f"{VARIANT_PROMPT}\n\nKnown certifications:\n{certs_text(certs)}"},
              {"type": "text", "text": "Original card (JSON):\n" + json.dumps(card, ensure_ascii=False)}]  # one-shot: no cache
    task = f"Write exactly {count} variant card(s) of the original card."
    task += "\n\n" + LEECH_TASK if leech else " Set explanation and learn to null and videos to []."
    out = call("variants", params(system, [{"role": "user", "content": task}], VARIANTS_SCHEMA))

    now, docs, dropped = now_ms(), [], 0
    orig_certs = card.get("certs") if isinstance(card.get("certs"), dict) else {}
    for raw in out.get("variants", [])[:count]:
        v = clean_card(raw)
        if not v:
            dropped += 1
            continue
        v.update(certs=orig_certs or card_certs(raw, certs), tags=card.get("tags") or _tags(raw),
                 source=f"ai:variant {raw.get('topic', '')}".strip(), variant_of=card["id"], new=True, created_at=now)
        docs.append(_card_doc(v, now))
    save_docs(docs)
    result = {"variants": [dict(d["data"], id=d["id"]) for d in docs], "dropped_invalid": dropped}
    if leech:
        result.update(explanation=out.get("explanation") or "", learn=out.get("learn") or "",
                      videos=_videos(out.get("videos")))
    return result


MAX_OVERRIDES, MAX_OVERRIDE_CARDS = 10, 50


def _override(o, cards):
    """Bound one AI override proposal; returns override doc data (without ids/timestamps) or None."""
    kind, reason = o.get("kind"), (o.get("reason") or "").strip()
    if kind not in ("advance", "postpone", "priority") or not reason:
        return None
    priority = _int(o.get("priority"), 0, -2, 2) if kind == "priority" else None
    if kind == "priority" and not priority:
        return None
    ids = [i for i in dict.fromkeys(o.get("card_ids") or []) if i in cards]
    if not ids and o.get("domain"):
        dom = str(o["domain"])
        pool = [(cid, c["r"]) for cid, c in cards.items()
                if c["domain"] == dom and (kind == "priority" or c["r"] is not None)]  # (un)scheduling needs reviewed cards
        weakest_first = kind == "advance" or (kind == "priority" and priority > 0)
        pool.sort(key=lambda x: x[1] or 0.0, reverse=not weakest_first)
        ids = [cid for cid, _ in pool]
    ids = ids[:MAX_OVERRIDE_CARDS]
    if not ids:
        return None
    data = {"reason": reason, "card_ids": ids, "due_shift_days": None, "due_now": False, "priority": priority,
            "applied_at": None, "reverted_at": None, "before": {}}
    days = o.get("days")
    if kind == "advance":
        if days:
            data["due_shift_days"] = -_int(abs(days), 1, 1, 30)
        else:
            data["due_now"] = True
    elif kind == "postpone":
        data["due_shift_days"] = _int(abs(days or 7), 7, 1, 30)
    return data


def analyze(body):
    certs = known_certs()
    code = body.get("cert")
    if code not in certs:
        raise ApiError(400, f"unknown cert {code!r}")
    data, cards = stats.cert_stats(code, certs[code])
    system = [{"type": "text", "text": ANALYZE_PROMPT}]
    out = call("analyze", params(system, [{"role": "user", "content": "Stats (JSON):\n" + json.dumps(data)}], ANALYZE_SCHEMA))

    now, analysis_id = now_ms(), str(uuid.uuid4())
    overrides = []
    for o in out.get("overrides", []):
        od = _override(o, cards)
        if od and len(overrides) < MAX_OVERRIDES:
            overrides.append({"id": str(uuid.uuid4()), "kind": "override", "updated_at": now, "deleted": False,
                              "data": {"created_at": now, "analysis_id": analysis_id, **od}})
    analysis = {
        "created_at": now, "cert": code, "summary": out.get("summary", ""),
        "weak_areas": sorted(out.get("weak_areas", []), key=lambda w: w.get("rank", 0)),
        "actions": [{"label": a["label"], "cert": code, "domain": a["domain"], "topic": a["topic"],
                     "count": _int(a.get("count"), 15, 1, 50)} for a in out.get("actions", [])],
        "videos": _videos(out.get("videos")),
        "override_ids": [o["id"] for o in overrides],
    }
    save_docs([{"id": analysis_id, "kind": "analysis", "data": analysis, "updated_at": now, "deleted": False}] + overrides)
    return {**analysis, "id": analysis_id, "overrides": [{"id": o["id"], **o["data"]} for o in overrides]}
