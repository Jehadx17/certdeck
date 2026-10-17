"""Telegram quiz posts (tgscrape JSONL) -> one candidate per distinct text question, for solving in Claude Code.
Usage: python3 -I quiz_candidates.py <channel.jsonl> <out.jsonl>
Same question + same options = one candidate (votes pooled over its reposts). Same question with different options is
kept apart and marked, so the solver sees each version. Image-only quizzes (the question is in a photo) are skipped."""
import collections
import json
import re
import sys
from pathlib import Path

MARKS = re.compile(r"[\u064B-\u0652\u0640]|[^\w\s:/()%.,،؟?\-+×÷=<>]")  # harakat, tatweel, emoji/markers


def clean(s):
    return re.sub(r"\s+", " ", MARKS.sub("", s.replace("\xa0", " "))).strip(" .")


def key(s):
    return re.sub(r"[\W_]+", "", clean(s)).replace("أ", "ا").replace("إ", "ا").replace("آ", "ا").replace("ة", "ه").replace("ى", "ي")


def build(src, chan):
    groups = collections.defaultdict(list)
    for line in open(src, encoding="utf-8"):
        x = json.loads(line)
        p = x.get("poll")
        if not p or len(key(p["question"])) < 8 or len(p["options"]) != 4:
            continue
        groups[(key(p["question"]), tuple(sorted(key(o["text"]) for o in p["options"])))].append(x)
    by_q = collections.Counter(q for q, _ in groups)
    out = []
    for (q, _), posts in groups.items():
        first = posts[0]["poll"]
        votes = collections.Counter()
        for x in posts:  # pool vote shares by option text (option order can change between reposts)
            for o in x["poll"]["options"]:
                votes[key(o["text"])] += o["pct"]
        out.append({"cid": f"{chan}-{min(x['id'] for x in posts)}", "question": clean(first["question"]),
                    "options": [clean(o["text"]) for o in first["options"]],
                    "vote": [round(votes[key(o["text"])] / len(posts)) for o in first["options"]],
                    "posts": sorted(x["id"] for x in posts), "other_versions": by_q[q] - 1,
                    "source": f"mezla:{chan}/{min(x['id'] for x in posts)}"})
    return sorted(out, key=lambda c: c["posts"][0])


def demo():
    import tempfile
    rows = [{"id": i, "poll": {"question": q, "options": [{"text": t, "pct": p} for t, p in o]}} for i, q, o in [
        (1, "🟢 ركوب : ترجل", [("أ : ب", 10), ("ج : د", 70), ("هـ : و", 10), ("ز : ح", 10)]),
        (2, "ركوب : ترجّل.", [("ج : د", 50), ("أ : ب", 30), ("هـ : و", 10), ("ز : ح", 10)]),  # repost, options reordered
        (3, "ركوب : ترجل", [("أ : ب", 25), ("ج : د", 25), ("هـ : و", 25), ("س : ش", 25)]),  # another version
        (4, ".", [("أ", 25), ("ب", 25), ("ج", 25), ("د", 25)])]]  # image-only
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        f.write("\n".join(json.dumps(r, ensure_ascii=False) for r in rows))
    c = build(f.name, "T")
    assert len(c) == 2 and c[0]["posts"] == [1, 2] and c[0]["vote"] == [20, 60, 10, 10] and c[0]["other_versions"] == 1, c
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["demo"]:
        demo()
    else:
        c = build(sys.argv[1], Path(sys.argv[1]).stem)
        Path(sys.argv[2]).write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in c), encoding="utf-8")
        print(len(c), "candidates;", sum(x["other_versions"] > 0 for x in c), "with other versions")
