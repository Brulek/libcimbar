#!/usr/bin/env python3
"""Generate brand assets (BrandMark, BrandLockup) from the icon source.

Source: scripts/icon-source.png (the master illustration)

Outputs into Assets.xcassets:
  - BrandMark.imageset    — square mark with the icon's own dark backdrop,
                            tightly cropped to the firefly subject
  - BrandLockup.imageset  — horizontal lockup: mark + 萤传 + tagline,
                            transparent background for use on dark surfaces

Run: python3 scripts/make_logo.py
"""
from __future__ import annotations
import math
import os
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
ASSETS_ROOT = ROOT / "Support" / "Assets.xcassets"
SOURCE = Path(__file__).resolve().parent / "icon-source.png"

CN_FONT_CANDIDATES = [
    "/System/Library/AssetsV2/com_apple_MobileAsset_Font8/86ba2c91f017a3749571a82f2c6d890ac7ffb2fb.asset/AssetData/PingFang.ttc",
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
]


def find_font_path() -> str:
    for p in CN_FONT_CANDIDATES:
        if os.path.exists(p):
            return p
    raise RuntimeError("No Chinese font found")


def load_font(size: int, indices=(4, 5, 1, 0)) -> ImageFont.FreeTypeFont:
    path = find_font_path()
    last = None
    for idx in indices:
        try:
            return ImageFont.truetype(path, size=size, index=idx)
        except Exception as e:
            last = e
    if last:
        raise last
    return ImageFont.truetype(path, size=size)


def load_master() -> Image.Image:
    img = Image.open(SOURCE).convert("RGB")
    if img.size[0] != img.size[1]:
        side = min(img.size)
        left = (img.size[0] - side) // 2
        top = (img.size[1] - side) // 2
        img = img.crop((left, top, left + side, top + side))
    return img.resize((1024, 1024), Image.LANCZOS)


def render_mark(size: int = 1024, padding: float = 0.06) -> Image.Image:
    """Tightly cropped firefly mark on its native dark backdrop, square."""
    src = load_master()
    # Source already has tight composition; trim small uniform padding
    pad_px = int(src.size[0] * padding)
    cropped = src.crop((pad_px, pad_px,
                        src.size[0] - pad_px, src.size[1] - pad_px))
    return cropped.resize((size, size), Image.LANCZOS)


def render_lockup_horizontal(width: int = 2400, with_backdrop: bool = False) -> Image.Image:
    """Horizontal lockup: mark | 萤传 + tagline."""
    height = width * 5 // 12

    # Background
    if with_backdrop:
        # Use the dominant indigo from the source as backdrop
        bg = Image.new("RGB", (width, height), (10, 10, 36))
        img = bg.convert("RGBA")
    else:
        img = Image.new("RGBA", (width, height), (0, 0, 0, 0))

    # Mark on the left — square at full height, with rounded corners so it
    # reads as a "badge"
    mark_size = int(height * 0.92)
    mark = render_mark(mark_size, padding=0.04).convert("RGBA")
    mark = round_corners(mark, radius=int(mark_size * 0.22))
    pad_left = int(height * 0.04)
    img.paste(mark, (pad_left, (height - mark_size) // 2), mark)

    # Wordmark text on the right
    text_x = pad_left + mark_size + int(height * 0.10)
    title_size = int(height * 0.50)
    title_font = load_font(title_size, indices=(4, 5, 1, 0))
    tagline_size = int(height * 0.15)
    tagline_font = load_font(tagline_size, indices=(2, 1, 0))

    title = "萤传"
    tagline = "扫一扫，文件就来了"

    text_color = (255, 252, 232, 255)
    sub_color = (255, 200, 110, 255)

    d = ImageDraw.Draw(img)
    title_bbox = d.textbbox((0, 0), title, font=title_font)
    tagline_bbox = d.textbbox((0, 0), tagline, font=tagline_font)
    title_h = title_bbox[3] - title_bbox[1]
    tagline_h = tagline_bbox[3] - tagline_bbox[1]
    gap = int(height * 0.04)
    block_h = title_h + gap + tagline_h
    text_top = (height - block_h) // 2 - title_bbox[1]
    d.text((text_x, text_top), title, font=title_font, fill=text_color)

    tagline_y = text_top + title_h + gap - tagline_bbox[1] + title_bbox[1]
    d.text((text_x, tagline_y), tagline, font=tagline_font, fill=sub_color)

    return img


def round_corners(img: Image.Image, radius: int) -> Image.Image:
    """Apply rounded-corner mask to a square RGBA image."""
    if img.mode != "RGBA":
        img = img.convert("RGBA")
    mask = Image.new("L", img.size, 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1],
                        radius=radius, fill=255)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def write_imageset(name: str, image: Image.Image, base_size: tuple[int, int]) -> None:
    out = ASSETS_ROOT / f"{name}.imageset"
    out.mkdir(parents=True, exist_ok=True)
    bw, bh = base_size
    for scale in (1, 2, 3):
        resized = image.resize((bw * scale, bh * scale), Image.LANCZOS)
        resized.save(out / f"{name}@{scale}x.png", format="PNG", optimize=True)
    contents = f'''{{
  "images" : [
    {{
      "filename" : "{name}@1x.png",
      "idiom" : "universal",
      "scale" : "1x"
    }},
    {{
      "filename" : "{name}@2x.png",
      "idiom" : "universal",
      "scale" : "2x"
    }},
    {{
      "filename" : "{name}@3x.png",
      "idiom" : "universal",
      "scale" : "3x"
    }}
  ],
  "info" : {{
    "author" : "xcode",
    "version" : 1
  }}
}}
'''
    (out / "Contents.json").write_text(contents)
    print(f"  wrote {name}.imageset/  ({bw}×{bh} base)")


def main() -> None:
    # Tightly cropped square mark with rounded corners (badge style),
    # rendered into the BrandMark.imageset for use anywhere in-app.
    mark = render_mark(1024)
    mark_rgba = round_corners(mark, radius=int(1024 * 0.22))
    mark_rgba.save(Path(__file__).resolve().parent / "logo-mark-1024.png", format="PNG")
    write_imageset("BrandMark", mark_rgba, (160, 160))

    # Horizontal lockup — transparent for in-app use on dark backgrounds
    lockup = render_lockup_horizontal(width=2400, with_backdrop=False)
    lockup.save(Path(__file__).resolve().parent / "logo-lockup.png", format="PNG")
    write_imageset("BrandLockup", lockup, (240, 100))

    # Backdrop preview for marketing / docs
    preview = render_lockup_horizontal(width=2400, with_backdrop=True)
    preview.save(Path(__file__).resolve().parent / "logo-lockup-preview.png", format="PNG")

    print("Done.")


if __name__ == "__main__":
    main()
