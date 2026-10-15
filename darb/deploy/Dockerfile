# Darb API image: the api pool, the slow (AI + uploads) pool and the worker all run it. Build context = darb/.
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
# poppler renders upload pages; Noto covers Arabic in uploaded photos converted to PDF.
RUN apt-get update && apt-get install -y --no-install-recommends poppler-utils fonts-noto-core \
    && rm -rf /var/lib/apt/lists/*
COPY backend/requirements.txt .
# requirements.txt pins the CPU-only torch index (the FSRS optimizer; the CUDA build is several GB).
RUN pip install -r requirements.txt
COPY backend /app
# The admin's CSS/JS, served by WhiteNoise from the image (no shared static volume).
RUN DJANGO_SECRET_KEY=build-only python manage.py collectstatic --noinput -v0
RUN useradd -r -u 10001 darb && mkdir -p /data/uploads && chown darb /data/uploads
USER darb
EXPOSE 8000
CMD ["gunicorn", "darb.wsgi", "-b", "0.0.0.0:8000", "-w", "4", "--threads", "4", "--timeout", "30", "--access-logfile", "-"]
