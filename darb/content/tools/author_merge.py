"""Claude Code authoring: <dir>/items-*.jsonl + the blind solver's <dir>/solved-*.jsonl -> <slug>.jsonl (items the blind
solver answered the same, unflagged) and <slug>-dropped.jsonl (the rest, with why). Then run quiz_checks.py on <slug>.jsonl.
Usage: author_merge.py <dir> <slug>, after author_merge.py prep <dir>, which shuffles each item's options (writers
leave the key in a pattern) and writes the blind solver's input in a shuffled order, so position gives nothing away."""
import glob
import json
import random
import sys


def prep(items, rng):
    """Shuffle options in place (fixing correct); -> blind rows {n, question, options} in a shuffled order."""
    for x in items:
        order = list(range(len(x["options"])))
        rng.shuffle(order)
        x["options"] = [x["options"][i] for i in order]
        x["correct"] = sorted(order.index(c) for c in x["correct"])
    rows = [{"n": n, "question": x["question"], "options": x["options"]} for n, x in enumerate(items)]
    rng.shuffle(rows)
    return rows


def merge(items, solved):
    """-> (kept, dropped); an item is kept only if the blind pick equals its key and no flaw was reported."""
    by_n = {s["n"]: s for s in solved}
    kept, dropped = [], []
    for n, x in enumerate(items):
        s = by_n.get(n)
        why = ("not solved" if s is None else f"flawed: {s['flaw']}" if s.get("flaw") else
               f"blind solver picked {s.get('pick')}" if [s.get("pick")] != x["correct"] else None)
        (dropped.append(dict(x, why=why)) if why else kept.append(x))
    return kept, dropped


def demo():
    items = [{"correct": [1]}, {"correct": [2]}, {"correct": [0]}, {"correct": [3]}]
    solved = [{"n": 0, "pick": 1, "flaw": None}, {"n": 1, "pick": 0, "flaw": None}, {"n": 2, "pick": 0, "flaw": "two right"}]
    k, d = merge(items, solved)
    assert k == [items[0]] and [x["why"] for x in d] == ["blind solver picked 0", "flawed: two right", "not solved"]
    x = {"question": "q", "options": ["a", "b", "c", "d"], "correct": [2]}
    prep([x], random.Random(1))
    assert x["options"][x["correct"][0]] == "c" and sorted(x["options"]) == ["a", "b", "c", "d"]


if __name__ == "__main__":
    demo()
    d, slug = sys.argv[1], sys.argv[2]
    rd = lambda f: [json.loads(l) for l in open(f, encoding="utf-8") if l.strip()]
    w = lambda f, rows: open(f, "w", encoding="utf-8").write("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    if d == "prep":
        rng = random.Random()
        for f in sorted(glob.glob(f"{slug}/items-*.jsonl")):
            items = rd(f)
            blind = prep(items, rng)
            w(f, items)
            w(f.replace("/items-", "/blind-"), blind)
        sys.exit()
    kept, dropped = [], []
    for f in sorted(glob.glob(f"{d}/items-*.jsonl")):
        k, x = merge(rd(f), rd(f.replace("/items-", "/solved-")))
        kept += k
        dropped += x
    w(f"{d}/{slug}.jsonl", kept)
    w(f"{d}/{slug}-dropped.jsonl", dropped)
    print(len(kept), "kept,", len(dropped), "dropped")
