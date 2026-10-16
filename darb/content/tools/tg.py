"""Telegram download for Darb sources, on the owner's own account (session stays in ~/.config/darb-tg, never in git).
  tg.py login                 first run: asks api_id/api_hash (my.telegram.org) + phone + code
  tg.py list <channel>        every file in the channel with its size -> <out>/<channel>-files.tsv
  tg.py get <channel> [ext..] downloads files (default: pdf) into <out>/<channel>/, skips ones already there and
                              repeats (same size); with TG_SERVER=host:path each file is moved there"""
import asyncio
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

from telethon import TelegramClient

HOME = Path(__file__).resolve().parent
OUT = Path("/home/jehad/Documents/Projects/learning/darb/content/sources/qudurat/mezla")
MIN_FREE = 1.0e9  # stop before the disk fills (laptop disk is nearly full)
SERVER = os.environ.get("TG_SERVER")  # e.g. root@169.58.7.222:/opt/darb/sources/mezla


def creds():
    f = HOME / "api.json"
    if not f.exists():
        d = {"api_id": int(input("api_id: ")), "api_hash": input("api_hash: ").strip()}
        f.write_text(json.dumps(d))
        os.chmod(f, 0o600)
    return json.loads(f.read_text())


def name(m):
    return m.file.name or f"{m.id}{m.file.ext or ''}"


async def main(cmd, chan=None, *exts):
    c = creds()
    async with TelegramClient(str(HOME / "session"), c["api_id"], c["api_hash"]) as tg:
        os.chmod(HOME / "session.session", 0o600)
        if cmd == "login":
            print("signed in as", (await tg.get_me()).first_name)
            return
        OUT.mkdir(parents=True, exist_ok=True)
        if cmd == "list":
            rows = [f"{m.id}\t{m.date:%Y-%m-%d}\t{m.file.size}\t{name(m)}"
                    async for m in tg.iter_messages(chan) if m.document]
            (OUT / f"{chan}-files.tsv").write_text("id\tdate\tbytes\tname\n" + "\n".join(rows) + "\n")
            print(len(rows), "files,", sum(int(r.split("\t")[2]) for r in rows) / 1e6, "MB")
        elif cmd == "get":
            exts = {"." + e.lower().lstrip(".") for e in (exts or ["pdf"])}
            d = OUT / chan
            d.mkdir(exist_ok=True)
            sizes = set()
            if SERVER:
                host, path = SERVER.split(":")
                subprocess.run(["ssh", host, f"mkdir -p {path}/{chan}"], check=True)
                got = subprocess.run(["ssh", host, f"cd {path}/{chan} && stat -c %s * 2>/dev/null"], capture_output=True, text=True).stdout
                sizes = {int(x) for x in got.split()}
            async for m in tg.iter_messages(chan):
                if not m.document or (m.file.ext or "").lower() not in exts:
                    continue
                dest = d / f"{m.id}-{name(m)}"
                if dest.exists() and dest.stat().st_size == m.file.size:
                    continue
                if shutil.disk_usage(OUT).free - m.file.size < MIN_FREE:
                    sys.exit(f"stopped: disk nearly full at post {m.id}")
                if m.file.size in sizes:  # the same file posted again
                    continue
                sizes.add(m.file.size)
                await m.download_media(file=str(dest))
                if SERVER:  # the laptop disk is nearly full: keep the files on Darb's server, not here
                    subprocess.run(["scp", "-q", str(dest), f"{SERVER}/{chan}/"], check=True)
                    dest.unlink()
                print(m.id, dest.name, m.file.size, flush=True)


asyncio.run(main(*sys.argv[1:]))
