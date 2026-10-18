"""Candidates from several channels -> one file without questions already in the packs or seen in another channel, so
nothing is solved twice. Same question + same options (quiz_candidates.key) = a repeat; the newest post wins.
Usage: python3 -I quiz_dedupe.py <out.jsonl> <have.jsonl,...> <cand.jsonl>...   (have: items already imported)"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from quiz_candidates import key  # noqa: E402


def sig(r):
    return key(r["question"]), tuple(sorted(key(o) for o in r["options"]))


def dedupe(have, cands):
    seen = {sig(r) for r in have}
    out = []
    for c in sorted(cands, key=lambda c: c.get("seen") or "", reverse=True):
        if sig(c) not in seen:
            seen.add(sig(c))
            out.append(c)
    return out


def demo():
    have = [{"question": "ركوب : ترجل", "options": ["أ", "ب", "ج", "د"]}]
    cands = [{"cid": "A-1", "question": "ركوب: ترجّل", "options": ["ب", "أ", "ج", "د"], "seen": "2026-10-01"},  # imported
             {"cid": "A-2", "question": "سؤال", "options": ["1", "2", "3", "4"], "seen": "2026-01-01"},
             {"cid": "B-9", "question": "سؤال", "options": ["4", "3", "2", "1"], "seen": "2026-09-01"}]  # newer repost
    assert [c["cid"] for c in dedupe(have, cands)] == ["B-9"], dedupe(have, cands)
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["demo"]:
        demo()
    else:
        load = lambda f: [json.loads(l) for l in open(f, encoding="utf-8") if l.strip()]
        have = [r for f in sys.argv[2].split(",") if f for r in load(f)]
        cands = [c for f in sys.argv[3:] for c in load(f)]
        out = dedupe(have, cands)
        with open(sys.argv[1], "w", encoding="utf-8") as f:
            f.writelines(json.dumps(c, ensure_ascii=False) + "\n" for c in out)
        print(len(cands), "candidates ->", len(out), "new")
