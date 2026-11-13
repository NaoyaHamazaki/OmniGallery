# OmniGallery (FastAPI + Godot Web ビルド) を 1 コンテナで配信する。Railway はルートの Dockerfile を自動検出する。
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    OMNI_DEBUG=1

WORKDIR /app

COPY backend/requirements.txt backend/requirements.txt
RUN pip install --no-cache-dir -r backend/requirements.txt

# バックエンド (素材 static/ を含む) と、Godot で書き出した Web ビルド
COPY backend backend
COPY godot/build/web godot/build/web

WORKDIR /app/backend
# Railway は PORT 環境変数で待ち受けポートを渡す。
# --proxy-headers: Railway の HTTPS 終端の後ろでも https:// の URL を生成する (画像URL・OGP が http になるのを防ぐ)
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000} --proxy-headers --forwarded-allow-ips='*'"]
