"""AI diagram specs -> PNG with Graphviz and the official AWS / Kubernetes icons in core/icons.

Specs come from the model (and indirectly from imported card text), so every label is escaped and only our own
icon files are ever referenced: nothing in a spec can add Graphviz attributes or point at other files.
"""
import html
import subprocess
import textwrap
from pathlib import Path

ICONS = Path(__file__).parent / "icons"
ICON_KEYS = sorted(str(p.relative_to(ICONS).with_suffix("")) for p in ICONS.rglob("*.png"))
_ICON_SET = set(ICON_KEYS)

# AWS architecture-diagram conventions for group boxes: (border, fill, dashed). Kubernetes uses its own blue.
GROUPS = {
    "aws_cloud": ("#232F3E", "#FFFFFF", False),
    "region": ("#00A4A6", "#FFFFFF", True),
    "az": ("#147EBA", "#FFFFFF", True),
    "vpc": ("#8C4FFF", "#FFFFFF", False),
    "public_subnet": ("#7AA116", "#F2F6E8", False),
    "private_subnet": ("#00A4A6", "#E6F6F7", False),
    "security_group": ("#DD344C", "#FFFFFF", False),
    "auto_scaling": ("#ED7100", "#FFFFFF", True),
    "k8s_cluster": ("#326CE5", "#FFFFFF", False),
    "namespace": ("#326CE5", "#EEF3FC", True),
    "box": ("#7D8998", "#F7F8F9", False),
}
LIMITS = {"groups": 10, "nodes": 16, "edges": 24, "columns": 5, "rows": 10}
FONT = "DejaVu Sans"


def icon_list():
    """Icon keys grouped by folder, for the prompt: 'aws/compute: ec2, lambda, ...'."""
    folders = {}
    for k in ICON_KEYS:
        folder, name = k.rsplit("/", 1)
        folders.setdefault(folder, []).append(name)
    return "\n".join(f"{f}: {', '.join(names)}" for f, names in folders.items())


def _q(s):
    """DOT quoted string. Backslashes are doubled so escapes like \\N or \\l can't do anything."""
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def _wrap(s, width, limit=80):
    return textwrap.wrap(" ".join(str(s).split())[:limit], width) or [""]


def _table(t):
    cols = [str(c) for c in (t.get("columns") or [])][:LIMITS["columns"]]
    rows = [[str(c) for c in r][:len(cols)] for r in (t.get("rows") or [])][:LIMITS["rows"]]
    if len(cols) < 2 or not rows:
        return None

    def cell(text, bg, bold=False, color="#16191F"):
        body = "<BR/>".join(html.escape(line) for line in _wrap(text, 22, 140)) or "&#160;"  # Graphviz rejects <B></B>
        if bold:
            body = f"<B>{body}</B>"
        return f'<TD BGCOLOR="{bg}" ALIGN="LEFT" BALIGN="LEFT"><FONT COLOR="{color}">{body}</FONT></TD>'

    head = "".join(cell(c, "#232F3E", True, "#FFFFFF") for c in cols)
    body = "".join("<TR>" + "".join(cell(c, "#FFFFFF" if i % 2 else "#F2F3F3", j == 0) for j, c in enumerate(r))
                   + "</TR>" for i, r in enumerate(rows))
    return (f'<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0" CELLPADDING="8" COLOR="#D5DBDB">'
            f"<TR>{head}</TR>{body}</TABLE>>")


def to_dot(spec):
    """Spec -> DOT source. Invalid references are dropped rather than failing the whole diagram."""
    groups = {g["id"]: g for g in (spec.get("groups") or [])[:LIMITS["groups"]] if g.get("id")}
    nodes = {n["id"]: n for n in (spec.get("nodes") or [])[:LIMITS["nodes"]] if n.get("id")}

    def parent(g):  # parent group id, or None when it's missing or the chain loops
        seen, p = {g}, groups[g].get("parent")
        while p in groups:
            if p in seen:
                return None
            seen.add(p)
            p = groups[p].get("parent")
        return groups[g].get("parent") if groups[g].get("parent") in groups else None

    children = {}
    for g in groups:
        children.setdefault(parent(g), []).append(g)
    members = {}
    for nid, n in nodes.items():
        members.setdefault(n.get("group") if n.get("group") in groups else None, []).append(nid)

    def first_node(g):  # an edge to a group is drawn to one of its nodes, clipped at the group's border
        return next(iter(members.get(g, [])), None) or next(filter(None, map(first_node, children.get(g, []))), None)

    ids = {k: f"n{i}" for i, k in enumerate(nodes)}
    out = ["digraph G {",
           f"graph [rankdir={'LR' if spec.get('direction') == 'LR' else 'TB'} bgcolor=\"#FFFFFF\" pad=0.4 "
           f"nodesep=0.6 ranksep=0.7 compound=true fontname={_q(FONT)} fontsize=20 fontcolor=\"#16191F\" "
           f"labelloc=t size=\"9,14\" label={_q(' '.join(str(spec.get('title') or '').split())[:80])}];",
           f"node [fontname={_q(FONT)} fontsize=13 fontcolor=\"#16191F\"];",
           f"edge [fontname={_q(FONT)} fontsize=12 fontcolor=\"#545B64\" color=\"#545B64\" arrowsize=0.8];"]

    def node(nid):
        n = nodes[nid]
        icon = n.get("icon") if n.get("icon") in _ICON_SET else None
        bold = "#ED7100" if n.get("highlight") else "#16191F"
        if icon:
            lines = _wrap(n.get("label"), 18)
            return (f"{ids[nid]} [shape=none fixedsize=true width=1.3 height={1.75 + 0.25 * (len(lines) - 1)} "
                    f"imagescale=true labelloc=b image={_q(ICONS / (icon + '.png'))} fontcolor=\"{bold}\" "
                    f"label={_q(chr(10).join(lines))}];")
        fill, border = ("#FFF4E5", "#ED7100") if n.get("highlight") else ("#F2F3F3", "#7D8998")
        return (f"{ids[nid]} [shape=box style=\"rounded,filled\" fillcolor=\"{fill}\" color=\"{border}\" "
                f"penwidth={2 if n.get('highlight') else 1} margin=\"0.2,0.1\" "
                f"label={_q(chr(10).join(_wrap(n.get('label'), 22)))}];")

    def cluster(g, depth):
        border, fill, dashed = GROUPS.get(groups[g].get("kind"), GROUPS["box"])
        pad = "  " * depth
        out.append(f"{pad}subgraph cluster_{list(groups).index(g)} {{")
        out.append(f"{pad}  graph [label={_q(' '.join(str(groups[g].get('label') or '').split())[:60])} "
                   f"labeljust=l fontsize=14 fontcolor=\"{border}\" color=\"{border}\" fillcolor=\"{fill}\" "
                   f"style=\"rounded,filled{',dashed' if dashed else ''}\" penwidth=2 margin=14];")
        for c in children.get(g, []):
            cluster(c, depth + 1)
        out.extend(pad + "  " + node(nid) for nid in members.get(g, []))
        out.append(pad + "}")

    for g in children.get(None, []):
        cluster(g, 1)
    out.extend("  " + node(nid) for nid in members.get(None, []))
    if spec.get("table") and (table := _table(spec["table"])):
        out.append(f"  t0 [shape=plain label={table}];")

    for e in (spec.get("edges") or [])[:LIMITS["edges"]]:
        ends = []
        for key in ("source", "target"):
            ref = e.get(key)
            if ref in nodes:
                ends.append((ids[ref], None))
            elif ref in groups and (n := first_node(ref)):
                ends.append((ids[n], f"cluster_{list(groups).index(ref)}"))
        if len(ends) != 2 or ends[0][0] == ends[1][0]:
            continue
        (a, ga), (b, gb) = ends
        attrs = [f"label={_q(' '.join(str(e.get('label') or '').split())[:40])}"]
        attrs += ["style=dashed"] * bool(e.get("dashed")) + ["dir=both"] * bool(e.get("both"))
        attrs += [f"ltail={ga}"] * bool(ga) + [f"lhead={gb}"] * bool(gb)
        out.append(f"  {a} -> {b} [{' '.join(attrs)}];")
    out.append("}")
    return "\n".join(out)


def render(spec):
    """Spec -> PNG bytes, or None when the spec has nothing to draw."""
    if not (spec.get("nodes") or spec.get("table")):
        return None
    r = subprocess.run(["dot", "-Tpng", "-Gdpi=144"], input=to_dot(spec).encode(), capture_output=True, timeout=30)
    if r.returncode != 0 or not r.stdout.startswith(b"\x89PNG"):
        raise ValueError(f"graphviz failed: {r.stderr.decode(errors='replace')[:300]}")
    return r.stdout
