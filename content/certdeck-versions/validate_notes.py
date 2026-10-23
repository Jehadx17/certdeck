"""Checks per-option notes against the versions: python3 validate_notes.py out/b1.json notes/b1.json [...pairs]

Notes file: [{"card_id": "...", "notes": [list-or-null, list-or-null]}], one entry per version, in order;
an MCQ version gets one note per option ("Correct." + optional why for correct ones, a short reason for wrong ones); others get null.
"""
import json
import sys

errors = []
pairs = sys.argv[1:]
for out, nf in zip(pairs[::2], pairs[1::2]):
    vers = {o["card_id"]: o["versions"] for o in json.load(open(out))}
    notes = {o["card_id"]: o["notes"] for o in json.load(open(nf))}
    for cid in vers.keys() ^ notes.keys():
        errors.append(f"{nf}: card {cid} missing on one side")
    for cid, vs in vers.items():
        ns = notes.get(cid)
        if ns is None:
            continue
        if len(ns) != len(vs):
            errors.append(f"{cid}: {len(vs)} versions, {len(ns)} note lists")
            continue
        for n, (v, note) in enumerate(zip(vs, ns)):
            where = f"{cid} v{n + 2}"
            if v["type"] != "mcq":
                if note is not None:
                    errors.append(f"{where}: not MCQ, notes must be null")
                continue
            if not isinstance(note, list) or len(note) != len(v["options"]):
                errors.append(f"{where}: needs {len(v['options'])} notes")
                continue
            for i, s in enumerate(note):
                ok = isinstance(s, str) and s.strip()
                if not ok or len(s) > 300:
                    errors.append(f"{where} option {i}: empty or over 300 chars")
                elif (i in v["correct"]) != s.startswith("Correct"):
                    errors.append(f"{where} option {i}: 'Correct' must start exactly the correct options' notes")
print("\n".join(errors) or "no errors")
sys.exit(1 if errors else 0)
