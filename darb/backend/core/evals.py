"""AI eval: each runtime feature on CertDeck's old setup (Opus writes, Sonnet reads) and on Darb's (Haiku, low effort,
tight max_tokens), on the fixed set in eval_set.json. Opus judges each pair blind (random order); grading is scored
against hand-set gold scores. `manage.py ai_eval` writes docs/DARB-AI-EVAL.md. Offline tool: it calls the API directly
(not the runtime gateway, which is Haiku-only) and costs a few dollars per run."""
import json
import random
import statistics
import time
from pathlib import Path

from . import ai, college, reteach

SET = Path(__file__).parent / "eval_set.json"
JUDGE = "claude-opus-5-5"
BASELINE = {"explain": "claude-opus-5-5", "grade": "claude-opus-5-5", "cards": "claude-opus-5-5",
            "reteach": "claude-sonnet-5-5"}
# A feature switches to Haiku only if: mean judged score >= MIN_SCORE, not more than MAX_DROP below the baseline, and at
# most MAX_WRONG items judged incorrect (correctness <= 2). Grading: mean absolute error and verdict agreement vs gold.
# MAX_DROP was 0.3; owner decision 2026-10-18: the absolute 4.0 bar decides, the drop rule only catches a collapse.
MIN_SCORE, MAX_DROP, MAX_WRONG = 4.0, 1.0, 1
GRADE_MAE, GRADE_AGREE = 0.15, 0.85
ARABIC_MIN = 4.0

JUDGE_PROMPT = """You are a strict examiner checking two AI outputs produced for the same task in a study app for Saudi students (ages 12+). Score each output independently on a 1-5 scale:
- correctness: every fact, number and answer key is right (5 = flawless, 3 = a minor slip, 1 = wrong or misleading)
- teaching: clear, focused, right level for the student, actually helps them learn the point (for cards: well-formed, exam-worthy, faithful to the source)
- language: written in the expected language; for Arabic, correct Modern Standard Arabic with natural phrasing (5) down to broken or mixed-language text (1)
- overall: your overall judgment
Also list concrete errors you found (empty list if none). Judge the content, not the length. Do not favor either position."""
SCORE = ai._obj(correctness=ai.INT, teaching=ai.INT, language=ai.INT, overall=ai.INT, errors=ai.SL)
JUDGE_SCHEMA = ai._obj(output_1=SCORE, output_2=SCORE)


def _requests(feature, item):
    """The production request for one eval item."""
    if feature == "explain":
        return ai.explain_request(item["card"], item["chat"], item["lang"])[0]
    if feature == "grade":
        return college.grade_request(item["card"], item["answer"])
    if feature == "cards":
        return college.generate_request(item["context"], item["kps"])
    return reteach.reteach_request(item["card"])


def _run(request, model):
    """Sends [request] on [model]: Haiku with Darb's settings; a baseline model with CertDeck's (medium effort, room
    to think). Returns (parsed output or error string, usd, seconds)."""
    req = dict(request, model=model)
    if model != ai.MODEL:
        req.update(max_tokens=max(request["max_tokens"] * 4, 16000), output_config={**request["output_config"], "effort": "medium"})
    t0 = time.monotonic()
    try:
        msg = ai._create(**req)
        out = ai.parse(msg)
    except Exception as e:  # noqa: BLE001 - a failure is a result to report
        return f"ERROR: {getattr(e, 'detail', e)}", 0.0, time.monotonic() - t0
    return out, ai.cost_usd(model, msg.usage), time.monotonic() - t0


def _judge(feature, item, out_a, out_b):
    """Blind pairwise judgment; returns (scores of a, scores of b, judge usd)."""
    swap = random.random() < 0.5
    first, second = (out_b, out_a) if swap else (out_a, out_b)
    task = {k: v for k, v in item.items() if k != "gold"}
    text = (f"Feature: {feature}. Expected language: {item.get('lang', 'ar')}.\nTask input (JSON):\n"
            f"{json.dumps(task, ensure_ascii=False)}\n\nOutput 1:\n{json.dumps(first, ensure_ascii=False)}\n\n"
            f"Output 2:\n{json.dumps(second, ensure_ascii=False)}")
    req = ai.params([{"type": "text", "text": JUDGE_PROMPT}], [{"role": "user", "content": text}], JUDGE_SCHEMA,
                    max_tokens=16000, effort="high", model=JUDGE)
    req["system"] = req["system"][1:]  # the judge is not a student-facing call: no safety block needed
    msg = ai._create(**req)
    out = ai.parse(msg)
    a, b = (out["output_2"], out["output_1"]) if swap else (out["output_1"], out["output_2"])
    return a, b, ai.cost_usd(JUDGE, msg.usage)


def _verdict(score):
    return "correct" if score >= 0.85 else "wrong" if score < 0.4 else "partial"


def run(features=None, log=print):
    data = json.loads(SET.read_text())
    results = {}
    for feature in features or ("explain", "grade", "cards", "reteach"):
        rows = []
        for i, item in enumerate(data[feature]):
            req = _requests(feature, item)
            base, base_usd, base_s = _run(req, BASELINE[feature])
            cand, cand_usd, cand_s = _run(req, ai.MODEL)
            if feature == "cards" and isinstance(cand, dict):  # Darb's second pass over the drafts
                cand, usd, s = _run(college.review_request(item["context"], item["kps"], cand["cards"]), ai.MODEL)
                cand_usd, cand_s = cand_usd + usd, cand_s + s
            row = {"i": i, "lang": item.get("lang", "ar"), "base_usd": base_usd, "cand_usd": cand_usd,
                   "base_s": base_s, "cand_s": cand_s, "base_out": base, "cand_out": cand}
            if feature == "grade":
                for side, out in (("base", base), ("cand", cand)):
                    s = college.grade_result(out)["score"] if isinstance(out, dict) else 0.0
                    row[side] = {"score": s, "err": abs(s - item["gold"]), "agree": _verdict(s) == _verdict(item["gold"])}
            else:
                a, b, judge_usd = _judge(feature, item, base, cand)
                row.update(base=a, cand=b, judge_usd=judge_usd)
            rows.append(row)
            log(f"{feature} {i}: base={row['base'].get('overall', row['base'].get('score'))} "
                f"cand={row['cand'].get('overall', row['cand'].get('score'))}")
        results[feature] = rows
    return results


def summarize(results):
    """Per-feature numbers and pass/fail by the thresholds above."""
    out = {}
    for feature, rows in results.items():
        cost = statistics.mean(r["cand_usd"] for r in rows)
        s = {"n": len(rows), "haiku_usd_per_call": cost, "base_usd_per_call": statistics.mean(r["base_usd"] for r in rows),
             "haiku_s": statistics.mean(r["cand_s"] for r in rows), "base_s": statistics.mean(r["base_s"] for r in rows)}
        if feature == "grade":
            s.update(haiku_mae=statistics.mean(r["cand"]["err"] for r in rows),
                     base_mae=statistics.mean(r["base"]["err"] for r in rows),
                     haiku_agree=statistics.mean(r["cand"]["agree"] for r in rows),
                     base_agree=statistics.mean(r["base"]["agree"] for r in rows))
            s["pass"] = s["haiku_mae"] <= GRADE_MAE and s["haiku_agree"] >= GRADE_AGREE
        else:
            for side in ("base", "cand"):
                s[f"{side}_overall"] = statistics.mean(r[side]["overall"] for r in rows)
                s[f"{side}_correct"] = statistics.mean(r[side]["correctness"] for r in rows)
                s[f"{side}_wrong"] = sum(r[side]["correctness"] <= 2 for r in rows)
            s["pass"] = (s["cand_overall"] >= MIN_SCORE and s["cand_overall"] >= s["base_overall"] - MAX_DROP
                         and s["cand_wrong"] <= MAX_WRONG)
        out[feature] = s
    arabic = [r["cand"]["language"] for rows in results.values() for r in rows if r["lang"] == "ar" and "language" in r["cand"]]
    if arabic:
        out["arabic"] = {"n": len(arabic), "haiku_language": statistics.mean(arabic), "pass": statistics.mean(arabic) >= ARABIC_MIN}
    return out


def session_cost(summary):
    """Measured Haiku cost of a typical study session: free (1 explanation + 1 graded answer) and Plus (3 explanations,
    2 graded answers, one re-teach a day, 10 uploaded pages a week turned into cards)."""
    c = {f: summary[f]["haiku_usd_per_call"] for f in ("explain", "grade", "cards", "reteach") if f in summary}
    free = c.get("explain", 0) + c.get("grade", 0)
    plus = 3 * c.get("explain", 0) + 2 * c.get("grade", 0) + c.get("reteach", 0) + c.get("cards", 0) * 10 / 7 / 3
    return {"free_session": free, "plus_session": plus, "free_month_20_sessions": 20 * free, "plus_month_20_sessions": 20 * plus}
