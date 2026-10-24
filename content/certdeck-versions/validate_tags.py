# Checks tags/bN.json against in/bN.json (main checkout), vocab.json and existing.json. Prints OK or the problems.
import glob, json, os, re, sys

SRC = os.environ.get("SRC", "/home/jehad/Documents/Projects/learning/content/certdeck-versions")
vocab = set(json.load(open("tags/vocab.json")))
existing = {r["id"]: r["tags"] for r in json.load(open("tags/existing.json"))}
errs = []
for f in sorted(glob.glob(f"{SRC}/in/b*.json")):
    b = os.path.basename(f)
    got = {r["card_id"]: r["tags"] for r in json.load(open(f"tags/{b}"))}
    for c in json.load(open(f)):
        tags = got.get(c["id"])
        if tags is None:
            errs.append(f"{b} {c['id']}: missing"); continue
        if not 1 <= len(tags) <= 8 or len(set(tags)) != len(tags):
            errs.append(f"{b} {c['id']}: {len(tags)} tags or duplicates")
        errs += [f"{b} {c['id']}: '{t}' not in vocab" for t in tags if t not in vocab]
        errs += [f"{b} {c['id']}: lost '{t}'" for t in existing.get(c["id"], []) if t not in tags]
errs += [f"vocab: bad format '{t}'" for t in vocab if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", t)]
print("\n".join(errs) or "OK")
sys.exit(bool(errs))
