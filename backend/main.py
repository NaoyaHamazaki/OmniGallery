"""OmniGallery PoC backend (FastAPI, single file).

起動:
    uvicorn main:app --host 0.0.0.0 --port 8000      (または ルートの 起動用.bat)

提供するもの:
    GET  /api/config         アプリ設定 (デバッグフラグ・フロア情報)
    GET  /api/artworks       作品一覧 (絵画 + 3Dモデル)
    GET  /api/debug/info     構成情報 (OMNI_DEBUG=1 のときのみ)
    GET  /static/...         作品画像 / glb モデル / 内装テクスチャ / アイコン・OGP画像
    GET  /                   トップページ (pages/index.html): 「美術館に入る」ボタン + 作品出品受付の案内
    GET  /submit/            トップページの出品受付の欄へ移動 (館内の受付端末から別タブで開く)
    GET  /game/              Godot の Web エクスポート (../godot/build/web) を配信 (OGP メタタグを注入)。
                             トップページを経由していないアクセスはトップページへ戻す

素材は初回起動時に自動ダウンロードする (すべて CC0 / CC BY / パブリックドメイン)。
"""

from __future__ import annotations

import gzip
import logging
import mimetypes
import os
import platform
import shutil
import sqlite3
import time
import urllib.parse
import urllib.request
from collections import Counter
from contextlib import asynccontextmanager, closing
from datetime import datetime, timezone
from html import escape
from pathlib import Path

import fastapi
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

# Windows ではレジストリ次第で MIME が正しく返らず Web ビルドが起動しないことがあるため明示登録
mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("text/javascript", ".js")
mimetypes.add_type("model/gltf-binary", ".glb")
mimetypes.add_type("application/manifest+json", ".webmanifest")
mimetypes.add_type("video/ogg", ".ogv")

logger = logging.getLogger("uvicorn.error")

APP_NAME = "OmniGallery"
APP_VERSION = "0.2.0"
DEBUG = os.getenv("OMNI_DEBUG", "1") == "1"  # PoC 期間中は既定でデバッグ表示 ON
CORS_ORIGINS = ["*"]  # PoC なので全許可。本番では配信ドメインに絞る

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"
ARTWORK_DIR = STATIC_DIR / "artworks"
MODEL_DIR = STATIC_DIR / "models"
VIDEO_DIR = STATIC_DIR / "videos"
TEXTURE_DIR = STATIC_DIR / "textures"
BRAND_DIR = STATIC_DIR / "brand"
PAGES_DIR = BASE_DIR / "pages"
DB_PATH = BASE_DIR / "data" / "omnigallery.db"
WEB_BUILD_DIR = BASE_DIR.parent / "godot" / "build" / "web"

STARTED_AT = time.time()
REQUEST_COUNTER: Counter[str] = Counter()

# ---------------------------------------------------------------------------
# シードデータ
# ---------------------------------------------------------------------------
FLOORS = [
    {"id": 1, "name": "1F", "title": "Classical Masters", "description": "European paintings and design chairs."},
    {"id": 2, "name": "2F", "title": "Light & Motion", "description": "From ukiyo-e to modernism, with 3D objects."},
]

WIKI = "https://commons.wikimedia.org/wiki/File:"
KHRONOS = "https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/"
PD_CREDIT = "Public domain, via Wikimedia Commons"

# kind: painting | model / floor: 展示フロア / featured: フロアの正面(アイストップ)に展示
# light_kelvin: スポットライトの色温度 (古典=3000K 電球色、現代・プロダクト=5000K 昼白色)
# display_size: 3D モデルの最大寸法 (m)
SEED_ARTWORKS: list[dict] = [
    # ---- 1F ----
    {"id": "starry-night", "kind": "painting", "floor": 1, "featured": 1, "light_kelvin": 3000,
     "title": "The Starry Night", "artist": "Vincent van Gogh", "year": 1889,
     "description": "Painted from the window of his asylum room at Saint-Remy-de-Provence, "
                    "the swirling night sky over a quiet village became one of the most recognized images in Western art.",
     "file": "starry_night.jpg", "remote": "Van Gogh - Starry Night - Google Art Project.jpg"},
    {"id": "mona-lisa", "kind": "painting", "floor": 1, "light_kelvin": 3000,
     "title": "Mona Lisa", "artist": "Leonardo da Vinci", "year": 1503,
     "description": "A half-length portrait famous for its subtle sfumato modelling and the sitter's enigmatic smile.",
     "file": "mona_lisa.jpg", "remote": "Mona Lisa, by Leonardo da Vinci, from C2RMF retouched.jpg"},
    {"id": "pearl-earring", "kind": "painting", "floor": 1, "light_kelvin": 3000,
     "title": "Girl with a Pearl Earring", "artist": "Johannes Vermeer", "year": 1665,
     "description": "A tronie - a study of a face - of a girl in an exotic turban, lit against a dark background.",
     "file": "pearl_earring.jpg", "remote": "1665 Girl with a Pearl Earring.jpg"},
    {"id": "milkmaid", "kind": "painting", "floor": 1, "light_kelvin": 3000,
     "title": "The Milkmaid", "artist": "Johannes Vermeer", "year": 1658,
     "description": "A kitchen maid carefully pours milk, bathed in soft daylight from a window.",
     "file": "milkmaid.jpg", "remote": "Johannes Vermeer - Het melkmeisje - Google Art Project.jpg"},
    {"id": "birth-of-venus", "kind": "painting", "floor": 1, "light_kelvin": 3000,
     "title": "The Birth of Venus", "artist": "Sandro Botticelli", "year": 1485,
     "description": "The goddess Venus arrives at the shore on a scallop shell, blown by the wind gods.",
     "file": "birth_of_venus.jpg", "remote": "Sandro Botticelli - La nascita di Venere - Google Art Project - edited.jpg"},
    {"id": "grande-jatte", "kind": "painting", "floor": 1, "light_kelvin": 3000,
     "title": "A Sunday on La Grande Jatte", "artist": "Georges Seurat", "year": 1884,
     "description": "Parisians relax on an island in the Seine, rendered in thousands of tiny dots of pure colour.",
     "file": "grande_jatte.jpg", "remote": "A Sunday on La Grande Jatte, Georges Seurat, 1884.jpg"},
    {"id": "sheen-chair", "kind": "model", "floor": 1, "light_kelvin": 5000, "display_size": 0.95,
     "title": "Sheen Chair", "artist": "Eric Chadwick / Wayfair", "year": 2020,
     "description": "A lounge chair modelled to show fabric sheen and material variants in glTF.",
     "file": "sheen_chair.glb", "remote": "SheenChair", "credit": "Eric Chadwick, Wayfair LLC - CC0 1.0"},
    {"id": "damask-chair", "kind": "model", "floor": 1, "light_kelvin": 5000, "display_size": 0.9,
     "title": "Damask Chair", "artist": "Eric Chadwick / Wayfair", "year": 2021,
     "description": "A small high-end seat upholstered in purple and gold damask.",
     "file": "damask_chair.glb", "remote": "ChairDamaskPurplegold", "credit": "Eric Chadwick, Wayfair - CC BY 4.0"},
    {"id": "upload-test-01", "kind": "model", "floor": 1, "light_kelvin": 5000, "display_size": 3.0,
     "title": "Upload Test 01", "artist": "Test upload (local only)", "year": 2026,
     "description": "A rigged figure converted from a Blender file to test how uploaded works are displayed: "
                    "a lightweight version is shown by default and the original can be loaded on request.",
     "file": "irobny_lite.glb", "hq_file": "irobny.glb", "remote": None,
     "credit": "Local test file - not for public deployment"},
    # 投稿のお試し展示 (スマホの写真・動画を tools/convert_media.py で変換したもの)
    {"id": "local-photo-01", "kind": "painting", "media": "image", "floor": 1, "light_kelvin": 5000,
     "title": "Photo Test 01", "artist": "Test upload", "year": 2026,
     "description": "A smartphone photo (HEIC) converted to JPEG with location and other metadata removed.",
     "file": "local_photo_01.jpg", "remote": None, "credit": "Test upload - photo by the OmniGallery team"},
    {"id": "local-video-01", "kind": "painting", "media": "video", "floor": 1, "light_kelvin": 5000,
     "title": "Video Test 01", "artist": "Test upload", "year": 2026,
     "description": "A smartphone video (HEVC .MOV) converted to Ogg Theora for the web, looping without sound.",
     "file": "local_video_01.ogv", "remote": None, "credit": "Test upload - video by the OmniGallery team"},
    # ---- 2F ----
    {"id": "great-wave", "kind": "painting", "floor": 2, "featured": 1, "light_kelvin": 3000,
     "title": "The Great Wave off Kanagawa", "artist": "Katsushika Hokusai", "year": 1831,
     "description": "A towering wave threatens boats off the coast of Kanagawa, with Mount Fuji small in the distance. "
                    "From the series Thirty-six Views of Mount Fuji.",
     "file": "great_wave.jpg", "remote": "Tsunami by hokusai 19th century.jpg"},
    {"id": "impression-sunrise", "kind": "painting", "floor": 2, "light_kelvin": 3000,
     "title": "Impression, Sunrise", "artist": "Claude Monet", "year": 1872,
     "description": "The port of Le Havre at dawn. A critic's mockery of its title gave Impressionism its name.",
     "file": "impression_sunrise.jpg", "remote": "Monet - Impression, Sunrise.jpg"},
    {"id": "the-kiss", "kind": "painting", "floor": 2, "light_kelvin": 3000,
     "title": "The Kiss", "artist": "Gustav Klimt", "year": 1908,
     "description": "Oil and gold leaf on canvas from Klimt's Golden Period: two lovers wrapped in ornamented robes.",
     "file": "the_kiss.jpg", "remote": "The Kiss - Gustav Klimt - Google Cultural Institute.jpg"},
    {"id": "the-scream", "kind": "painting", "floor": 2, "light_kelvin": 3000,
     "title": "The Scream", "artist": "Edvard Munch", "year": 1893,
     "description": "An agonized figure against a blood-red sky - an icon of modern anxiety.",
     "file": "the_scream.jpg",
     "remote": "Edvard Munch, 1893, The Scream, oil, tempera and pastel on cardboard, 91 x 73 cm, National Gallery of Norway.jpg"},
    {"id": "fox", "kind": "model", "floor": 2, "light_kelvin": 5000, "display_size": 1.1,
     "title": "Fox", "artist": "PixelMannen / tomkranis", "year": 2014,
     "description": "A low-poly fox with rigged animation cycles, looking around its pedestal.",
     "file": "fox.glb", "remote": "Fox",
     "credit": "Model: PixelMannen (CC0 1.0) / Rigging & animation: tomkranis (CC BY 4.0) / "
               "glTF conversion: AsoboStudio & scurest (CC BY 4.0)"},
    {"id": "toy-car", "kind": "model", "floor": 2, "light_kelvin": 5000, "display_size": 0.9,
     "title": "Toy Car", "artist": "Guido Odendahl / Eric Chadwick", "year": 2020,
     "description": "A glossy toy car with clearcoat paint and a transparent windshield.",
     "file": "toy_car.glb", "remote": "ToyCar", "credit": "Guido Odendahl, Eric Chadwick - CC0 1.0"},
]

# 内装テクスチャ (Poly Haven, CC0)。key -> (asset id, 取得するマップ)
TEXTURES = {
    "floor_parquet": ("herringbone_parquet", ["diff", "nor_gl", "rough"]),
    "floor_stone": ("marble_01", ["diff", "nor_gl", "rough"]),
    "wall_plaster": ("plastered_wall", ["nor_gl"]),
}


# ---------------------------------------------------------------------------
# 素材のダウンロード
# ---------------------------------------------------------------------------
def _download(url: str, dest: Path) -> None:
    if dest.exists():
        return
    req = urllib.request.Request(url, headers={"User-Agent": "OmniGalleryPoC/0.2 (asset downloader)"})
    try:
        with urllib.request.urlopen(req, timeout=60) as res:
            data = res.read()
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        logger.info("downloaded %s (%d KB)", dest.name, len(data) // 1024)
    except Exception as exc:  # PoC なので失敗した素材は表示しないだけ
        logger.warning("failed to download %s: %s", dest.name, exc)


def download_assets() -> None:
    for art in SEED_ARTWORKS:
        if art["remote"] is None:  # ローカルに置いた投稿テスト作品はダウンロードしない
            continue
        if art["kind"] == "painting":
            name = urllib.parse.quote(art["remote"])
            url = f"https://commons.wikimedia.org/wiki/Special:FilePath/{name}?width=1280"
            _download(url, ARTWORK_DIR / art["file"])
        else:
            m = art["remote"]
            url = f"https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models/{m}/glTF-Binary/{m}.glb"
            _download(url, MODEL_DIR / art["file"])
    for key, (asset, maps) in TEXTURES.items():
        for m in maps:
            url = f"https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/{asset}/{asset}_{m}_1k.jpg"
            _download(url, TEXTURE_DIR / f"{key}_{m.replace('_gl', '')}.jpg")


# ---------------------------------------------------------------------------
# データベース (SQLite)。将来の UGC 投稿に備えて作品はテーブルで管理する
# ---------------------------------------------------------------------------
SCHEMA = """
CREATE TABLE IF NOT EXISTS floors (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS artworks (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('painting', 'model')),
    title TEXT NOT NULL,
    artist TEXT NOT NULL,
    year INTEGER,
    description TEXT NOT NULL DEFAULT '',
    file TEXT NOT NULL,
    source_url TEXT NOT NULL DEFAULT '',
    credit TEXT NOT NULL DEFAULT '',
    floor INTEGER NOT NULL REFERENCES floors(id),
    featured INTEGER NOT NULL DEFAULT 0,
    light_kelvin INTEGER NOT NULL DEFAULT 3000,
    display_size REAL,
    hq_file TEXT,
    media TEXT NOT NULL DEFAULT 'image',
    sort_order INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'published',
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS rankings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    course TEXT NOT NULL DEFAULT 'driving-school',
    name TEXT NOT NULL CHECK (length(name) = 3),
    time_ms INTEGER NOT NULL,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rankings_course_time ON rankings (course, time_ms);
"""


def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    with closing(db()) as conn, conn:
        conn.executescript(SCHEMA)
        cols = [c[1] for c in conn.execute("PRAGMA table_info(artworks)")]
        if "hq_file" not in cols:  # 既存の DB に列を追加
            conn.execute("ALTER TABLE artworks ADD COLUMN hq_file TEXT")
        if "media" not in cols:
            conn.execute("ALTER TABLE artworks ADD COLUMN media TEXT NOT NULL DEFAULT 'image'")
        conn.executemany(
            "INSERT INTO floors (id, name, title, description) VALUES (:id, :name, :title, :description) "
            "ON CONFLICT(id) DO UPDATE SET name=excluded.name, title=excluded.title, description=excluded.description",
            FLOORS,
        )
        rows = []
        for i, a in enumerate(SEED_ARTWORKS):
            painting = a["kind"] == "painting"
            rows.append({
                "id": a["id"], "kind": a["kind"], "title": a["title"], "artist": a["artist"],
                "year": a.get("year"), "description": a["description"], "file": a["file"],
                "source_url": "" if a["remote"] is None else
                (WIKI + a["remote"].replace(" ", "_")) if painting else KHRONOS + a["remote"],
                "credit": a.get("credit", PD_CREDIT), "floor": a["floor"], "featured": a.get("featured", 0),
                "light_kelvin": a["light_kelvin"], "display_size": a.get("display_size"),
                "hq_file": a.get("hq_file"), "media": a.get("media", "image"),
                "sort_order": i, "created_at": now,
            })
        # シード作品は毎回最新の定義で上書き (UGC 投稿分は影響を受けない)
        conn.executemany(
            "INSERT INTO artworks (id, kind, title, artist, year, description, file, source_url, credit, floor, "
            "featured, light_kelvin, display_size, hq_file, media, sort_order, created_at) VALUES (:id, :kind, :title, :artist, "
            ":year, :description, :file, :source_url, :credit, :floor, :featured, :light_kelvin, :display_size, :hq_file, :media, "
            ":sort_order, :created_at) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, title=excluded.title, "
            "artist=excluded.artist, year=excluded.year, description=excluded.description, file=excluded.file, "
            "source_url=excluded.source_url, credit=excluded.credit, floor=excluded.floor, "
            "featured=excluded.featured, light_kelvin=excluded.light_kelvin, display_size=excluded.display_size, "
            "hq_file=excluded.hq_file, media=excluded.media, sort_order=excluded.sort_order",
            rows,
        )


def _asset_dir(kind: str, media: str = "image") -> Path:
    if media == "video":
        return VIDEO_DIR
    return ARTWORK_DIR if kind == "painting" else MODEL_DIR


def _asset_path(kind: str, file: str, media: str = "image") -> Path:
    return _asset_dir(kind, media) / file


# ---------------------------------------------------------------------------
# アプリ
# ---------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    download_assets()
    precompress_web_build()
    yield


app = FastAPI(title=APP_NAME, version=APP_VERSION, lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=CORS_ORIGINS, allow_methods=["GET", "POST"], allow_headers=["*"])


@app.middleware("http")
async def count_and_cache(request: Request, call_next):
    path = request.url.path
    REQUEST_COUNTER[path.split("/")[1] if path.startswith("/") else path] += 1
    response = await call_next(request)
    # ゲーム本体は再エクスポートで中身が変わるので、毎回 ETag で更新確認させる (未変更なら 304)
    if path.startswith("/game/"):
        response.headers["Cache-Control"] = "no-cache"
    elif path.startswith("/api/"):
        # 中継サーバー (Railway のエッジ) で勝手に圧縮させない。
        # 圧縮されると Godot Web 版の HTTPRequest が二重に解凍しようとして失敗する
        response.headers["Cache-Control"] = "no-store, no-transform"
    return response


@app.get("/api/config")
def get_config() -> dict:
    with closing(db()) as conn:
        floors = [dict(r) for r in conn.execute("SELECT id, name, title, description FROM floors ORDER BY id")]
    return {"app": APP_NAME, "version": APP_VERSION, "debug": DEBUG, "floors": floors}


@app.get("/api/artworks")
def list_artworks(request: Request) -> dict:
    with closing(db()) as conn:
        rows = conn.execute(
            "SELECT * FROM artworks WHERE status = 'published' ORDER BY floor, featured DESC, sort_order"
        ).fetchall()
    items = []
    for r in rows:
        if not _asset_path(r["kind"], r["file"], r["media"]).exists():
            continue
        mount = "videos" if r["media"] == "video" else ("artworks" if r["kind"] == "painting" else "models")
        item = {k: r[k] for k in ("id", "kind", "title", "artist", "year", "description", "source_url", "credit",
                                  "floor", "light_kelvin")}
        item["featured"] = bool(r["featured"])
        item["media"] = r["media"]
        item["url"] = str(request.url_for(mount, path=r["file"]))
        if r["kind"] == "model":
            item["display_size"] = r["display_size"] or 1.0
            hq = MODEL_DIR / r["hq_file"] if r["hq_file"] else None
            if hq and hq.exists():  # 軽量版を常時表示し、希望した人だけ高品質版を読み込む
                item["hq_url"] = str(request.url_for("models", path=r["hq_file"]))
                item["hq_mb"] = round(hq.stat().st_size / 1_048_576, 1)
        items.append(item)
    return {"artworks": items}


# ---------------------------------------------------------------------------
# タイムアタックのランキング (タクシーのイースターエッグ)
# ---------------------------------------------------------------------------
RANKING_SIZE = 10
COURSE_ID = "driving-school"


class RankingIn(BaseModel):
    name: str = Field(pattern=r"^[A-Z]{3}$", description="アルファベット大文字 3 文字")
    time_ms: int = Field(ge=20_000, le=600_000, description="ラップタイム (ミリ秒)")


def _top_rankings(conn: sqlite3.Connection) -> list[dict]:
    rows = conn.execute(
        "SELECT name, time_ms, created_at FROM rankings WHERE course = ? ORDER BY time_ms, id LIMIT ?",
        (COURSE_ID, RANKING_SIZE),
    ).fetchall()
    return [{"rank": i + 1, "name": r["name"], "time_ms": r["time_ms"], "created_at": r["created_at"]}
            for i, r in enumerate(rows)]


@app.get("/api/rankings")
def get_rankings() -> dict:
    with closing(db()) as conn:
        top = _top_rankings(conn)
    # この時間より速ければランクイン (10 件未満なら誰でも入れる)
    qualify = top[-1]["time_ms"] if len(top) >= RANKING_SIZE else None
    return {"course": COURSE_ID, "size": RANKING_SIZE, "rankings": top, "qualify_ms": qualify}


@app.post("/api/rankings")
def post_ranking(entry: RankingIn) -> dict:
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    with closing(db()) as conn, conn:
        cur = conn.execute("INSERT INTO rankings (course, name, time_ms, created_at) VALUES (?, ?, ?, ?)",
                           (COURSE_ID, entry.name, entry.time_ms, now))
        new_id = cur.lastrowid
        rank = conn.execute(
            "SELECT COUNT(*) FROM rankings WHERE course = ? AND (time_ms < ? OR (time_ms = ? AND id < ?))",
            (COURSE_ID, entry.time_ms, entry.time_ms, new_id),
        ).fetchone()[0] + 1
        top = _top_rankings(conn)
    return {"rank": rank, "in_top": rank <= RANKING_SIZE, "rankings": top}


DEBUG_ROW_LIMIT = 200


def _cell(v):
    """デバッグ表示用にセルの値を整える (長文は切り詰め)。"""
    if isinstance(v, str) and len(v) > 300:
        return v[:300] + "..."
    return v


def _dir_stats(path: Path) -> dict:
    files = [p for p in path.glob("*") if p.is_file()] if path.exists() else []
    return {"files": len(files), "size_mb": round(sum(p.stat().st_size for p in files) / 1_048_576, 2)}


@app.get("/api/debug/info")
def debug_info() -> dict:
    """公開しても問題ない範囲の構成情報 (絶対パス・環境変数・ホスト名などは返さない)。"""
    if not DEBUG:
        raise HTTPException(status_code=404)
    with closing(db()) as conn:
        tables = []
        for name, sql in conn.execute("SELECT name, sql FROM sqlite_master WHERE type='table' ORDER BY name").fetchall():
            cols = [
                {"name": c["name"], "type": c["type"], "notnull": bool(c["notnull"]),
                 "default": c["dflt_value"], "pk": bool(c["pk"])}
                for c in conn.execute(f"PRAGMA table_info({name})")
            ]
            count = conn.execute(f"SELECT COUNT(*) FROM {name}").fetchone()[0]
            data = conn.execute(f"SELECT * FROM {name} LIMIT {DEBUG_ROW_LIMIT}").fetchall()
            rows = [[_cell(v) for v in r] for r in data]
            tables.append({"name": name, "sql": sql, "row_count": count, "columns": cols, "rows": rows,
                           "truncated": count > DEBUG_ROW_LIMIT})
        by_kind = {r[0]: r[1] for r in conn.execute("SELECT kind, COUNT(*) FROM artworks GROUP BY kind")}
        by_floor = {f"{r[0]}F": r[1] for r in conn.execute("SELECT floor, COUNT(*) FROM artworks GROUP BY floor")}
    index = WEB_BUILD_DIR / "index.html"
    wasm = WEB_BUILD_DIR / "index.wasm"
    return {
        "app": {
            "name": APP_NAME, "version": APP_VERSION, "debug": DEBUG,
            "server_time": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "uptime_sec": int(time.time() - STARTED_AT),
        },
        "runtime": {"python": platform.python_version(), "fastapi": fastapi.__version__,
                    "os": platform.system(), "sqlite": sqlite3.sqlite_version},
        "database": {"engine": "SQLite", "file": DB_PATH.name,
                     "size_kb": round(DB_PATH.stat().st_size / 1024, 1) if DB_PATH.exists() else 0,
                     "tables": tables, "artworks_by_kind": by_kind, "artworks_by_floor": by_floor},
        "storage": {"artworks": _dir_stats(ARTWORK_DIR), "models": _dir_stats(MODEL_DIR), "videos": _dir_stats(VIDEO_DIR),
                    "textures": _dir_stats(TEXTURE_DIR)},
        "web_build": {
            "present": index.exists(),
            "built_at": datetime.fromtimestamp(index.stat().st_mtime, timezone.utc).isoformat(timespec="seconds")
            if index.exists() else None,
            "wasm_mb": round(wasm.stat().st_size / 1_048_576, 1) if wasm.exists() else None,
        },
        "cors": {"allow_origins": CORS_ORIGINS},
        "requests": dict(REQUEST_COUNTER.most_common(8)),
        "endpoints": sorted({r.path for r in app.routes if r.path.startswith("/api")}),
    }


# ---------------------------------------------------------------------------
# Web ページ (ゲーム本体 / OGP / favicon)
# ---------------------------------------------------------------------------
OG_DESCRIPTION = "Walk through a virtual museum in your browser. ブラウザで歩けるバーチャル美術館。"


def _meta_tags(base: str) -> str:
    tags = {
        "description": OG_DESCRIPTION,
        "og:type": "website",
        "og:site_name": APP_NAME,
        "og:title": f"{APP_NAME} - Virtual Museum",
        "og:description": OG_DESCRIPTION,
        "og:url": base,
        "og:image": f"{base}static/brand/og-image.png",
        "og:image:width": "1200",
        "og:image:height": "630",
        "twitter:card": "summary_large_image",
        "theme-color": "#1f2433",
    }
    lines = []
    for key, value in tags.items():
        attr = "property" if key.startswith("og:") else "name"
        lines.append(f'<meta {attr}="{key}" content="{escape(value)}">')
    lines.append('<link rel="icon" href="/favicon.ico" sizes="any">')
    lines.append('<link rel="apple-touch-icon" href="/static/brand/apple-touch-icon.png">')
    # ホーム画面に追加して起動するとアドレスバーなしの全画面になる (iPhone はこれが唯一の方法)
    lines.append('<link rel="manifest" href="/static/brand/manifest.webmanifest">')
    lines.append('<meta name="apple-mobile-web-app-capable" content="yes">')
    lines.append('<meta name="mobile-web-app-capable" content="yes">')
    lines.append('<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">')
    lines.append('<meta name="apple-mobile-web-app-title" content="OmniGallery">')
    return "\n".join(lines)


# トップページを開いたら発行する入館の印 (ブラウザを閉じるまで有効)。/game/ はこれがないとトップページへ戻す
ENTRY_COOKIE = "omni_entry"


@app.get("/", include_in_schema=False)
def top_page(request: Request):
    """トップページ。ここの「美術館に入る」ボタンからゲームを起動する。"""
    if not (WEB_BUILD_DIR / "index.html").exists():
        return HTMLResponse(
            """<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
            <title>OmniGallery</title><link rel="icon" href="/favicon.ico">
            <body style="font-family:sans-serif;max-width:640px;margin:40px auto;padding:0 16px;line-height:1.7">
            <h1>OmniGallery: サーバーは起動しています</h1>
            <p>Godot の Web エクスポートがまだありません (<code>godot/build/web/index.html</code>)。</p>
            <p>Godot で「プロジェクト → エクスポート → Web → プロジェクトのエクスポート」を実行したら、
            このページを再読み込みしてください (サーバーの再起動は不要)。</p>
            <p>API の確認: <a href="/api/artworks">/api/artworks</a> ・ <a href="/docs">/docs</a></p>
            </body>"""
        )
    html = (PAGES_DIR / "index.html").read_text(encoding="utf-8")
    html = html.replace("<!--META-->", _meta_tags(str(request.base_url)), 1)
    res = HTMLResponse(html, headers={"Cache-Control": "no-cache"})
    res.set_cookie(ENTRY_COOKIE, "1", path="/", samesite="lax", httponly=True,
                   secure=request.url.scheme == "https")
    return res


@app.get("/game/", include_in_schema=False)
@app.get("/game/index.html", include_in_schema=False)
def game_index(request: Request):
    """Godot が出力した index.html に OGP / favicon のメタタグを差し込んで返す。"""
    index = WEB_BUILD_DIR / "index.html"
    if not index.exists() or request.cookies.get(ENTRY_COOKIE) != "1":
        return RedirectResponse(url="/")  # トップページを経由してから入館する
    html = index.read_text(encoding="utf-8")
    html = html.replace("<head>", "<head>\n" + _meta_tags(str(request.base_url)), 1)
    return HTMLResponse(html, headers={"Cache-Control": "no-cache"})


COMPRESSIBLE = {".wasm", ".pck", ".js"}


def _gzip_for(path: Path) -> Path | None:
    """事前圧縮した .gz を用意する (元ファイルより古ければ作り直す)。wasm 39MB → 約 10MB。"""
    gz = path.with_name(path.name + ".gz")
    try:
        if not gz.exists() or gz.stat().st_mtime < path.stat().st_mtime:
            tmp = path.with_name(path.name + ".gz.tmp")
            with open(path, "rb") as src, gzip.open(tmp, "wb", compresslevel=6) as dst:
                shutil.copyfileobj(src, dst, 1 << 20)
            tmp.replace(gz)
            logger.info("precompressed %s (%d KB -> %d KB)", path.name, path.stat().st_size // 1024,
                        gz.stat().st_size // 1024)
        return gz
    except OSError as exc:
        logger.warning("gzip failed for %s: %s", path.name, exc)
        return None


def precompress_web_build() -> None:
    if WEB_BUILD_DIR.exists():
        for p in WEB_BUILD_DIR.iterdir():
            if p.suffix in COMPRESSIBLE:
                _gzip_for(p)


@app.get("/game/{path:path}", include_in_schema=False)
def game_file(path: str, request: Request):
    """Web ビルドの配信。ブラウザが gzip に対応していれば事前圧縮版を返す (ETag で 304 対応)。"""
    base = WEB_BUILD_DIR.resolve()
    target = (base / path).resolve()
    if not target.is_relative_to(base) or not target.is_file() or target.name.endswith((".gz", ".tmp")):
        raise HTTPException(status_code=404)
    media = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
    headers = {"Cache-Control": "no-cache", "Vary": "Accept-Encoding"}
    file = target
    if target.suffix in COMPRESSIBLE and "gzip" in request.headers.get("accept-encoding", ""):
        gz = _gzip_for(target)
        if gz:
            file = gz
            headers["Content-Encoding"] = "gzip"
    st = file.stat()
    etag = f'"{st.st_mtime_ns:x}-{st.st_size:x}"'
    headers["ETag"] = etag
    if request.headers.get("if-none-match") == etag:
        return Response(status_code=304, headers=headers)
    return FileResponse(file, media_type=media, headers=headers)


@app.get("/bye", include_in_schema=False)
def bye():
    """ゲーム内の EXIT から移動するお別れページ (ブラウザのタブはスクリプトから閉じられないため)。"""
    return HTMLResponse(
        """<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>OmniGallery</title><link rel="icon" href="/favicon.ico">
        <style>
        @font-face{font-family:Cinzel;src:url('/static/brand/fonts/Cinzel.ttf')}
        body{margin:0;height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;
             background:radial-gradient(ellipse at 50% 40%,#2b3247,#1f2433 55%,#151824);color:#ece6da;
             font-family:Cinzel,Georgia,serif;text-align:center}
        img{width:64px;height:64px}
        h1{font-weight:400;letter-spacing:.15em;font-size:24px;margin:8px 0 0}
        p{color:#9a96a0;letter-spacing:.1em;font-size:13px;margin:0}
        a{margin-top:18px;color:#1f2433;background:#c9a45c;padding:10px 26px;border-radius:6px;text-decoration:none;letter-spacing:.15em}
        </style>
        <img src="/static/brand/icon-512.png" alt="">
        <h1>THANK YOU FOR VISITING</h1>
        <p>ご来館ありがとうございました</p>
        <a href="/">ENTER AGAIN</a>"""
    )


@app.get("/submit", include_in_schema=False)
@app.get("/submit/", include_in_schema=False)
def submit_redirect():
    """作品出品受付 = トップページの出品受付の欄 (館内の受付端末のリンク先。現在は案内のみ)。"""
    return RedirectResponse(url="/#submit")


@app.get("/favicon.ico", include_in_schema=False)
def favicon():
    return FileResponse(BRAND_DIR / "favicon.ico")


for _d in (ARTWORK_DIR, MODEL_DIR, VIDEO_DIR, TEXTURE_DIR, BRAND_DIR):
    _d.mkdir(parents=True, exist_ok=True)
app.mount("/static/artworks", StaticFiles(directory=ARTWORK_DIR), name="artworks")
app.mount("/static/models", StaticFiles(directory=MODEL_DIR), name="models")
app.mount("/static/videos", StaticFiles(directory=VIDEO_DIR), name="videos")
app.mount("/static/textures", StaticFiles(directory=TEXTURE_DIR), name="textures")
app.mount("/static/brand", StaticFiles(directory=BRAND_DIR), name="brand")
# /game/ 配下は game_index / game_file のルートで配信する (OGP 差し込み・gzip 対応のため)
