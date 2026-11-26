#!/usr/bin/env python3
"""Generate the SUNNATI Android launcher icon (Phase 1).

Original geometric drawing — no copied logo, no stock art:
an open book (two pages) under a small dome with a star, drawn in
deep petrol blue (#0F3B4D) with matte gold (#B89B5E) details on a warm
ivory (#F7F2E9) rounded-square background. NO green anywhere — the
corrected identity (owner decision 2026-11-25) is petrol + ivory +
matte gold, with only a faint blush (#E8CFC8) accent in one corner.

Usage:
    python3 tools/make_icon.py --out android/app/src/main/res
Writes ic_launcher.png into mipmap-mdpi/hdpi/xhdpi/xxhdpi/xxxhdpi
(48/72/96/144/192 px) plus a 512 px foreground preview at the repo root
of the output dir (icon-preview-512.png, not shipped in the APK).

Requires Pillow: pip install Pillow
"""
from __future__ import annotations

import argparse
import math
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError as exc:  # pragma: no cover
    raise SystemExit("Pillow is required: pip install Pillow") from exc

# Corrected identity palette — petrol / warm ivory / matte gold / blush.
PETROL = (15, 59, 77, 255)
DEEP_PETROL = (10, 42, 56, 255)
GOLD = (184, 155, 94, 255)
IVORY = (247, 242, 233, 255)
BLUSH = (232, 207, 200, 255)

SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}


def _rounded_square(draw: ImageDraw.ImageDraw, size: int) -> None:
    r = int(size * 0.16)
    draw.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=IVORY)


def _star(draw: ImageDraw.ImageDraw, cx: float, cy: float, r: float, fill) -> None:
    pts = []
    for i in range(10):
        ang = math.pi / 2 + i * math.pi / 5
        rad = r if i % 2 == 0 else r * 0.42
        pts.append((cx + rad * math.cos(ang), cy - rad * math.sin(ang)))
    draw.polygon(pts, fill=fill)


def draw_icon(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    _rounded_square(draw, size)

    # Faint blush corner touch (very limited, per the identity).
    blush_r = size * 0.20
    draw.ellipse(
        [size - blush_r, -blush_r * 0.45, size + blush_r * 0.45, blush_r * 0.55],
        fill=BLUSH,
    )

    cx = size / 2
    # --- Dome (petrol) above the book ---
    dome_top = size * 0.13
    dome_base = size * 0.42
    dome_w = size * 0.34
    draw.pieslice(
        [cx - dome_w / 2, dome_top, cx + dome_w / 2, dome_base + dome_w * 0.28],
        start=180,
        end=360,
        fill=PETROL,
    )
    draw.rectangle(
        [cx - dome_w / 2, dome_base - size * 0.02, cx + dome_w / 2, dome_base + size * 0.02],
        fill=PETROL,
    )
    # Finial + star (matte gold).
    draw.line([cx, dome_top - size * 0.05, cx, dome_top], fill=GOLD, width=max(2, size // 64))
    _star(draw, cx, dome_top - size * 0.075, size * 0.035, GOLD)

    # --- Open book (petrol cover, ivory pages, gold centre line) ---
    book_top = size * 0.48
    book_bottom = size * 0.86
    book_left = size * 0.14
    book_right = size * 0.86
    # Cover.
    draw.rounded_rectangle(
        [book_left, book_top, book_right, book_bottom],
        radius=size * 0.03,
        fill=PETROL,
    )
    # Left + right pages (ivory, inset).
    inset = size * 0.025
    mid = cx
    draw.polygon(
        [(book_left + inset, book_top + inset),
         (mid - inset / 2, book_top + inset + size * 0.02),
         (mid - inset / 2, book_bottom - inset),
         (book_left + inset, book_bottom - inset)],
        fill=IVORY,
    )
    draw.polygon(
        [(mid + inset / 2, book_top + inset + size * 0.02),
         (book_right - inset, book_top + inset),
         (book_right - inset, book_bottom - inset),
         (mid + inset / 2, book_bottom - inset)],
        fill=IVORY,
    )
    # Centre spine (gold) + two gold text lines per page.
    draw.line([mid, book_top + inset, mid, book_bottom - inset], fill=GOLD, width=max(2, size // 72))
    for y in (0.60, 0.68):
        yy = size * y
        draw.line([book_left + size * 0.07, yy, mid - size * 0.05, yy], fill=GOLD, width=max(1, size // 96))
        draw.line([mid + size * 0.05, yy, book_right - size * 0.07, yy], fill=GOLD, width=max(1, size // 96))
    # Gold rule under the book.
    draw.line(
        [book_left + size * 0.06, book_bottom + size * 0.03, book_right - size * 0.06, book_bottom + size * 0.03],
        fill=GOLD,
        width=max(2, size // 72),
    )
    # Thin petrol border inside the ivory tile.
    draw.rounded_rectangle(
        [size * 0.02, size * 0.02, size * 0.98, size * 0.98],
        radius=size * 0.15,
        outline=DEEP_PETROL,
        width=max(1, size // 128),
    )
    return img


def main() -> None:
    ap = argparse.ArgumentParser(description="Generate the SUNNATI launcher icon")
    ap.add_argument("--out", required=True, help="android/app/src/main/res directory")
    args = ap.parse_args()
    out_root = Path(args.out)
    for name, size in SIZES.items():
        target = out_root / name
        target.mkdir(parents=True, exist_ok=True)
        draw_icon(size).save(target / "ic_launcher.png")
        print(f"wrote {target / 'ic_launcher.png'} ({size}px)")
    draw_icon(512).save(out_root / "icon-preview-512.png")
    print(f"wrote {out_root / 'icon-preview-512.png'} (512px preview, not shipped)")


if __name__ == "__main__":
    main()
