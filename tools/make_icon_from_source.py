#!/usr/bin/env python3
"""Generate the SUNNATI Android launcher icon from the owner's v2 image.

Replaces tools/make_icon.py (retired 2026-11-26: it drew a geometric
book+dome with Pillow and never used the owner's image).

Source: tools/icon-source.png — the file is NAMED .png but its bytes are
JPEG (JFIF, 1254x1254, RGB), so Pillow opens it by content, not by
extension, and the output here is real PNG (Android's aapt2 requires PNG
for launcher icons). The source is a rounded-square artwork tile on a
BLACK background: the black corners are part of the delivered file, not
part of the artwork, so the pipeline crops to the tile's bounding box
(non-black pixels) and then flood-fills the black surround outside the
tile's rounded corners to transparency. The tile's own corners are warm
ivory, so it blends seamlessly onto the ivory background.

Outputs (under android/app/src/main/res):
  mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png
      legacy icon, 48/72/96/144/192 px — full artwork on warm ivory.
  mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher_foreground.png
      adaptive-icon foreground, 108/162/216/324/432 px (108dp) — the
      artwork scaled to FOREGROUND_SCALE of the canvas, centred on
      transparency, so launcher masks (circle / squircle) do not clip
      the book, the calligraphy or the dome. The ivory background comes
      from @color/ic_launcher_background (values/colors.xml).
  mipmap-anydpi-v26/ic_launcher.xml + ic_launcher_round.xml
      adaptive-icon definitions (background + foreground).

No pubspec.yaml change is needed: Android launcher icons are Android
resources, not Flutter assets.

Usage:
    pip install Pillow
    python3 tools/make_icon_from_source.py [--out android/app/src/main/res]
    python3 tools/make_icon_from_source.py --check
        also writes masked previews (circle + squircle) to
        /tmp/sunnati-icon-check/ for visual verification.

Requires Pillow: pip install Pillow
"""
from __future__ import annotations

import argparse
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError as exc:  # pragma: no cover
    raise SystemExit("Pillow is required: pip install Pillow") from exc

# Corrected identity: warm ivory background (matches theme.dart ivory
# 0xFFF7F2E9 and values/colors.xml launch_background).
IVORY = (247, 242, 233, 255)
TRANSPARENT = (0, 0, 0, 0)

# Legacy launcher sizes (px) per density.
LEGACY_SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

# Adaptive-icon foreground canvas is 108dp; px per density.
FOREGROUND_SIZES = {
    "mipmap-mdpi": 108,
    "mipmap-hdpi": 162,
    "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324,
    "mipmap-xxxhdpi": 432,
}

# Fraction of the 108dp foreground canvas the artwork spans. 0.70 keeps
# the book, the «السنة النبوية» calligraphy, the dome and the inkwell
# inside the 66dp safe zone / inscribed circle of every launcher mask,
# while staying large and legible. Verified visually with --check
# (circle + squircle masked previews).
FOREGROUND_SCALE = 0.70

ADAPTIVE_XML = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
"""


def load_artwork(source: Path) -> Image.Image:
    """Open the owner's image (JPEG bytes, .png name) and crop the tile.

    Returns the artwork as RGBA: the rounded-square tile with its black
    surround removed. The tile's own corners are ivory, so the cropped
    image blends onto an ivory canvas with no visible seam.
    """
    img = Image.open(source)
    print(f"source: {source} (format={img.format}, size={img.size}, "
          f"mode={img.mode})")
    if img.format != "JPEG":
        print(f"NOTE: source format is {img.format}, expected JPEG "
              f"(the file is named .png but holds JPEG bytes).")
    rgb = img.convert("RGB")
    w, h = rgb.size
    px = rgb.load()
    # Bounding box of non-black pixels. The surround is pure black
    # (0,0,0); the tile edge is ivory, so a low threshold is safe.
    min_x, min_y, max_x, max_y = w, h, -1, -1
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            if r + g + b > 60:
                if x < min_x:
                    min_x = x
                if x > max_x:
                    max_x = x
                if y < min_y:
                    min_y = y
                if y > max_y:
                    max_y = y
    if max_x < 0:
        raise SystemExit(f"{source}: no non-black pixels found")
    # Inset 2 px to drop any anti-aliased dark fringe on the tile edge.
    min_x, min_y = min_x + 2, min_y + 2
    max_x, max_y = max_x - 2, max_y - 2
    print(f"tile bbox: x {min_x}..{max_x}, y {min_y}..{max_y} "
          f"({max_x - min_x + 1}x{max_y - min_y + 1})")
    tile = rgb.crop((min_x, min_y, max_x + 1, max_y + 1))
    return _remove_black_surround(tile.convert("RGBA"))


def _remove_black_surround(tile: Image.Image) -> Image.Image:
    """Make the black surround OUTSIDE the tile's rounded corners
    transparent.

    The cropped tile is a rectangle, but the artwork is a rounded
    square: the bbox corners are black surround, not artwork (verified
    by pixel sampling — legacy corners were (0,0,0,255) before this
    fix). Flood-fill from the image border through near-black pixels
    only: the artwork's own dark pixels (petrol book, inkwell) are
    enclosed by bright ivory and can never be reached, and the fill
    threshold (sum < 120) stops at the petrol wave that touches the
    tile's bottom edge. A 1 px blur on the resulting alpha softens the
    JPEG fringe on the tile edge.
    """
    import numpy as np
    from PIL import ImageFilter

    a = np.asarray(tile).astype(int)
    dark = a[:, :, 0] + a[:, :, 1] + a[:, :, 2] < 120
    h, w = dark.shape
    # Seed: border pixels that are dark. Dilate the seed through dark
    # pixels only, until stable (absorbs the anti-aliased fringe).
    surround = np.zeros((h, w), dtype=bool)
    surround[0, :] = dark[0, :]
    surround[-1, :] = dark[-1, :]
    surround[:, 0] = dark[:, 0]
    surround[:, -1] = dark[:, -1]
    while True:
        grown = surround.copy()
        grown[1:, :] |= surround[:-1, :]
        grown[:-1, :] |= surround[1:, :]
        grown[:, 1:] |= surround[:, :-1]
        grown[:, :-1] |= surround[:, 1:]
        grown &= dark
        if (grown == surround).all():
            break
        surround = grown
    print(f"surround pixels removed: {int(surround.sum())} "
          f"({100.0 * surround.mean():.1f}% of tile)")
    alpha = np.where(surround, 0, 255).astype("uint8")
    alpha_img = Image.fromarray(alpha, mode="L").filter(
        ImageFilter.GaussianBlur(1))
    out = tile.copy()
    out.putalpha(alpha_img)
    return out


def legacy_icon(tile: Image.Image, size: int) -> Image.Image:
    """Full artwork on a warm-ivory square (pre-Oreo launcher icon)."""
    canvas = Image.new("RGBA", (size, size), IVORY)
    art = tile.resize((size, size), Image.LANCZOS)
    canvas.alpha_composite(art)
    return canvas


def foreground_icon(tile: Image.Image, size: int) -> Image.Image:
    """Artwork scaled to FOREGROUND_SCALE, centred on transparency."""
    canvas = Image.new("RGBA", (size, size), TRANSPARENT)
    art_size = max(1, int(round(size * FOREGROUND_SCALE)))
    art = tile.resize((art_size, art_size), Image.LANCZOS)
    canvas.alpha_composite(art, ((size - art_size) // 2,
                                 (size - art_size) // 2))
    return canvas


def masked_preview(tile: Image.Image, size: int, shape: str) -> Image.Image:
    """512 px preview of the adaptive icon under a launcher mask.

    shape 'circle' = inscribed circle; 'squircle' = rounded square
    (corner radius 22%, the Android squircle approximation). The ivory
    background is composited underneath so the preview shows what a
    launcher shows. A thin gold ring marks the 66dp safe-zone circle
    (radius 33% of the canvas) for the circle preview.
    """
    fg = foreground_icon(tile, size)
    base = Image.new("RGBA", (size, size), IVORY)
    base.alpha_composite(fg)
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    if shape == "circle":
        draw.ellipse([0, 0, size - 1, size - 1], fill=255)
    elif shape == "squircle":
        r = int(size * 0.22)
        draw.rounded_rectangle([0, 0, size - 1, size - 1], radius=r,
                               fill=255)
    else:  # pragma: no cover
        raise ValueError(shape)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(base, (0, 0), mask)
    if shape == "circle":
        # 66dp safe-zone guide: radius = 33% of the 108dp canvas.
        guide = ImageDraw.Draw(out)
        sr = int(size * 0.33)
        guide.ellipse([size // 2 - sr, size // 2 - sr,
                       size // 2 + sr, size // 2 + sr],
                      outline=(184, 155, 94, 255), width=max(2, size // 256))
    return out


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Generate the SUNNATI launcher icon from the "
                    "owner's v2 image")
    ap.add_argument("--out", default="android/app/src/main/res",
                    help="android/app/src/main/res directory")
    ap.add_argument("--source", default="tools/icon-source.png",
                    help="owner's v2 image (JPEG bytes, .png name)")
    ap.add_argument("--check", action="store_true",
                    help="also write masked previews to "
                         "/tmp/sunnati-icon-check/")
    args = ap.parse_args()

    out_root = Path(args.out)
    tile = load_artwork(Path(args.source))

    for name, size in LEGACY_SIZES.items():
        target = out_root / name
        target.mkdir(parents=True, exist_ok=True)
        legacy_icon(tile, size).save(target / "ic_launcher.png")
        print(f"wrote {target / 'ic_launcher.png'} ({size}px legacy)")
    for name, size in FOREGROUND_SIZES.items():
        target = out_root / name
        target.mkdir(parents=True, exist_ok=True)
        foreground_icon(tile, size).save(
            target / "ic_launcher_foreground.png")
        print(f"wrote {target / 'ic_launcher_foreground.png'} "
              f"({size}px foreground)")
    anydpi = out_root / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    for fname in ("ic_launcher.xml", "ic_launcher_round.xml"):
        (anydpi / fname).write_text(ADAPTIVE_XML, encoding="utf-8")
        print(f"wrote {anydpi / fname} (adaptive icon)")

    if args.check:
        check_dir = Path("/tmp/sunnati-icon-check")
        check_dir.mkdir(parents=True, exist_ok=True)
        legacy_icon(tile, 512).save(check_dir / "legacy-512.png")
        foreground_icon(tile, 512).save(check_dir / "foreground-512.png")
        masked_preview(tile, 512, "circle").save(
            check_dir / "masked-circle-512.png")
        masked_preview(tile, 512, "squircle").save(
            check_dir / "masked-squircle-512.png")
        print(f"wrote previews to {check_dir}/")


if __name__ == "__main__":
    main()
