"""Merged items -> the ones whose SymPy check passes the app's own import checks, before importing.
Usage (backend venv, for SymPy): darb/backend/.venv/bin/python -I quiz_checks.py <items.jsonl> <kept.jsonl> <owner.md>
A value written with a unit or as a ratio ('63%', '29 عام', '2 : 3') is rewritten to its plain number first. An item whose
check still fails, or whose check value isn't in the key option, is appended to the owner list instead of imported."""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "backend" / "core"))
import verify  # noqa: E402


def plain(value):
    """'2 : 3' -> '2/3', '63%' -> '63', '29 عام' -> '29'; else None."""
    v = str(value).translate(verify.DIGITS)
    m = re.fullmatch(r"\s*(-?\d+(?:\.\d+)?)\s*:\s*(-?\d+(?:\.\d+)?)\s*", v)
    if m:
        return f"{m[1]}/{m[2]}"
    m = re.search(r"-?\d+(?:\.\d+)?(?:\s*/\s*\d+(?:\.\d+)?)?", v)
    return m[0].replace(" ", "") if m and m[0] != v.strip() else None


def triage(item, run=verify.check, matches=verify.matches_key):
    """-> (item, None) to import, or (item, why) for the owner."""
    c = item.get("check")
    if not c:
        return item, None
    if not run(c) and plain(c.get("value")) and run(dict(c, value=plain(c["value"]))):
        c = item["check"] = dict(c, value=plain(c["value"]))
    if not run(c):
        return item, f"the solver's maths check doesn't evaluate: {c.get('expr')} = {c.get('value')}"
    if not matches(c, item["options"][item["correct"][0]]):
        return item, f"the solver's maths check ({c['value']}) isn't the number in the key option"
    return item, None


def demo():
    fake = lambda c: c["value"] in ("63", "2/3", "5")  # stands in for SymPy
    it = lambda v, key="63%": {"options": [key, "b", "c", "d"], "correct": [0], "check": {"kind": "numeric", "expr": "x", "value": v}}
    same = lambda c, key: c["value"] != "5"  # stands in for verify.matches_key: 5 isn't in the key
    triage = lambda i, run: globals()["triage"](i, run, same)
    assert triage(it("63%"), fake) == ({**it("63"), "check": {"kind": "numeric", "expr": "x", "value": "63"}}, None)
    assert triage(it("2 : 3", "2 : 3"), fake)[1] is None and triage(it("7"), fake)[1].startswith("the solver's maths check doesn't")
    assert "isn't the number" in triage(it("5"), fake)[1]
    assert triage({"options": list("abcd"), "correct": [0]}, fake)[1] is None
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["demo"]:
        demo()
        sys.exit()
    src, kept_path, owner_path = sys.argv[1:4]
    kept, ask = [], []
    for line in open(src, encoding="utf-8"):
        if line.strip():
            item, why = triage(json.loads(line))
            (ask.append((item, why)) if why else kept.append(item))
    Path(kept_path).write_text("".join(json.dumps(i, ensure_ascii=False) + "\n" for i in kept), encoding="utf-8")
    with open(owner_path, "a", encoding="utf-8") as f:
        for i, why in ask:
            opts = "  ".join(f"({'أبجد'[k]}) {o}" for k, o in enumerate(i["options"]))
            f.write(f"- **{i['source']}**: {i['question']}\n  - {opts}\n  - why: {why}; the solver's answer is {'أبجد'[i['correct'][0]]}\n")
    print(f"{len(kept)} kept, {len(ask)} to the owner")
