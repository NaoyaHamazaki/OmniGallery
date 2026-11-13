"""アイコン / favicon / OGP 画像を生成する開発用スクリプト (生成物はリポジトリに含めているので通常は実行不要)。

    backend\\.venv\\Scripts\\pip install pillow
    backend\\.venv\\Scripts\\python tools\\make_brand_assets.py

出力: backend/static/brand/{favicon.ico, apple-touch-icon.png, icon-512.png, og-image.png}
アイコンの図柄は godot/icon.svg と同じ。
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "backend" / "static" / "brand"
ARTWORKS = ROOT / "backend" / "static" / "artworks"
FONT_DIR = Path("C:/Windows/Fonts")

NAVY = (31, 36, 51)
GOLD = (201, 164, 92)
CANVAS = (242, 235, 221)
SUN = (224, 122, 63)
MOUNTAIN = (47, 93, 115)


def draw_icon(size: int) -> Image.Image:
    s = 4  # 4倍で描いて縮小 (アンチエイリアス)
    img = Image.new("RGBA", (512 * s, 512 * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    k = lambda *v: [x * s for x in v]  # noqa: E731
    d.rounded_rectangle(k(0, 0, 511, 511), radius=104 * s, fill=NAVY)
    d.polygon(k(256, 70, 330, 112, 182, 112), fill=GOLD + (140,))
    d.rounded_rectangle(k(96, 112, 416, 400), radius=12 * s, fill=GOLD)
    d.rectangle(k(126, 142, 386, 370), fill=CANVAS)
    d.ellipse(k(292, 172, 352, 232), fill=SUN)
    d.polygon(k(126, 370, 214, 252, 266, 318, 302, 282, 386, 370), fill=MOUNTAIN)
    return img.resize((size, size), Image.LANCZOS)


def font(names: list[str], size: int) -> ImageFont.FreeTypeFont:
    for n in names:
        p = FONT_DIR / n
        if p.exists():
            return ImageFont.truetype(str(p), size)
    return ImageFont.load_default(size)


def make_og() -> Image.Image:
    W, H = 1200, 630
    img = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(img)
    # 壁: 上から暗く→やや明るいオフホワイト寄りのグラデーション
    for y in range(H):
        t = y / H
        c = tuple(int(a + (b - a) * t) for a, b in zip((26, 28, 36), (58, 52, 46)))
        d.line([(0, y), (W, y)], fill=c)

    picks = [("pearl_earring.jpg", 280, 260), ("starry_night.jpg", 320, 400), ("great_wave.jpg", 280, 300)]
    xs = [205, 600, 995]
    glow = Image.new("L", (W, H), 0)
    gd = ImageDraw.Draw(glow)
    placed = []
    for (name, h, max_w), cx in zip(picks, xs):
        p = ARTWORKS / name
        if not p.exists():
            continue
        art = Image.open(p).convert("RGB")
        w = int(art.width * h / art.height)
        if w > max_w:
            w, h = max_w, int(art.height * max_w / art.width)
        art = art.resize((w, h), Image.LANCZOS)
        x, y = cx - w // 2, 60 + (320 - h) // 2
        placed.append((art, x, y))
        gd.ellipse([cx - 260, y - 120, cx + 260, y + h + 140], fill=110)  # スポットライトの光だまり
    glow = glow.filter(ImageFilter.GaussianBlur(70))
    img = Image.composite(Image.new("RGB", (W, H), (255, 214, 160)), img, glow.point(lambda v: int(v * 0.55)))
    d = ImageDraw.Draw(img)
    for art, x, y in placed:
        f = 14
        d.rectangle([x - f + 6, y - f + 10, x + art.width + f + 6, y + art.height + f + 10], fill=(18, 16, 14))
        d.rectangle([x - f, y - f, x + art.width + f, y + art.height + f], fill=(92, 64, 38))
        d.rectangle([x - 3, y - 3, x + art.width + 3, y + art.height + 3], fill=(201, 164, 92))
        img.paste(art, (x, y))

    # 床
    d.rectangle([0, 455, W, H], fill=(48, 34, 24))
    d.line([(0, 455), (W, 455)], fill=(90, 70, 52), width=3)

    icon = draw_icon(96)
    title_font = font(["georgiab.ttf", "timesbd.ttf", "arialbd.ttf"], 64)
    sub_font = font(["YuGothB.ttc", "meiryob.ttc", "meiryo.ttc", "msgothic.ttc"], 30)
    title = "OmniGallery"
    tw = d.textlength(title, font=title_font)
    total = 96 + 24 + tw
    x0 = int((W - total) / 2)
    img.paste(icon, (x0, 482), icon)
    d.text((x0 + 120, 488), title, font=title_font, fill=(246, 240, 228))
    sub = "ブラウザで歩ける、バーチャル美術館"
    sw = d.textlength(sub, font=sub_font)
    d.text(((W - sw) / 2, 572), sub, font=sub_font, fill=(214, 196, 160))
    return img


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    big = draw_icon(512)
    big.save(OUT / "icon-512.png")
    draw_icon(180).save(OUT / "apple-touch-icon.png")
    big.save(OUT / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48), (64, 64)])
    make_og().save(OUT / "og-image.png", optimize=True)
    # Godot の起動スプラッシュ (背景色は project.godot の boot_splash/bg_color と同じ紺色)
    splash = Image.new("RGBA", (640, 400), NAVY + (255,))
    splash.paste(draw_icon(220), (210, 40), draw_icon(220))
    d = ImageDraw.Draw(splash)
    f = font(["georgiab.ttf", "timesbd.ttf", "arialbd.ttf"], 46)
    w = d.textlength("OmniGallery", font=f)
    d.text(((640 - w) / 2, 285), "OmniGallery", font=f, fill=(246, 240, 228))
    splash.save(ROOT / "godot" / "splash.png")
    print("written to", OUT)


if __name__ == "__main__":
    main()
