#!/usr/bin/env python3
"""Generate AppIcon assets for 萤传 (Lumen) from a source PNG.

Source file: scripts/icon-source.png — the master 1024+ image.

Outputs:
  - All 15 iOS AppIcon.appiconset PNG sizes (opaque)
  - scripts/icon-master-1024.png — clean 1024 master used by other scripts

Run: python3 scripts/make_icon.py
"""
from __future__ import annotations
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ICON_DIR = ROOT / "Support" / "Assets.xcassets" / "AppIcon.appiconset"
SOURCE = Path(__file__).resolve().parent / "icon-source.png"

SPEC = [
    ("Icon-20@1x.png", 20),
    ("Icon-20@2x.png", 40),
    ("Icon-20@3x.png", 60),
    ("Icon-29@1x.png", 29),
    ("Icon-29@2x.png", 58),
    ("Icon-29@3x.png", 87),
    ("Icon-40@1x.png", 40),
    ("Icon-40@2x.png", 80),
    ("Icon-40@3x.png", 120),
    ("Icon-60@2x.png", 120),
    ("Icon-60@3x.png", 180),
    ("Icon-76@1x.png", 76),
    ("Icon-76@2x.png", 152),
    ("Icon-83.5@2x.png", 167),
    ("Icon-1024@1x.png", 1024),
]


def load_master() -> Image.Image:
    if not SOURCE.exists():
        raise FileNotFoundError(f"Source icon not found at {SOURCE}")
    img = Image.open(SOURCE).convert("RGBA")
    # Normalise to a square 1024 master (LANCZOS for clean downsample)
    if img.size[0] != img.size[1]:
        side = min(img.size)
        left = (img.size[0] - side) // 2
        top = (img.size[1] - side) // 2
        img = img.crop((left, top, left + side, top + side))
    return img.resize((1024, 1024), Image.LANCZOS)


def flatten(rgba: Image.Image, bg=(0, 0, 0)) -> Image.Image:
    """Flatten RGBA over a solid bg — Apple requires opaque PNGs."""
    out = Image.new("RGB", rgba.size, bg)
    out.paste(rgba, mask=rgba.split()[3] if rgba.mode == "RGBA" else None)
    return out


def main() -> None:
    ICON_DIR.mkdir(parents=True, exist_ok=True)
    master = load_master()

    # Marketing 1024 (opaque)
    flatten(master).save(ICON_DIR / "Icon-1024@1x.png", format="PNG", optimize=True)

    for filename, size in SPEC:
        if filename == "Icon-1024@1x.png":
            continue
        resized = master.resize((size, size), Image.LANCZOS)
        flatten(resized).save(ICON_DIR / filename, format="PNG", optimize=True)
        print(f"  wrote {filename:28s}  {size}×{size}")

    # Save the clean 1024 master for other scripts (e.g. logo lockups)
    master.save(Path(__file__).resolve().parent / "icon-master-1024.png", format="PNG")
    print("  wrote scripts/icon-master-1024.png")


if __name__ == "__main__":
    main()
