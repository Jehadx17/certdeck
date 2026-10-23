"""Checks version files against their input batches: python3 validate.py in/b1.json out/b1.json [...pairs]

Each out file: [{"card_id": "...", "versions": [card, card]}], card = {type, question, explanation, + type fields}.
Exits 1 on any error; prints the correct-answer length spread (should look random) for single-answer MCQs.
"""
import difflib
import json
import re
import sys

norm = lambda s: re.sub(r"[^a-z0-9]+", " ", str(s).lower()).strip()
similar = lambda a, b: difflib.SequenceMatcher(None, norm(a), norm(b)).ratio() > 0.85
short = lambda s: len(norm(s).split()) <= 3  # a name or number ("16", "Max I/O") can't be reworded; the question changes instead
FILLER = ("and nothing else", "as aws documents it", "with no extra services", "as a default setting", "with no further setup",
          "for every request in the account", "on a fixed schedule")

errors, ranks, ratios, types = [], [], [], []
pairs = sys.argv[1:]
for inp, out in zip(pairs[::2], pairs[1::2]):
    cards = {c["id"]: c for c in json.load(open(inp))}
    got = {o["card_id"]: o for o in json.load(open(out))}
    for cid in cards.keys() - got.keys():
        errors.append(f"{out}: missing card {cid}")
    for cid in got.keys() - cards.keys():
        errors.append(f"{out}: unknown card {cid}")
    for cid, o in got.items():
        orig = cards.get(cid)
        if not orig:
            continue
        vs = o.get("versions") or []
        if len(vs) != 2:
            errors.append(f"{cid}: needs exactly 2 versions, has {len(vs)}")
        old_texts = [orig["question"], *(orig.get("options") or []), *([orig["answer"]] if orig.get("answer") else [])]
        for n, v in enumerate(vs):
            where, t = f"{cid} v{n + 2}", v.get("type")
            types.append(t)
            if not str(v.get("question", "")).strip() or not str(v.get("explanation", "")).strip():
                errors.append(f"{where}: question and explanation required")
            if similar(v.get("question", ""), orig["question"]):
                errors.append(f"{where}: question too close to the original")
            if t == "mcq":
                opts, corr = v.get("options") or [], v.get("correct") or []
                if not (3 <= len(opts) <= 6) or not corr or any(not isinstance(i, int) or not 0 <= i < len(opts) for i in corr) or len(set(corr)) != len(corr):
                    errors.append(f"{where}: mcq needs 3-6 options and valid correct indices")
                    continue
                if len(corr) == len(opts):
                    errors.append(f"{where}: every option is correct")
                if len({norm(x) for x in opts}) != len(opts):
                    errors.append(f"{where}: duplicate options")
                for x in opts:
                    if any(f in x.lower() for f in FILLER):
                        errors.append(f"{where}: filler padding in option: {x[:60]!r}")
                    if not short(x) and any(similar(x, old) for old in old_texts[1:]):
                        errors.append(f"{where}: option reuses the original's wording: {x[:60]!r}")
                if len(corr) == 1:
                    lens = [len(x) for x in opts]
                    c = lens[corr[0]]
                    wrong = [l for i, l in enumerate(lens) if i != corr[0]]
                    ranks.append(sorted(lens, reverse=True).index(c) == 0 and "longest" or (c == min(lens) and "shortest" or "middle"))
                    ratios.append(c / (sum(wrong) / len(wrong)))
            elif t == "cloze":
                if "{{" not in v["question"]:
                    errors.append(f"{where}: cloze needs {{{{blanks}}}}")
            elif t == "ordering":
                if len(v.get("items") or []) < 3:
                    errors.append(f"{where}: ordering needs 3+ items")
            elif t in ("basic", "typed", "code"):
                if not str(v.get("answer", "")).strip():
                    errors.append(f"{where}: {t} needs an answer")
                elif not short(v["answer"]) and any(similar(v["answer"], old) for old in old_texts[1:]):
                    errors.append(f"{where}: answer reuses the original's wording")
                if t == "code" and not str(v.get("code", "")).strip():
                    errors.append(f"{where}: code card needs code")
            else:
                errors.append(f"{where}: unknown type {t!r}")

print("\n".join(errors) or "no errors")
if types:
    print(f"versions {len(types)}, mcq {types.count('mcq') / len(types):.0%}")
    if types.count("mcq") < 0.6 * len(types):
        errors.append("FAIL: most versions must be MCQ")
        print(errors[-1])
if ranks:
    share = lambda k: ranks.count(k) / len(ranks)
    off = sum(1 for r in ratios if not 0.6 <= r <= 1.6)
    print(f"single-answer MCQ versions {len(ranks)}: correct longest {share('longest'):.0%}, shortest {share('shortest'):.0%}, "
          f"length ratio outside 0.6-1.6: {off}")
    if share("longest") > 0.35 or share("shortest") > 0.35 or off > 0.15 * len(ranks):
        errors.append("length spread not random enough")
        print("FAIL: correct answer length is a giveaway (target ~25% longest, ~25% shortest, ratio 0.6-1.6)")
sys.exit(1 if errors else 0)
