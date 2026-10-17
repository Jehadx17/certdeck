"""Blind solves + candidates -> pack items and the owner's question list.
Usage: python3 -I quiz_merge.py <candidates.jsonl> <outdir with out-*.jsonl> <items.jsonl> <owner.md>
An item is kept only when the solver called it "ok" AND its answer is the students' most-voted option. Everything else
(solver unsure, or solver and vote disagree) goes to the owner list with both answers; nothing is guessed."""
import collections
import glob
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from quiz_candidates import key  # noqa: E402

ITEM = ("question", "options", "explanation", "hint", "topic", "difficulty", "skill", "check")
LETTERS = "أبجد"


def merge(cands, solves):
    """A question posted in several versions (other options): when the versions that pass agree on the answer's
    text, the most-posted one is kept and the rest are repeats; when they disagree, all go to the owner."""
    items, ask, held, covered = [], [], collections.defaultdict(list), set()
    for c in cands:
        s = solves.get(c["cid"])
        top = c["key"] if "key" in c else max(range(4), key=lambda k: c["vote"][k])  # a sheet's printed key, else the vote
        said = f"the source's key is {LETTERS[top]}" if "key" in c else f"most students voted {LETTERS[top]} ({c['vote'][top]}%)"
        if not s:
            ask.append((c, None, "not solved yet"))
        elif s["status"] != "ok":
            ask.append((c, s, f"{s['status']}: {s.get('note', '')}"))
        elif s["correct"] != top:
            ask.append((c, s, f"solver says {LETTERS[s['correct']]}, {said}"))
        elif any(re.search(r"\([^)]*:[^)]*\)", o) for o in c["options"]):  # «أ : ب (ج : د)»: which pair got the votes?
            ask.append((c, s, "an option offers two pairs; which one is meant?"))
        elif any("(" in o and "(" not in t for o, t in zip(c["options"], s.get("options") or c["options"])):
            ask.append((c, s, "an option offered alternative wordings in brackets; which one is meant?"))
        elif c.get("other_versions"):
            held[qkey(c)].append((c, s))
        else:
            items.append(item(c, s))
            covered.add(qkey(c))
    for versions in held.values():
        if len({key((s.get("options") or c["options"])[s["correct"]]) for c, s in versions}) == 1:
            items.append(item(*max(versions, key=lambda v: (len(v[0]["posts"]), -v[0]["posts"][0]))))
            covered.add(qkey(versions[0][0]))
        else:
            ask += [(c, s, "the same question was posted with other options and the versions' answers differ") for c, s in versions]
    # a failed version of a kept question is a repeat, not a question for the owner
    ask = [a for a in ask if not (a[0].get("other_versions") and qkey(a[0]) in covered)]
    seen, unique = set(), []
    for i in items:  # the same image question posted twice is one item
        k = key(i["question"] + "".join(sorted(i["options"])) + i["options"][i["correct"][0]])
        if k not in seen:
            seen.add(k)
            unique.append(i)
    return unique, ask


def qkey(c):  # «يفهم من النص» under two passages is two questions
    return key(c.get("passage", "") + c["question"])


def item(c, s):
    return dict({k: s[k] for k in ITEM if k in s}, type="mcq", correct=[s["correct"]], source=c["source"])


def demo():
    c = lambda cid, vote, ov=0: {"cid": cid, "question": "q", "options": list("abcd"), "vote": vote, "posts": [5], "other_versions": ov,
                                 "source": "mezla:T/5"}
    s = lambda cid, st, k: {"cid": cid, "status": st, "correct": k, "question": "q", "options": list("abcd"), "topic": "t1", "note": "n"}
    items, ask = merge([c("T-1", [10, 70, 10, 10]), c("T-2", [70, 10, 10, 10]), c("T-3", [10, 70, 10, 10]), c("T-4", [0, 90, 5, 5], 1), c("T-5", [25] * 4)],
                       {x["cid"]: x for x in [s("T-1", "ok", 1), s("T-2", "ok", 1), s("T-3", "incomplete", None), dict(s("T-4", "ok", 1), question="q4")]})
    assert [i["source"] for i in items] == ["mezla:T/5"] * 2 and items[0]["correct"] == [1], items  # T-4: its one version passes
    assert [a[0]["cid"] for a in ask] == ["T-2", "T-3", "T-5"], ask
    two = dict(c("T-6", [0, 90, 5, 5]), options=["a", "هلال : بدر (غيوم : مطر)", "c", "d"])
    assert not merge([two], {"T-6": s("T-6", "ok", 1)})[0]
    alt = dict(c("T-7", [0, 90, 5, 5]), options=["a", "غير الرؤية (غير الوسيلة)", "c", "d"])
    assert not merge([alt], {"T-7": s("T-7", "ok", 1)})[0]  # the solver dropped the bracketed wording
    v1, v2, v3 = (dict(c(n, [0, 90, 5, 5], 1), posts=p) for n, p in (("V-1", [1]), ("V-2", [2, 3]), ("V-3", [4])))
    v3["options"] = ["x", "b", "y", "z"]  # another version, same answer text «b»
    kept, asked = merge([v1, v2, v3, dict(c("V-4", [10, 10, 70, 10], 1), posts=[5])],
                        {x: s(x, "ok", 1) for x in ("V-1", "V-2", "V-3")} | {"V-4": s("V-4", "ok", 1)})
    assert [i["source"] for i in kept] == ["mezla:T/5"] and len(kept) == 1 and not asked, (kept, asked)  # V-4 disagrees with its vote: a repeat
    v3["options"] = ["x", "y", "b", "z"]
    assert len(merge([v1, v3], {"V-1": s("V-1", "ok", 1), "V-3": dict(s("V-3", "ok", 1), options=v3["options"])})[1]) == 2  # «b» vs «y»
    twice = merge([c("D-1", [0, 90, 5, 5]), c("D-2", [0, 90, 5, 5])], {x: s(x, "ok", 1) for x in ("D-1", "D-2")})[0]
    assert len(twice) == 1, twice
    sheet = dict(c("S-q1", [0] * 4), key=2)  # a printed key overrides the vote
    assert merge([sheet], {"S-q1": s("S-q1", "ok", 2)})[0] and not merge([sheet], {"S-q1": s("S-q1", "ok", 2)})[1]
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["demo"]:
        demo()
        sys.exit()
    cand_path, outdir, items_path, owner_path = sys.argv[1:5]
    cands = [json.loads(l) for l in open(cand_path, encoding="utf-8")]
    solves = {}
    for f in sorted(glob.glob(f"{outdir}/out-*.jsonl")):
        for l in open(f, encoding="utf-8"):
            if l.strip():
                x = json.loads(l)
                solves[x["cid"]] = x
    cands = [c for c in cands if c["cid"] in solves]  # only the batches solved so far
    items, ask = merge(cands, solves)
    open(items_path, "w", encoding="utf-8").write("".join(json.dumps(i, ensure_ascii=False) + "\n" for i in items))
    with open(owner_path, "w", encoding="utf-8") as f:
        f.write(f"# Questions for you ({len(ask)} of {len(cands)})\nReply per id: the right letter, «fix: …», or «drop».\n\n")
        for c, s, why in ask:
            opts = "  ".join(f"({LETTERS[k]}) {o} [{c['vote'][k]}%]" for k, o in enumerate((s or {}).get("options") or c["options"]))
            mine = f"\n  - solver's working: {s.get('my_answer', '')}" if s else ""
            f.write(f"- **{c['cid']}** ({c['source']}): {(s or {}).get('question') or c['question']}\n  - {opts}\n  - why: {why}{mine}\n")
    print(f"{len(items)} items kept, {len(ask)} questions for the owner, of {len(cands)}")
