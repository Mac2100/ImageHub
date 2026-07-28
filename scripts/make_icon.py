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

    body_half_w = 0.255 * W
    body_half_h = 0.150 * W
    body_radius = 0.052 * W
    centre = W / 2.0
    # Nudge the drive body up so the plus sits in optical centre.
    body_cy = centre - 0.012 * W

    inner_half_w = body_half_w - GLYPH_STROKE
    inner_half_h = body_half_h - GLYPH_STROKE
    inner_radius = max(body_radius - GLYPH_STROKE, 1.0)

    led_cx = centre - body_half_w + GLYPH_STROKE * 2.6
    led_r = 0.024 * W

    plus_cx = centre + body_half_w - GLYPH_STROKE * 2.9
    plus_arm = 0.055 * W
    plus_thickness = GLYPH_STROKE * 0.86

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

            # Drive body outline.
            in_body = rounded_rect_coverage(x, y, centre, body_cy,
                                            body_half_w, body_half_h, body_radius)
            in_hole = rounded_rect_coverage(x, y, centre, body_cy,
                                            inner_half_w, inner_half_h, inner_radius)
            white = bool(in_body and not in_hole)

            if not white and in_hole:
                # Activity LED.
                if math.hypot(x - led_cx, y - body_cy) <= led_r:
                    white = True
                # Plus sign.
                elif (abs(x - plus_cx) <= plus_arm and abs(y - body_cy) <= plus_thickness / 2) or \
                     (abs(y - body_cy) <= plus_arm and abs(x - plus_cx) <= plus_thickness / 2):
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
