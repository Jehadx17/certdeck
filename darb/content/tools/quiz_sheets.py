"""A batch of question images -> a few labelled contact sheets, so a solver reads ~8 pages instead of 40 images
(the image tokens are the same; the saving is in the turns around them).
Usage: python3 -I quiz_sheets.py <in.jsonl> <outdir>   (writes outdir/sheet-NN.png, prints how many)"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

WIDTH, MAX_H, BAR = 800, 1500, 26  # under the reader's 1568px edge, so nothing is downscaled


def pages(items, open_img):
    """items: [(label, path)] -> [[(label, image)]], each page at most MAX_H tall."""
    out, h = [[]], 0
    for label, path in items:
        im = open_img(path)
        if im.width > WIDTH:
            im = im.resize((WIDTH, round(im.height * WIDTH / im.width)))
        if out[-1] and h + BAR + im.height > MAX_H:
            out.append([])
            h = 0
        out[-1].append((label, im))
        h += BAR + im.height
    return [p for p in out if p]


def render(page):
    sheet = Image.new("RGB", (WIDTH, sum(BAR + im.height for _, im in page)), "white")
    draw, font, y = ImageDraw.Draw(sheet), ImageFont.load_default(size=20), 0
    for label, im in page:
        draw.rectangle((0, y, WIDTH, y + BAR - 2), fill="black")
        draw.text((6, y + 2), label, fill="yellow", font=font)
        sheet.paste(im.convert("RGB"), (0, y + BAR))
        y += BAR + im.height
    return sheet


def demo():
    tall = lambda p: Image.new("RGB", (1600, 800) if p == "wide" else (800, 400))
    got = pages([("a", "x"), ("b", "x"), ("c", "x"), ("d", "wide")], tall)
    assert [[label for label, _ in p] for p in got] == [["a", "b", "c"], ["d"]], got  # 3×426 fits, a 4th doesn't
    assert got[1][0][1].size == (800, 400) and render(got[0]).size == (800, 3 * 426)
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["demo"]:
        demo()
        sys.exit()
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    dst.mkdir(parents=True, exist_ok=True)
    rows = [json.loads(line) for line in src.read_text(encoding="utf-8").splitlines() if line.strip()]
    ps = pages([(r["cid"], r["image"]) for r in rows], Image.open)
    for k, p in enumerate(ps):
        render(p).save(dst / f"sheet-{k:02d}.png", optimize=True)
    print(len(ps), "sheets for", len(rows), "images")
