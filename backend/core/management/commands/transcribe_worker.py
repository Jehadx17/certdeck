import json
import logging
import os
import time

from django.conf import settings
from django.core.management.base import BaseCommand
from django.db import close_old_connections

from core import ingest
from core.models import Doc

log = logging.getLogger(__name__)


def transcribe(model, user, material_id):
    """Every audio/video file of the material, in order -> transcript.json [[start, end, text]]; then the audio
    is deleted. faster-whisper decodes the files itself (PyAV), so no ffmpeg is needed."""
    audio = list(ingest.files(user, material_id).values())
    segments, offset, last_report = [], 0.0, 0.0
    for i, path in enumerate(audio):
        parts, info = model.transcribe(str(path), vad_filter=True, beam_size=1, condition_on_previous_text=False)
        for seg in parts:
            segments.append([round(offset + seg.start, 1), round(offset + seg.end, 1), seg.text.strip()])
            if time.monotonic() - last_report > 20:
                last_report = time.monotonic()
                done = (i + min(1.0, seg.end / max(info.duration, 1))) / len(audio)
                ingest.set_ingest(user, material_id, progress=round(min(0.99, done), 2), language=info.language)
        offset += info.duration
    segments = [s for s in segments if s[2]]
    if not segments:
        raise ValueError("no speech found")
    out = ingest.material_dir(user, material_id) / "transcript.json"
    out.write_text(json.dumps(segments, ensure_ascii=False))
    for path in audio:  # a verified transcript exists: the (large) audio isn't needed any more
        path.unlink(missing_ok=True)
    return round(offset / 60, 1)


class Command(BaseCommand):
    help = "Transcribes lecture recordings with faster-whisper (certdeck-whisper: CPU- and memory-limited, one at a time)."

    def handle(self, *args, **options):
        from faster_whisper import WhisperModel

        while True:
            close_old_connections()
            job = next((d for d in Doc.objects.filter(kind="ingest", deleted=False).select_related("user")
                        if d.data.get("status") == "transcribing"), None)
            if not job:
                time.sleep(15)
                continue
            mid, t0 = job.data["material_id"], time.monotonic()
            try:
                # Loaded per recording and freed after: idle, this container holds no model in the shared server's RAM.
                model = WhisperModel(settings.CERTDECK_WHISPER_MODEL, device="cpu", compute_type="int8",
                                     cpu_threads=int(os.environ.get("WHISPER_THREADS", "2")),
                                     download_root=os.environ.get("WHISPER_MODELS", "/models"))
                minutes = transcribe(model, job.user, mid)
                del model
                ingest.set_ingest(job.user, mid, status="transcribed", minutes=minutes, progress=1,
                                  transcribe_seconds=round(time.monotonic() - t0))
                log.info("transcribed %s: %.1f min of audio in %.0f s", mid, minutes, time.monotonic() - t0)
            except Exception as e:  # noqa: BLE001 - one bad file must not stop the queue
                log.exception("transcription of %s failed", mid)
                ingest.set_ingest(job.user, mid, status="failed", error=f"transcription failed ({type(e).__name__})")
