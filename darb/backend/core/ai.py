"""Anthropic calls, prompts and output schemas for the AI endpoints."""
import difflib
import functools
import json
import logging
import re
import time
import uuid

import anthropic
from django.conf import settings
from django.db.models import Sum
from django.utils.timezone import now as tz_now

from .auth import ApiError
from .models import AiCall

log = logging.getLogger(__name__)

# Runtime AI is Haiku only (docs/GOAL-DARB.md). Opus/Sonnet run only in the offline content pipeline (core/content.py).
MODEL = "claude-haiku-5-5"
# $ per million tokens: input, 5-minute cache write, cache read, output (platform pricing, checked 2026-10-15).
# Haiku 5.5 has a second tier for prompts over 100K tokens (cached tokens count toward the 100K).
PRICES = {"claude-opus-5-5": (4, 5, 0.20, 20), "claude-sonnet-5-5": (2, 2.5, 0.20, 10),
          "claude-haiku-5-5": (0.10, 0.125, 0.01, 0.50)}
LONG_PRICES = {"claude-haiku-5-5": (100_000, (0.50, 0.625, 0.05, 2.50))}
AI_TYPES = ["basic", "mcq", "cloze", "typed", "code", "ordering"]  # no occlusion: the AI can't draw images
DUP_RATIO = 0.85


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
    if model in LONG_PRICES and sum(tok[:3]) > LONG_PRICES[model][0]:
        p = LONG_PRICES[model][1]
    return round(sum(t * r for t, r in zip(tok, p)) / 1e6 * (0.5 if batch else 1), 6)


def month_start():
    return tz_now().replace(day=1, hour=0, minute=0, second=0, microsecond=0)


def check_budget(user, estimate=0.0):
    """Refuses AI work that would take the user past their monthly cap (owner: no cap unless set)."""
    if user.cap_usd is None:
        return
    spent = float(AiCall.objects.filter(user=user, created__gte=month_start()).aggregate(s=Sum("cost_usd"))["s"] or 0)
    if spent + estimate > float(user.cap_usd):
        left = max(0.0, float(user.cap_usd) - spent)
        raise ApiError(402, f"Monthly AI budget reached: ${left:.2f} of ${float(user.cap_usd):.2f} left"
                            + (f", this needs about ${estimate:.2f}" if estimate else "") + ". Studying still works.")


def log_call(user, endpoint, model, msg, ok, error, duration_ms, batch=False):
    u = getattr(msg, "usage", None)
    row = AiCall.objects.create(
        user=user, endpoint=endpoint, model=model, ok=ok, error=error or ("" if ok else "unexpected error"), batch=batch,
        input_tokens=getattr(u, "input_tokens", 0) or 0, output_tokens=getattr(u, "output_tokens", 0) or 0,
        cache_read_tokens=getattr(u, "cache_read_input_tokens", 0) or 0,
        cache_creation_tokens=getattr(u, "cache_creation_input_tokens", 0) or 0,
        duration_ms=duration_ms, cost_usd=cost_usd(model, u, batch))
    log.info("ai %s%s user=%s model=%s ok=%s in=%d out=%d cache_read=%d cache_write=%d $%.4f ms=%d %s", endpoint,
             " (batch)" if batch else "", user, model, ok, row.input_tokens, row.output_tokens, row.cache_read_tokens,
             row.cache_creation_tokens, row.cost_usd, row.duration_ms, row.error)
    return float(row.cost_usd)


def params(system, messages, schema, model=None, effort="medium"):
    """Request params shared by streamed calls and batch requests (runtime: Haiku)."""
    return dict(model=model or MODEL, max_tokens=64000, system=system, messages=messages,
                output_config={"effort": effort, "format": {"type": "json_schema", "schema": schema}})


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


def call(user, endpoint, request, estimate=0.0, costs=None):
    """One streamed structured-output call; returns the parsed JSON object. Always logs an AiCall row (and appends
    its dollar cost to [costs] when given)."""
    check_budget(user, estimate)
    t0 = time.monotonic()
    msg, ok, error = None, False, ""
    try:
        # The server-side refusal fallback exists for Opus/Sonnet 5.5 only (not Haiku).
        msg = _create(**request, **(FALLBACK if "haiku" not in request["model"] else {}))
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
        cost = log_call(user, endpoint, request["model"], msg, ok, error, int((time.monotonic() - t0) * 1000))
        if costs is not None:
            costs.append(cost)


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
    tags=SL, topic=S)
REPLY_SCHEMA = _obj(reply=S)
FILL_SCHEMA = _obj(explanation=S, option_explanations=_null(SL))
BOOL = {"type": "boolean"}
# ---------- prompts ----------

CARD_RULES = """Card format (set every field a type doesn't use to null):
- basic: question = front, answer = back.
- mcq: question = exam-style scenario stem; options = 4 plausible options (5-6 for multiple response, and say "(Choose 2)"/"(Choose 3)" in the stem); correct = 0-based indices of the correct options; option_explanations = one string per option, same order, saying why that option is right or wrong. No "all/none of the above".
- cloze: question = text with 1-3 blanks written {{answer}} or {{answer::hint}}.
- typed: question = prompt; answer = canonical short answer (CLI command, service/API/field name); accepted = other acceptable forms.
- code: question = task or "what does this do?"; code = snippet shown with the question and/or answer_code = snippet shown with the answer; language = yaml|json|bash|python|...; answer = short markdown answer.
- ordering: question = what to order; items = 3-7 steps in the CORRECT order.
- Every card: explanation = markdown explaining why the right answer is right AND why each wrong option (or the common misconception) is wrong, then one short memory aid: a concrete analogy or mnemonic (and, where the concept is a process or calculation, a 2-3 line worked example). Keep it short; skip the aid only when it would be forced. tags = 1-4 lowercase topic tags. topic = a few words naming the specific topic.
- Markdown everywhere; fenced code blocks with a language. Be technically accurate and current. One concept per card. Test what the real exam rewards, not trivia."""

TUTOR_PROMPT = """You are an expert, patient tutor in Darb, a study app for Saudi students (middle school, high school, university, certifications).
The student is asking about the study card below. Answer in the student's language (Arabic unless they write in English), in markdown: precise, concrete and concise, with an example where it helps. Explicitly correct misconceptions and relate the answer to how the exam tests it. If the card itself is wrong, say so clearly."""

FILL_TASK = """Write this card's explanation in markdown: why the correct answer is right AND why each wrong option (or the most common misconception) is wrong. End with one short memory aid: a concrete analogy or mnemonic (and, for a process or calculation, a 2-3 line worked example).
If the card is an mcq, also return option_explanations: one string per option in the same order, each saying why that option is right or wrong. Otherwise return null for option_explanations."""

# ---------- helpers ----------

TYPE_FIELDS = {"basic": ["answer"], "mcq": ["options", "correct", "option_explanations"], "cloze": [],
               "typed": ["answer", "accepted"], "code": ["code", "answer_code", "language", "answer"], "ordering": ["items"]}


FENCE = re.compile(r"^\s*```[\w+-]*\n([\s\S]*?)\n?```\s*$")


def unfence(code):
    """A code field holds code; the model sometimes wraps it in its own ``` fence."""
    m = FENCE.match(code) if isinstance(code, str) else None
    return m.group(1) if m else code


def clean_card(raw, allowed=AI_TYPES):
    """Semantic validation of one AI card; returns the card content or None (dropped)."""
    t = raw.get("type")
    question, explanation = (raw.get("question") or "").strip(), (raw.get("explanation") or "").strip()
    if t not in allowed or not question or not explanation:
        return None
    card = {"type": t, "question": question, "explanation": explanation}
    card.update({k: unfence(raw[k]) if k in ("code", "answer_code") else raw[k]
                 for k in TYPE_FIELDS[t] if raw.get(k) not in (None, "", [])})
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


def _card_doc(data, now):
    return {"id": str(uuid.uuid4()), "kind": "card", "data": data, "updated_at": now, "deleted": False}


def _card_arg(body):
    card = body.get("card")
    if not isinstance(card, dict) or not card.get("question"):
        raise ApiError(400, "card (object with question) required")
    return card


# ---------- endpoints ----------

def explain(user, body):
    card = _card_arg(body)
    fill = body.get("mode") == "fill"
    system = [{"type": "text", "text": TUTOR_PROMPT},
              # Chat follow-ups re-read the card from cache; a one-shot fill would only pay the write surcharge.
              {"type": "text", "text": "The card (JSON):\n" + json.dumps(card, ensure_ascii=False),
               **({} if fill else {"cache_control": {"type": "ephemeral"}})}]
    if fill:
        out = call(user, "explain_fill", params(system, [{"role": "user", "content": FILL_TASK}], FILL_SCHEMA))
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
    out = call(user, "explain", params(system, messages, REPLY_SCHEMA))
    if not (out.get("reply") or "").strip():
        raise ApiError(502, "AI returned an empty reply")
    return {"reply": out["reply"]}


