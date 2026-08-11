#!/usr/bin/env python3
"""Draws Windows/App/Assets/ImageHub.ico from the same mark the apps display.

The macOS side renders its icon from the SF Symbol the app itself puts on screen
(scripts/make_icon.swift), which needs macOS. Windows needs a multi-resolution
.ico and the runners that build it have no image tooling, so the shape is drawn
here in pure Python -- no Pillow, no ImageMagick -- from the same geometry and
the same "Hub" gradient as AppTheme.glyph in Sources/ImageHub/Views/Theme.swift.

Run it after changing the mark; the .ico is committed so a build needs nothing.
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

# AppTheme "Hub": primary Color(0.16, 0.40, 0.92), secondary Color(0.36, 0.74, 0.96).
PRIMARY = (41, 102, 235)
SECONDARY = (92, 189, 245)

SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)
SUPERSAMPLE = 4

# Fractions of the canvas, so every size is the same drawing.
TILE_RADIUS = 0.235          # matches the 0.24 corner radius of the SwiftUI glyph
DRIVE = (0.205, 0.315, 0.795, 0.685)
DRIVE_RADIUS = 0.072
LED = (0.715, 0.500, 0.036)


def rounded_rect_contains(x: float, y: float, box, radius: float) -> bool:
    x0, y0, x1, y1 = box
    if x < x0 or x > x1 or y < y0 or y > y1:
        return False
    # Corner circles; the straight edges are covered by the box test above.
    for cx, cy in ((x0 + radius, y0 + radius), (x1 - radius, y0 + radius),
                   (x0 + radius, y1 - radius), (x1 - radius, y1 - radius)):
        near_x = (x < x0 + radius) if cx < (x0 + x1) / 2 else (x > x1 - radius)
        near_y = (y < y0 + radius) if cy < (y0 + y1) / 2 else (y > y1 - radius)
        if near_x and near_y:
            return (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2
    return True


def render(size: int) -> bytes:
    """Returns raw RGBA bytes for one square icon."""
    hi = size * SUPERSAMPLE
    samples = SUPERSAMPLE * SUPERSAMPLE

    # Accumulate coverage of the tile and of the white glyph separately, so the
    # glyph's edge antialiases against the gradient rather than against nothing.
    tile = bytearray(hi * hi)
    glyph = bytearray(hi * hi)
    for py in range(hi):
        v = (py + 0.5) / hi
        row = py * hi
        for px in range(hi):
            u = (px + 0.5) / hi
            if rounded_rect_contains(u, v, (0.0, 0.0, 1.0, 1.0), TILE_RADIUS):
                tile[row + px] = 1
                if rounded_rect_contains(u, v, DRIVE, DRIVE_RADIUS):
                    cx, cy, r = LED
                    if (u - cx) ** 2 + (v - cy) ** 2 > r * r:
                        glyph[row + px] = 1

    out = bytearray()
    for y in range(size):
        for x in range(size):
            covered = 0
            glyphed = 0
            for sy in range(SUPERSAMPLE):
                row = (y * SUPERSAMPLE + sy) * hi + x * SUPERSAMPLE
                for sx in range(SUPERSAMPLE):
                    covered += tile[row + sx]
                    glyphed += glyph[row + sx]
            alpha = covered / samples
            if alpha <= 0:
                out += b"\x00\x00\x00\x00"
                continue
            # Diagonal top-leading to bottom-trailing, like the SwiftUI gradient.
            t = min(1.0, max(0.0, ((x + 0.5) / size + (y + 0.5) / size) / 2))
            base = tuple(
                PRIMARY[i] + (SECONDARY[i] - PRIMARY[i]) * t for i in range(3)
            )
            white = glyphed / samples
            pixel = tuple(
                int(round(base[i] + (255 - base[i]) * white)) for i in range(3)
            )
            out += bytes(pixel) + bytes((int(round(alpha * 255)),))
    return bytes(out)


def png(size: int, rgba: bytes) -> bytes:
    raw = bytearray()
    stride = size * 4
    for y in range(size):
        raw.append(0)  # filter: none
        raw += rgba[y * stride:(y + 1) * stride]

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def main() -> None:
    images = [(size, png(size, render(size))) for size in SIZES]

    header = struct.pack("<HHH", 0, 1, len(images))
    offset = len(header) + 16 * len(images)
    directory = bytearray()
    for size, data in images:
        directory += struct.pack(
            "<BBBBHHII",
            0 if size >= 256 else size,
            0 if size >= 256 else size,
            0, 0, 1, 32, len(data), offset,
        )
        offset += len(data)

    target = Path(__file__).resolve().parent.parent / "Windows/App/Assets/ImageHub.ico"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(header + bytes(directory) + b"".join(d for _, d in images))
    print(f"wrote {target} ({target.stat().st_size} bytes, {len(images)} sizes)")


if __name__ == "__main__":
    main()
