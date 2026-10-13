# Build context = repo root (the backend reads docs/cards.schema.json).
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app/backend
# Graphviz + a font draw the card diagrams (core/diagram.py).
RUN apt-get update && apt-get install -y --no-install-recommends graphviz fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*
COPY backend/requirements.txt .
# requirements.txt pins the CPU-only torch index (the CUDA build is several GB).
RUN pip install -r requirements.txt
COPY docs /app/docs
COPY backend /app/backend
RUN useradd -r -u 10001 certdeck && mkdir -p /data/media && chown certdeck /data/media
USER certdeck
EXPOSE 8000
CMD ["sh", "-c", "python manage.py migrate --noinput && exec gunicorn certdeck.wsgi -b 0.0.0.0:8000 -w 2 --threads 8 --timeout 600 --access-logfile -"]
