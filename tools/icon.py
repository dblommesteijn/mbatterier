#!/usr/bin/env python3
"""Generate the Alfred workflow icons into alfred/.

It lives in tools/ rather than alfred/, because `make alfred` zips everything in
alfred/ into the bundle and only info.plist and the icons belong in there.

The icons are kept as a script rather than committed blobs so they can be
edited and re-rendered. It uses only the standard library: this project
deliberately avoids a second toolchain, so there is no Swift, no SF Symbol and
no image library here.

Every icon is the same glyph — the battery with a bolt knocked out of it that
is the workflow's logo — on a differently coloured tile. The logo is what says
"mbatterier" in a list of Alfred rows, so a row never replaces it with a
glyph of its own; the tile colour is what tells the rows apart. One shape also
means the family can never drift apart in weight or alignment.

Shapes are drawn as signed distance fields, which gives smooth antialiasing in
one pass per pixel instead of supersampling. Coverage for a pixel is
clamp(0.5 - distance, 0, 1), where distance is in pixels from the shape's edge.
Combining them is just min (union), max (intersection) and max(a, -b)
(difference).

The tile colour is picked from the output file's name, so the Makefile can have
one pattern rule per icon:

    python3 -I tools/icon.py alfred/boost.png

Run: make icon (writes every icon in PALETTES)
"""

import math
import os
import struct
import sys
import zlib

SIZE = 512
CENTRE = SIZE / 2.0

# A tile reads better than a bare glyph in Alfred's result list, where rows sit
# on both light and dark backgrounds.
TILE_RADIUS = 0.225 * SIZE
GLYPH = (0xFF, 0xFF, 0xFF)

# The tile gradient per icon name. The colour is the only thing that varies
# between icons, so it carries the category — the fastest thing to read in a
# list of rows. Three categories, four colours: amber is reserved for the logo
# itself, which is also what tells mbatterier apart from epods' blue, so the
# power rows sit one step along at orange rather than duplicating it.
# Rows in the same category share a tile on purpose, so their files are
# identical; Alfred only needs the paths to differ. Every gradient runs
# mid-to-dark, so the white logo keeps its contrast top to bottom.
AMBER = ((0xFB, 0xBF, 0x24), (0xEA, 0x58, 0x0C))
ORANGE = ((0xFB, 0x92, 0x3C), (0xC2, 0x41, 0x0C))
TEAL = ((0x2D, 0xD4, 0xBF), (0x0D, 0x94, 0x88))
SLATE = ((0x94, 0xA3, 0xB8), (0x47, 0x55, 0x69))

PALETTES = {
    "icon": AMBER,  # the logo, and the fallback for a row without an icon
    "boost": ORANGE,  # raises power
    "unplug": ORANGE,  # raises power
    "watch": TEAL,  # the watcher
    "low": SLATE,  # lowers power
    "status": SLATE,  # only reports
    "stop": SLATE,  # ends a boost or a watcher
}


def sd_rounded_rect(px, py, cx, cy, half_w, half_h, r):
    # Distance to a rectangle shrunk by r, then expanded back out by r.
    dx = abs(px - cx) - (half_w - r)
    dy = abs(py - cy) - (half_h - r)
    outside = math.hypot(max(dx, 0.0), max(dy, 0.0))
    return outside + min(max(dx, dy), 0.0) - r


def sd_polygon(px, py, pts):
    """Signed distance to a closed polygon, negative inside.

    The distance is the nearest of the per-edge distances; the sign comes from
    a ray cast along -x, flipped once for every edge it crosses. That handles
    the bolt's concave waist, which a convex-only test would get wrong.
    """
    d = (px - pts[0][0]) ** 2 + (py - pts[0][1]) ** 2
    inside = False
    for i in range(len(pts)):
        jx, jy = pts[i - 1]
        ix, iy = pts[i]
        ex, ey = jx - ix, jy - iy
        wx, wy = px - ix, py - iy
        # Closest point on this edge, clamped to the segment.
        t = max(0.0, min(1.0, (wx * ex + wy * ey) / (ex * ex + ey * ey)))
        bx, by = wx - ex * t, wy - ey * t
        d = min(d, bx * bx + by * by)
        # Only edges straddling py can be crossed, which also means ey != 0.
        if (iy > py) != (jy > py):
            if px < ix + (py - iy) * ex / ey:
                inside = not inside
    return -math.sqrt(d) if inside else math.sqrt(d)


# --- the logo: a battery lying on its side, bolt knocked out ----------------

CAP_HALF_W = 11.0
CAP_HALF_H = 38.0
CAP_RADIUS = 8.0
BODY_HALF_W = 142.0
BODY_HALF_H = 96.0
BODY_RADIUS = 34.0
# The body and its cap are centred together, so the body sits left of the tile
# centre by half the cap's width.
BODY_CX = CENTRE - CAP_HALF_W

# The bolt, as a polygon about its own centre. Six points: down the left of the
# upper stroke, across the waist, down to the tip, then back up the right.
BOLT = (
    (26.0, -84.0),
    (-56.0, 10.0),
    (-6.0, 10.0),
    (-26.0, 84.0),
    (56.0, -10.0),
    (6.0, -10.0),
)


def sd_logo(px, py):
    """The battery shell with the bolt subtracted.

    The bolt is a hole rather than a shape drawn on top: at the ~44px Alfred
    actually renders, a hole showing the gradient holds its shape better than a
    white-on-white outline would. max(shape, -hole) is the standard SDF
    difference — a point must be inside the shell and outside the bolt.
    """
    body = sd_rounded_rect(
        px, py, BODY_CX, CENTRE, BODY_HALF_W, BODY_HALF_H, BODY_RADIUS
    )
    cap = sd_rounded_rect(
        px,
        py,
        BODY_CX + BODY_HALF_W + CAP_HALF_W,
        CENTRE,
        CAP_HALF_W,
        CAP_HALF_H,
        CAP_RADIUS,
    )
    bolt = sd_polygon(px - BODY_CX, py - CENTRE, BOLT)
    return max(min(body, cap), -bolt)


def coverage(distance):
    """Antialiased coverage from a signed distance in pixels."""
    return min(max(0.5 - distance, 0.0), 1.0)


def render(palette):
    top, bottom = palette
    rows = []
    for y in range(SIZE):
        py = y + 0.5
        # The gradient runs top to bottom across the tile.
        t = py / SIZE
        base = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        row = bytearray()
        for x in range(SIZE):
            px = x + 0.5
            tile = coverage(
                sd_rounded_rect(px, py, CENTRE, CENTRE, CENTRE, CENTRE, TILE_RADIUS)
            )
            if tile <= 0.0:
                row += b"\x00\x00\x00\x00"
                continue
            g = coverage(sd_logo(px, py))
            # The logo is composited over the tile, then the tile's own
            # coverage becomes the alpha, so the corners stay round.
            rgb = tuple(round(base[i] + (GLYPH[i] - base[i]) * g) for i in range(3))
            row += bytes((rgb[0], rgb[1], rgb[2], round(tile * 255)))
        rows.append(bytes(row))
    return rows


def png(width, height, rows):
    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    raw = b"".join(b"\x00" + row for row in rows)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def write(out):
    name = os.path.splitext(os.path.basename(out))[0]
    if name not in PALETTES:
        sys.exit(f"no palette named {name!r} (have: {', '.join(sorted(PALETTES))})")
    with open(out, "wb") as f:
        f.write(png(SIZE, SIZE, render(PALETTES[name])))
    print(f"wrote {out} ({SIZE}x{SIZE})")


def main():
    args = sys.argv[1:] or ["alfred"]
    for arg in args:
        if os.path.isdir(arg):
            for name in sorted(PALETTES):
                write(os.path.join(arg, name + ".png"))
        else:
            write(arg)


if __name__ == "__main__":
    main()
