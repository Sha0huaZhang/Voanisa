#!/usr/bin/env python3
"""Draw the source artwork for the Voanisa app icon.

Usage:
    python3 Scripts/generate-icon-source.py

The result is written to images/Voanisa-icon-1024.png and then turned into a
macOS icon set by Scripts/generate-appicon.py.

Requires Pillow.
"""
import os

from PIL import Image, ImageDraw

SIZE = 1024
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "images", "Voanisa-icon-1024.png")

TOP_LEFT = (45, 32, 190)
BOTTOM_RIGHT = (0, 194, 168)


def lerp(a, b, t):
    return round(a + (b - a) * t)


def main():
    image = Image.new("RGB", (SIZE, SIZE))
    pixels = image.load()
    for y in range(SIZE):
        for x in range(SIZE):
            t = (x + y) / (2 * (SIZE - 1))
            t = t * t * (3 - 2 * t)
            pixels[x, y] = (
                lerp(TOP_LEFT[0], BOTTOM_RIGHT[0], t),
                lerp(TOP_LEFT[1], BOTTOM_RIGHT[1], t),
                lerp(TOP_LEFT[2], BOTTOM_RIGHT[2], t),
            )

    draw = ImageDraw.Draw(image, "RGBA")

    heights = [150, 260, 420, 560, 420, 260, 150]
    bar_width = 64
    gap = 36
    total = len(heights) * bar_width + (len(heights) - 1) * gap
    start_x = (SIZE - total) // 2

    for index, height in enumerate(heights):
        x0 = start_x + index * (bar_width + gap)
        x1 = x0 + bar_width
        y0 = (SIZE - height) // 2
        y1 = y0 + height
        draw.rounded_rectangle((x0, y0, x1, y1), radius=bar_width // 2, fill=(255, 255, 255, 235))

    # A small red accent ties the icon to the player's red playback state.
    draw.ellipse((748, 214, 868, 334), fill=(255, 59, 72, 255))
    draw.polygon([(792, 250), (792, 298), (832, 274)], fill=(255, 255, 255, 255))

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    image.save(OUT)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
