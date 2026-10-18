"""Image quizzes (the question is a photo posted just before a «.» poll whose options are أ ب ج د) -> candidates.
Usage: python3 -I quiz_images.py <channel.jsonl> <img dir with <id>-<k>.jpg> <out.jsonl>
The photo is the nearest earlier photo-only post (at most 3 posts back) not already taken by another poll. Reposts of
the same image (same bytes) are one candidate with votes pooled. Solving reads the image (SOLVE-IMAGE.md)."""
import collections
import hashlib
import json
import re
import sys
from pathlib import Path


def pair(rows, have, also=frozenset()):
    """rows sorted by id; have(id) -> image path or None; also: ids of text polls whose figure is in the photo before
    them. Returns [(poll row, image path)]."""
    out, used = [], set()
    by_id = {r["id"]: r for r in rows}
    for r in rows:
        p = r.get("poll")
        if not p or len(p["options"]) != 4 or (len(re.sub(r"\W", "", p["question"])) >= 8 and r["id"] not in also):
            continue
        for back in (1, 2, 3):
            q = by_id.get(r["id"] - back)
            if q and q.get("poll"):
                break  # another poll in between: this photo is not ours
            if q and q["id"] not in used and have(q["id"]):
                used.add(q["id"])
                out.append((r, have(q["id"])))
                break
    return out


def build(src, img, chan, also=frozenset()):
    rows = sorted((json.loads(l) for l in open(src, encoding="utf-8")), key=lambda r: r["id"])
    have = lambda i: next((str(f) for f in sorted(Path(img).glob(f"{i}-*.jpg"))[:1]), None)
    groups = collections.defaultdict(list)
    for r, f in pair(rows, have, also):
        groups[hashlib.md5(Path(f).read_bytes()).hexdigest()].append((r, f))
    out = []
    for g in groups.values():
        (r, f) = min(g, key=lambda x: x[0]["id"])
        vote = [round(sum(x["poll"]["options"][k]["pct"] for x, _ in g) / len(g)) for k in range(4)]
        out.append({"cid": f"{chan}-{r['id']}", "image": f, "question": f"[image {Path(f).name}]",
                    **({"text": r["poll"]["question"]} if r["id"] in also else {}),
                    "options": [o["text"] for o in r["poll"]["options"]], "vote": vote,
                    "posts": sorted(x["id"] for x, _ in g), "other_versions": 0, "source": f"{'mezla' if chan.startswith('Mezla') else 'tg'}:{chan}/{r['id']}"})
    return sorted(out, key=lambda c: c["posts"][0])


def demo():
    poll = lambda i: {"id": i, "poll": {"question": ".", "options": [{"text": t, "pct": 25} for t in "أبجد"]}}
    rows = [{"id": 1}, poll(2), {"id": 3}, {"id": 4}, poll(5), poll(6), {"id": 7}, {"id": 8}, poll(9)]
    have = lambda i: f"{i}.jpg" if i in (1, 3, 4, 7) else None  # 8 has no saved image
    got = [(r["id"], f) for r, f in pair(rows, have)]
    assert got == [(2, "1.jpg"), (5, "4.jpg"), (9, "7.jpg")], got  # 6 has a poll right before it: no photo
    rows[1]["poll"]["question"] = "ما مساحة الشكل المقابل؟"  # a text poll: paired only when asked for
    assert [r["id"] for r, _ in pair(rows, have)] == [5, 9] and [r["id"] for r, _ in pair(rows, have, {2})] == [2, 5, 9]
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["demo"]:
        demo()
    else:
        src, img, dst = sys.argv[1:4]  # optional 4th: a candidates file whose text polls need the photo before them
        also = {int(json.loads(l)["cid"].rsplit("-", 1)[1]) for l in open(sys.argv[4], encoding="utf-8")} if sys.argv[4:] else set()
        c = build(src, img, Path(src).stem, also)
        Path(dst).write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in c), encoding="utf-8")
        print(len(c), "image candidates")
