#!/usr/bin/env python3
"""Generates Resources/icon_1024.png.

Kept in the repo so the app icon is reproducible and reviewable as code rather
than an opaque binary nobody can regenerate. Pure standard library — no Pillow.

    python3 scripts/make_icon.py
"""

from __future__ import annotations

import math
import os
import struct
import zlib

SIZE = 1024
SUPERSAMPLE = 2          # render at 2x, box-filter down for clean edges
W = SIZE * SUPERSAMPLE

# Matches the "Hub" theme gradient in Sources/ImageHub/Views/Theme.swift.
TOP_LEFT = (41, 102, 235)
BOTTOM_RIGHT = (92, 189, 245)

CORNER_RADIUS = 0.235 * W
GLYPH_STROKE = 0.055 * W


def rounded_rect_coverage(x: float, y: float, cx: float, cy: float,
                          half_w: float, half_h: float, radius: float) -> float:
    """Signed-distance coverage of a rounded rectangle, 1 inside / 0 outside."""
    dx = abs(x - cx) - (half_w - radius)
    dy = abs(y - cy) - (half_h - radius)
    outside = math.hypot(max(dx, 0.0), max(dy, 0.0))
    distance = outside + min(max(dx, dy), 0.0) - radius
    return 1.0 if distance <= 0 else 0.0


def build() -> bytearray:
    rows = bytearray()

    centre = W / 2.0

    # A downward arrow landing on a drive. The previous glyph was a rounded
    # rectangle outline with a dot at one end and a plus at the other, which at
    # icon size read as a game controller rather than anything to do with
    # deployment -- it was mistaken for the wrong app's icon in the Dock.
    #
    # An arrow into a device is the conventional "write this to that" mark, and
    # it survives being shrunk to 16pt in a sidebar, which an outlined body with
    # two small details inside does not.
    stem_half_w = 0.052 * W
    stem_top = 0.235 * W
    stem_bottom = 0.520 * W

    head_top = 0.470 * W
    head_bottom = 0.660 * W
    head_half_w = 0.150 * W

    bar_cy = 0.790 * W
    bar_half_w = 0.250 * W
    bar_half_h = 0.055 * W
    bar_radius = 0.030 * W

    for py in range(W):
        y = py + 0.5
        row = bytearray()
        for px in range(W):
            x = px + 0.5

            # Outer rounded square = the icon silhouette.
            if not rounded_rect_coverage(x, y, centre, centre,
                                         W / 2.0, W / 2.0, CORNER_RADIUS):
                row += b"\x00\x00\x00\x00"
                continue

            # Diagonal gradient.
            t = ((x / W) + (y / W)) / 2.0
            r = round(TOP_LEFT[0] + (BOTTOM_RIGHT[0] - TOP_LEFT[0]) * t)
            g = round(TOP_LEFT[1] + (BOTTOM_RIGHT[1] - TOP_LEFT[1]) * t)
            b = round(TOP_LEFT[2] + (BOTTOM_RIGHT[2] - TOP_LEFT[2]) * t)

            white = False

            # Arrow stem.
            if stem_top <= y <= stem_bottom and abs(x - centre) <= stem_half_w:
                white = True

            # Arrow head: a triangle tapering to a point at the bottom.
            if not white and head_top <= y <= head_bottom:
                span = head_half_w * (1.0 - (y - head_top) / (head_bottom - head_top))
                if abs(x - centre) <= span:
                    white = True

            # The drive it lands on.
            if not white and rounded_rect_coverage(x, y, centre, bar_cy,
                                                   bar_half_w, bar_half_h, bar_radius):
                white = True

            if white:
                r = g = b = 255

            row += bytes((r, g, b, 255))
        rows.append(0)  # PNG filter type 0
        rows += row
    return rows


def downsample(raw: bytearray) -> bytes:
    """Box-filters the supersampled buffer down to SIZE x SIZE."""
    stride = W * 4 + 1
    out = bytearray()
    factor = SUPERSAMPLE
    area = factor * factor

    for oy in range(SIZE):
        out.append(0)
        for ox in range(SIZE):
            r = g = b = a = 0
            for sy in range(factor):
                base = (oy * factor + sy) * stride + 1 + (ox * factor) * 4
                for sx in range(factor):
                    offset = base + sx * 4
                    r += raw[offset]
                    g += raw[offset + 1]
                    b += raw[offset + 2]
                    a += raw[offset + 3]
            out += bytes((r // area, g // area, b // area, a // area))
    return bytes(out)


def chunk(tag: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def main() -> None:
    pixels = downsample(build())
    header = struct.pack(">2I5B", SIZE, SIZE, 8, 6, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", header)
           + chunk(b"IDAT", zlib.compress(pixels, 9))
           + chunk(b"IEND", b""))

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    target = os.path.join(root, "Resources", "icon_1024.png")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "wb") as handle:
        handle.write(png)
    print(f"wrote {target} ({len(png):,} bytes)")


if __name__ == "__main__":
    main()
