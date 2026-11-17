# Cloud image: API + dashboard (SENTINEL_MODE=api). No OpenCV/YOLO/PyTorch, so it is small.
# The camera agent is NOT built here: it runs next to the camera (see docs/AWS.md).

# ---- 1. build the dashboard as static files -------------------------------------------------
FROM node:22-slim AS web
WORKDIR /web
RUN corepack enable
COPY frontend/package.json frontend/pnpm-lock.yaml frontend/pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY frontend/ ./
# NEXT_PUBLIC_SENTINEL_API_URL is deliberately NOT set: in production the dashboard calls the
# API on its own origin.
RUN pnpm build

# ---- 2. run the API and serve the dashboard ------------------------------------------------
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 \
    SENTINEL_MODE=api SENTINEL_ENV=production \
    SENTINEL_FRONTEND_DIR=/app/static SENTINEL_DATA_DIR=/data
WORKDIR /app
COPY backend/requirements-cloud.txt .
RUN pip install --no-cache-dir -r requirements-cloud.txt
COPY backend/ .
COPY --from=web /web/out /app/static
RUN useradd --system --create-home app && mkdir -p /data && chown app /data
USER app
VOLUME /data
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD python -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8000/api/health', timeout=4)"
CMD ["python", "main.py"]
