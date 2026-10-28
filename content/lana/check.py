# Checks a lecture's cards before import: shape, answer indexes, real duplicate options, and how often the correct
# option is longest/shortest as displayed (LaTeX commands count as one character). Usage: python3 check.py out/L01.json ...
import json
import re
import sys


def shown(s):
    return len(re.sub(r"\\[a-zA-Z]+", "x", re.sub(r"[$ ]|\\(?=[{}])|\\[,;:!]|\\q?quad\b", "", s)))


for path in sys.argv[1:]:
    items, errors, longest, shortest, mcqs = json.load(open(path)), [], 0, 0, 0
    for n, item in enumerate(items):
        if len(item.get("versions", [])) != 2:
            errors.append(f"{n}: needs 2 versions")
        for v, c in enumerate([item["original"]] + item.get("versions", [])):
            where = f"{n}.{v}"
            if not c.get("question"):
                errors.append(f"{where}: no question")
            if c.get("type") == "basic":
                if not c.get("answer"):
                    errors.append(f"{where}: no answer")
                continue
            opts, corr = c.get("options", []), c.get("correct", [])
            if c.get("type") != "mcq" or len(opts) != 4 or len(corr) != 1 or not 0 <= corr[0] < 4:
                errors.append(f"{where}: bad MCQ shape")
                continue
            if len(set(opts)) != 4:
                errors.append(f"{where}: duplicate options")
            if len(c.get("option_explanations", [])) != 4:
                errors.append(f"{where}: needs 4 option notes")
            if c["question"].count("$") % 2 or any(o.count("$") % 2 for o in opts):
                errors.append(f"{where}: unbalanced $")
            lens = [shown(o) for o in opts]
            right, wrong = lens[corr[0]], [l for i, l in enumerate(lens) if i != corr[0]]
            mcqs += 1
            longest += right > max(wrong)
            shortest += right < min(wrong)
    print(f"{path}: {len(items)} cards, {mcqs} MCQs, correct longest {longest * 100 // max(mcqs, 1)}%, "
          f"shortest {shortest * 100 // max(mcqs, 1)}%, {len(errors)} errors")
    for e in errors:
        print("  ", e)
