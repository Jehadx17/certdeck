"""Pages through a public Telegram channel's web preview (t.me/s/<channel>?before=N) into JSONL.
Usage: python3 -I tgscrape.py <channel> <out.jsonl>   (resumes: skips posts already in the file)"""
import html
import json
import re
import sys
import time
import urllib.request

def clean(x):
    return html.unescape(re.sub(r"<[^>]+>", "", re.sub(r"<br\s*/?>", "\n", x))).strip()


def poll(b):
    """A quiz/poll: question, type and options with their vote share (the web preview never shows the key)."""
    q = re.search(r'tgme_widget_message_poll_question">(.*?)</div>', b, re.S)
    if not q:
        return None
    opts = re.findall(r'poll_option_percent">(\d+)%</div>.*?poll_option_text">(.*?)</div>', b, re.S)
    t = re.search(r'tgme_widget_message_poll_type">(.*?)</div>', b, re.S)
    return {"question": clean(q.group(1)), "type": clean(t.group(1)) if t else "",
            "options": [{"text": clean(o), "pct": int(p)} for p, o in opts]}


chan, out = sys.argv[1], sys.argv[2]
seen = set()
try:
    seen = {json.loads(l)["id"] for l in open(out, encoding="utf-8")}
except FileNotFoundError:
    pass
before, empty = None, 0
with open(out, "a", encoding="utf-8") as f:
    while True:
        url = f"https://t.me/s/{chan}" + (f"?before={before}" if before else "")
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        for attempt in range(5):
            try:
                page = urllib.request.urlopen(req, timeout=30).read().decode("utf-8")
                break
            except Exception as e:  # noqa: BLE001 - retry network errors
                time.sleep(5 * (attempt + 1))
        else:
            sys.exit(f"gave up at before={before}")
        blocks = re.split(r'(?=<div class="tgme_widget_message_wrap)', page)[1:]
        ids = []
        for b in blocks:
            m = re.search(r'data-post="[^/]+/(\d+)"', b)
            if not m:
                continue
            pid = int(m.group(1))
            ids.append(pid)
            if pid in seen:
                continue
            text = re.search(r'tgme_widget_message_text[^>]*>(.*?)</div>', b, re.S)
            text = html.unescape(re.sub(r"<br\s*/?>", "\n", text.group(1)) if text else "")
            text = re.sub(r"<[^>]+>", "", text).strip()
            rec = {"id": pid, "date": (re.search(r'datetime="([^"]+)"', b) or [None, None])[1], "text": text,
                   "photos": re.findall(r"background-image:url\('([^']+)'\)", b),
                   "files": [html.unescape(x).strip() for x in re.findall(r'tgme_widget_message_document_title[^>]*>([^<]*)<', b)],
                   "links": sorted(set(re.findall(r'href="(https://t\.me/[^"]+)"', b))),
                   "poll": poll(b)}
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            seen.add(pid)
        f.flush()
        if not ids or min(ids) <= 1:
            empty += 1
            if empty >= 3 or (ids and min(ids) <= 1):
                break
            before = (before or 2) - 20
        else:
            before = min(ids)
        print(f"before={before} total={len(seen)}", flush=True)
        time.sleep(1.5)
print(f"done: {len(seen)} posts")
