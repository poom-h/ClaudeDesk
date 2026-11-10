#!/usr/bin/env python3
"""Build design/icon/AppIcon.icns from design/icon/source.png (tile on transparent background)."""
import subprocess, sys
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parent.parent
src = Image.open(root / "design/icon/source.png").convert("RGBA")

# The source already has a transparent background; crop to the tile's opaque bounds.
tile = src.crop(src.getchannel("A").point(lambda v: 255 if v > 200 else 0).getbbox())

# macOS icon grid: 824pt tile centred on a 1024pt canvas.
canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
t = tile.resize((824, 824), Image.LANCZOS)
canvas.alpha_composite(t, (100, 100))
canvas.save(root / "design/icon/AppIcon-1024.png")

iconset = root / "design/icon/AppIcon.iconset"
iconset.mkdir(exist_ok=True)
for size in (16, 32, 128, 256, 512):
    canvas.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
    canvas.resize((size * 2, size * 2), Image.LANCZOS).save(iconset / f"icon_{size}x{size}@2x.png")
subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(root / "design/icon/AppIcon.icns")], check=True)
print("wrote design/icon/AppIcon.icns")
