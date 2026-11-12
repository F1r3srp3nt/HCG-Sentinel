#!/usr/bin/env python3
"""Regenerates the HCG Sentinel app icon set (requires Pillow).

  python3 Tools/generate_app_icon.py
"""
import json
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

OUT = Path(__file__).resolve().parent.parent / "HCGSentinel/Resources/Assets.xcassets/AppIcon.appiconset"
SPECS = [  # (idiom, point size, scale)
    ("iphone", 20, 2), ("iphone", 20, 3), ("iphone", 29, 2), ("iphone", 29, 3), ("iphone", 40, 2), ("iphone", 40, 3),
    ("iphone", 60, 2), ("iphone", 60, 3), ("ipad", 20, 1), ("ipad", 20, 2), ("ipad", 29, 1), ("ipad", 29, 2),
    ("ipad", 40, 1), ("ipad", 40, 2), ("ipad", 76, 1), ("ipad", 76, 2), ("ipad", 83.5, 2), ("ios-marketing", 1024, 1),
]


def master(size=2048):
    image = Image.new("RGB", (size, size), (8, 9, 13))
    pixels = image.load()
    centre = size / 2
    for y in range(size):
        for x in range(size):
            d = math.hypot(x - centre, y - centre) / centre
            lift = max(0.0, 1 - d) ** 2
            pixels[x, y] = (int(8 + 16 * lift), int(9 + 19 * lift), int(13 + 26 * lift))
    draw = ImageDraw.Draw(image)

    def ring(radius, width, colour):
        box = [centre - radius, centre - radius, centre + radius, centre + radius]
        draw.ellipse(box, outline=colour, width=width)

    def arc(radius, width, start, end, colour):
        box = [centre - radius, centre - radius, centre + radius, centre + radius]
        draw.arc(box, start, end, fill=colour, width=width)

    # Brushed-metal outer ring: alternating light and dark arcs.
    for index in range(72):
        tone = 150 + int(60 * math.sin(index * 0.9)) - (index % 3) * 14
        arc(size * 0.40, int(size * 0.035), index * 5, index * 5 + 5.4, (tone, tone + 3, tone + 9))
    ring(size * 0.365, int(size * 0.004), (40, 44, 52))

    # Cyan illumination layer, blurred for glow and redrawn sharp on top.
    glow = Image.new("RGB", (size, size), (0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    box = [centre - size * 0.27, centre - size * 0.27, centre + size * 0.27, centre + size * 0.27]
    glow_draw.arc(box, 200, 340, fill=(64, 222, 245), width=int(size * 0.03))
    glow_draw.ellipse([centre - size * 0.05, centre - size * 0.05, centre + size * 0.05, centre + size * 0.05], fill=(64, 222, 245))
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.03))
    image = ImageChops.screen(image, glow)
    draw = ImageDraw.Draw(image)
    arc(size * 0.27, int(size * 0.022), 200, 340, (64, 222, 245))
    arc(size * 0.19, int(size * 0.012), 215, 325, (40, 150, 170))
    draw.ellipse([centre - size * 0.045, centre - size * 0.045, centre + size * 0.045, centre + size * 0.045], fill=(120, 236, 252))
    # Restrained violet marker.
    arc(size * 0.27, int(size * 0.022), 28, 52, (168, 145, 252))
    return image


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    source = master()
    images = []
    for idiom, points, scale in SPECS:
        pixels = int(round(points * scale))
        name = f"icon-{idiom}-{points}@{scale}x.png"
        source.resize((pixels, pixels), Image.LANCZOS).save(OUT / name, optimize=True)
        size_text = f"{points:g}x{points:g}"
        images.append({"filename": name, "idiom": idiom, "scale": f"{scale}x", "size": size_text})
    (OUT / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    print(f"wrote {len(images)} icons to {OUT}")


if __name__ == "__main__":
    main()
