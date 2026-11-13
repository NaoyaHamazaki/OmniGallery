"""アップロードされたファイルを展示用に変換する共通の入口 (UGC 投稿の受付処理から呼ぶ想定)。

    backend\\.venv\\Scripts\\python tools\\convert_media.py <入力ファイル> <出力先フォルダ> [<名前>]

ファイルの中身 (先頭バイト) から種類を判定して振り分ける:

| 種類 | 受け付ける形式 | 出力 | 主な処理 |
|---|---|---|---|
| image | JPEG / PNG / WebP / HEIC・HEIF / AVIF / GIF (1 枚目) / BMP / TIFF | JPEG (透過ありは PNG) | 撮影時の向きを反映、長辺 2048px 以下、EXIF (位置情報など) を除去 |
| video | MOV / MP4 / M4V / WebM / MKV / AVI | Ogg Theora (.ogv) + サムネイル JPEG | 長辺 960px・30fps・無音、メタデータ除去 (Godot が再生できるのは Theora のみ) |
| model | glb / gltf / blend / fbx / obj / stl / ply / usd(z) | オリジナル版 glb + 軽量版 glb | Blender で読み込み (tools/convert_blend.py)。材質の整理、静止ポーズの適用、三角形数とテクスチャの削減 |

結果は JSON (標準出力と <名前>_media.json) で返す:
    {"kind": "painting"|"model", "media": "image"|"video"|"model", "files": {...}, "meta": {...}}
外部ツール: ffmpeg (動画)、Blender (3D。環境変数 BLENDER で場所を指定)。
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

IMAGE_MAX = 2048
VIDEO_MAX = 960
BLENDER = os.getenv("BLENDER", r"C:\Users\right\Tools\blender-5.2.4-windows-x64\blender.exe")
CONVERT_BLEND = Path(__file__).resolve().parent / "convert_blend.py"


class ConvertError(Exception):
    pass


def sniff(path: Path) -> str:
    """先頭バイトで種類を判定する (拡張子は偽装できるので補助的にのみ使う)。"""
    head = path.read_bytes()[:64]
    ext = path.suffix.lower()
    if head[:3] == b"\xff\xd8\xff" or head[:8] == b"\x89PNG\r\n\x1a\n" or head[:4] == b"GIF8" \
            or head[:2] == b"BM" or head[:4] in (b"II*\x00", b"MM\x00*"):
        return "image"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image"
    if head[:4] == b"RIFF" and head[8:12] == b"AVI ":
        return "video"
    if head[4:8] == b"ftyp":  # ISO メディア: HEIC/AVIF は画像、それ以外は動画
        brand = head[8:12]
        return "image" if brand in (b"heic", b"heix", b"mif1", b"msf1", b"heim", b"avif", b"avis") else "video"
    if head[:4] == b"\x1a\x45\xdf\xa3":  # WebM / MKV
        return "video"
    if head[:4] == b"glTF" or head[:7] == b"BLENDER" or ext in (".gltf", ".fbx", ".obj", ".stl", ".ply",
                                                                ".usd", ".usda", ".usdc", ".usdz"):
        return "model"
    raise ConvertError(f"unsupported file type: {path.name}")


def convert_image(src: Path, out: Path, name: str) -> dict:
    from PIL import Image, ImageOps
    try:
        import pillow_heif
        pillow_heif.register_heif_opener()
        if hasattr(pillow_heif, "register_avif_opener"):
            pillow_heif.register_avif_opener()
    except ImportError:
        pass
    with Image.open(src) as im:
        im.seek(0)  # GIF などは 1 枚目
        im = ImageOps.exif_transpose(im)
        has_alpha = im.mode in ("RGBA", "LA") or (im.mode == "P" and "transparency" in im.info)
        im = im.convert("RGBA" if has_alpha else "RGB")
        im.thumbnail((IMAGE_MAX, IMAGE_MAX))
        dst = out / f"{name}.{'png' if has_alpha else 'jpg'}"
        # exif を渡さずに保存 = 位置情報などのメタデータは残らない
        im.save(dst, **({"optimize": True} if has_alpha else {"quality": 88}))
        size = im.size
    return {"kind": "painting", "media": "image", "files": {"main": dst.name},
            "meta": {"width": size[0], "height": size[1], "mb": round(dst.stat().st_size / 1048576, 2)}}


def convert_video(src: Path, out: Path, name: str) -> dict:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise ConvertError("ffmpeg not found")
    dst = out / f"{name}.ogv"
    poster = out / f"{name}_poster.jpg"
    scale = f"scale='if(gt(iw,ih),min({VIDEO_MAX},iw),-2)':'if(gt(iw,ih),-2,min({VIDEO_MAX},ih))'"
    run([ffmpeg, "-v", "error", "-y", "-i", str(src), "-map", "0:v:0", "-an", "-map_metadata", "-1",
         "-vf", f"{scale},fps=30,format=yuv420p", "-c:v", "libtheora", "-q:v", "5", str(dst)])
    run([ffmpeg, "-v", "error", "-y", "-i", str(dst), "-frames:v", "1", "-q:v", "3", str(poster)])
    probe = run([shutil.which("ffprobe") or "ffprobe", "-v", "error", "-show_entries",
                 "stream=width,height:format=duration", "-of", "json", str(dst)], capture=True)
    info = json.loads(probe)
    st = info["streams"][0]
    return {"kind": "painting", "media": "video", "files": {"main": dst.name, "poster": poster.name},
            "meta": {"width": st["width"], "height": st["height"],
                     "seconds": round(float(info["format"]["duration"]), 1),
                     "mb": round(dst.stat().st_size / 1048576, 2)}}


def convert_model(src: Path, out: Path, name: str, target: int = 60000, exclude: str = "") -> dict:
    if not Path(BLENDER).exists():
        raise ConvertError(f"Blender not found: {BLENDER}")
    cmd = [BLENDER, "-b"]
    if src.suffix.lower() == ".blend":
        cmd += [str(src), "--python", str(CONVERT_BLEND), "--", str(out), name, str(target), exclude]
    else:
        cmd += ["--python", str(CONVERT_BLEND), "--", str(out), name, str(target), exclude, "--import", str(src)]
    run(cmd)
    report = json.loads((out / f"{name}_report.json").read_text(encoding="utf-8"))
    return {"kind": "model", "media": "model", "files": {"main": f"{name}_lite.glb", "hq": f"{name}.glb"},
            "meta": {k: report.get(k) for k in ("triangles_original", "triangles_lite", "original_mb", "lite_mb",
                                                "static_pose", "excluded")}}


def run(cmd: list, capture: bool = False) -> str:
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise ConvertError(f"{Path(cmd[0]).name} failed: {(r.stderr or r.stdout)[-500:]}")
    return r.stdout if capture else ""


def convert(src: Path, out: Path, name: str | None = None, **kw) -> dict:
    out.mkdir(parents=True, exist_ok=True)
    name = name or src.stem
    kind = sniff(src)
    result = {"image": convert_image, "video": convert_video}.get(kind, None)
    data = result(src, out, name) if result else convert_model(src, out, name, **kw)
    data["source"] = {"name": src.name, "mb": round(src.stat().st_size / 1048576, 2), "detected": kind}
    (out / f"{name}_media.json").write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    return data


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    try:
        print(json.dumps(convert(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3] if len(sys.argv) > 3 else None),
                         ensure_ascii=False, indent=2))
    except ConvertError as e:
        print(json.dumps({"error": str(e)}, ensure_ascii=False))
        sys.exit(2)
