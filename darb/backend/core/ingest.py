"""Course material on disk: resumable uploads, type checks, conversion to one PDF, pages.

Layout: <DARB_UPLOAD_DIR>/<account id>/<material id>/
  <n>.part            file n while it uploads (chunks appended at the offset the server reports)
  <n>.<ext>           file n once its sha256 matched
  material.pdf        every page of the material in order (PDFs and photos)

Everything uploaded is untrusted: types come from magic bytes (never the name), and sizes and pages are capped.
"""
import hashlib
import io
import logging
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from django.conf import settings

from .auth import ApiError
from .models import docs, now_ms, save_docs

log = logging.getLogger(__name__)

UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
CHUNK_MAX = 8 * 1024 * 1024
FILE_MAX = 30 * 1024 * 1024  # strict limits for subscribers' uploads (docs/GOAL-DARB.md)
FILES_MAX = 20  # files per material (photos)
PAGES_MAX = 60  # pages per material
MIN_FREE = 3 * 1024 ** 3  # keep 3 GB free on the server's disk
KINDS = ("book", "slides", "notes", "photos", "syllabus", "past_exam")
IMAGES = {"png", "jpg", "webp", "gif"}


def material_dir(user, material_id):
    if not UUID.fullmatch(material_id or ""):
        raise ApiError(400, "material id must be a lowercase UUID")
    return settings.DARB_UPLOAD_DIR / str(user.id) / material_id


def _n(n):
    if not (isinstance(n, int) and 0 <= n < FILES_MAX):
        raise ApiError(400, f"file number must be 0..{FILES_MAX - 1}")
    return n


def files(user, material_id):
    """{n: path} of the finished uploads, in order."""
    d = material_dir(user, material_id)
    out = {}
    for p in d.glob("[0-9]*.*") if d.exists() else []:
        if p.suffix != ".part" and p.stem.isdigit():
            out[int(p.stem)] = p
    return dict(sorted(out.items()))


# ---------- uploads ----------

def upload_chunk(user, material_id, n, offset, data):
    """Appends a chunk at [offset], which must equal what the server has (so a resumed upload never duplicates)."""
    part = material_dir(user, material_id) / f"{_n(n)}.part"
    size = part.stat().st_size if part.exists() else 0
    if offset != size:
        raise ApiError(409, f"offset must be {size}")
    if not data or len(data) > CHUNK_MAX:
        raise ApiError(400, f"chunk must be 1 byte to {CHUNK_MAX // 1024 // 1024} MB")
    if size + len(data) > FILE_MAX:
        raise ApiError(413, f"files are limited to {FILE_MAX // 1024 // 1024} MB")
    part.parent.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(part.parent).free < MIN_FREE + len(data):
        raise ApiError(507, "the server is low on disk space; ask the owner")
    with part.open("ab") as f:
        f.write(data)
    return size + len(data)


def upload_status(user, material_id, n):
    d = material_dir(user, material_id)
    part = d / f"{_n(n)}.part"
    done = files(user, material_id).get(n)
    return {"size": (done or part).stat().st_size if (done or part.exists()) else 0, "done": done is not None}


def sniff(path):
    """File type from its first bytes: an extension from IMAGES|{'pdf'}, or None."""
    with open(path, "rb") as f:
        head = f.read(64)
    if head.startswith(b"%PDF"):
        return "pdf"
    if head.startswith(b"\x89PNG"):
        return "png"
    if head.startswith(b"\xff\xd8\xff"):
        return "jpg"
    if head.startswith(b"GIF8"):
        return "gif"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "webp"
    return None


def upload_done(user, material_id, n, sha256):
    """Verifies the finished upload and keeps it under its real type."""
    d = material_dir(user, material_id)
    part = d / f"{_n(n)}.part"
    if not part.exists():
        if n in files(user, material_id):
            return {"ok": True, "type": files(user, material_id)[n].suffix[1:]}
        raise ApiError(404, "nothing uploaded for this file")
    h = hashlib.sha256()
    with part.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    if h.hexdigest() != (sha256 or "").lower():
        part.unlink()
        raise ApiError(400, "upload corrupted (sha256 mismatch), please upload this file again")
    kind = sniff(part)
    if kind not in IMAGES | {"pdf"}:
        part.unlink()
        raise ApiError(415, "unsupported file: use PDF or photos (JPEG/PNG/WebP)")
    os.replace(part, d / f"{n}.{kind}")
    return {"ok": True, "type": kind}


# ---------- conversion ----------

def image_to_pdf(src):
    from PIL import Image, ImageOps

    with Image.open(src) as im:
        im = ImageOps.exif_transpose(im).convert("RGB")
        im.thumbnail((2000, 2000))
        buf = io.BytesIO()
        im.save(buf, "PDF", resolution=150, quality=88)
        return buf.getvalue()


def build_pdf(user, material_id):
    """Merges every document/photo file of a material into material.pdf; returns its page count."""
    from pypdf import PdfReader, PdfWriter

    writer = PdfWriter()
    for n, path in files(user, material_id).items():
        ext = path.suffix[1:]
        if ext == "pdf":
            data = path.read_bytes()
        elif ext in IMAGES:
            data = image_to_pdf(path)
        else:
            raise ApiError(422, f"file {n + 1} isn't a document or photo")
        reader = PdfReader(io.BytesIO(data))
        if reader.is_encrypted and not reader.decrypt(""):
            raise ApiError(422, f"file {n + 1} is a password-protected PDF")
        writer.append(reader)
    if not writer.pages:
        raise ApiError(422, "no pages found")
    if len(writer.pages) > PAGES_MAX:
        raise ApiError(422, f"too many pages ({len(writer.pages)}): upload at most {PAGES_MAX} pages at a time")
    out = material_dir(user, material_id) / "material.pdf"
    with open(out.with_suffix(".tmp"), "wb") as f:
        writer.write(f)
    os.replace(out.with_suffix(".tmp"), out)
    return len(writer.pages)


def material_pdf(user, material_id):
    p = material_dir(user, material_id) / "material.pdf"
    if not p.exists():
        raise ApiError(409, "this material isn't processed yet")
    return p


def page_pdfs(path, pages):
    """{page number (1-based): single-page PDF bytes} for [pages], so the model can cite exact pages."""
    from pypdf import PdfReader, PdfWriter

    reader = PdfReader(str(path))
    out = {}
    for p in pages:
        if 1 <= p <= len(reader.pages):
            w = PdfWriter()
            w.add_page(reader.pages[p - 1])
            buf = io.BytesIO()
            w.write(buf)
            out[p] = buf.getvalue()
    return out


def page_chars(path):
    """Characters of text on each page (what the density-based cost estimate uses)."""
    from pypdf import PdfReader

    out = []
    for page in PdfReader(str(path)).pages:
        try:
            out.append(len("".join((page.extract_text() or "").split())))
        except Exception:  # noqa: BLE001
            out.append(0)
    return out


def page_texts(path, limit=200):
    """First [limit] characters of each page's text layer (a cheap digest for mapping big books)."""
    from pypdf import PdfReader

    reader = PdfReader(str(path))
    texts = []
    for page in reader.pages:
        try:
            t = " ".join((page.extract_text() or "").split())
        except Exception:  # noqa: BLE001 - a broken page just has no digest
            t = ""
        texts.append(t[:limit])
    return texts


def page_png(user, material_id, page):
    """A rendered page (poppler's pdftoppm, cached next to the material)."""
    pdf = material_pdf(user, material_id)
    out = pdf.parent / f"page-{int(page)}.png"
    if not out.exists():
        tmp = pdf.parent / f".page-{int(page)}"
        try:
            subprocess.run(["pdftoppm", "-png", "-r", "110", "-f", str(page), "-l", str(page), "-singlefile", str(pdf), str(tmp)],
                           capture_output=True, timeout=60, check=True)
        except (FileNotFoundError, subprocess.TimeoutExpired, subprocess.CalledProcessError):
            raise ApiError(404, "page not available")
        os.replace(tmp.with_suffix(".png"), out)
    return out


# ---------- ingest status (backend-owned docs: ingest-<material id>) ----------

def ingest_id(material_id):
    return f"ingest-{material_id}"


def get_ingest(user, material_id):
    d = docs(user).filter(doc_id=ingest_id(material_id), deleted=False).first()
    return dict(d.data) if d else None


def set_ingest(user, material_id, **fields):
    data = {**(get_ingest(user, material_id) or {"material_id": material_id}), **fields}
    save_docs(user, [{"id": ingest_id(material_id), "kind": "ingest", "data": data, "updated_at": now_ms(),
                      "deleted": False}])
    return data


def delete_account_files(user):
    shutil.rmtree(settings.DARB_UPLOAD_DIR / str(user.id), ignore_errors=True)
