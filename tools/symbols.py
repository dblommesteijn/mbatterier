#!/usr/bin/env python3
"""Generate the Control Center control's battery symbols.

A control can only show an SF Symbol, system or custom, so the menu bar's
drawn battery (BatteryIcon.swift) is redrawn here as custom symbols: one per
5% of charge, each also with a bolt for the adapter, and each of those also
with the bar's Low Power chevron or High Power chevrons (.low, .high), since
the mode colour can't show. They are written into the
extension's asset catalog, which `make menulet` compiles with actool.

The shape is the menu bar battery's: a borderless rounded pill over a track,
filled from the left to the charge, the terminal nub a point away, and a bolt
cut out of it on the adapter. The proportions are BatteryIcon.swift's, scaled
from its 12pt body to the symbol's cap height. The track and the fill are the
symbol's two hierarchical layers, so the system can draw the track fainter, as
the bar's translucent white track is. Colour is not the symbol's to choose:
Control Center draws a control's symbol in its own colour, which is why the
mode is a mark.

The centred controls draw battery and charge as one symbol, since Control
Center won't centre a control's symbol and title: battery.mbat.centred.<percent>
and .bolt, with .low or .high, one per percent, and battery.mbat.centred.none for no reading, for
the medium size; battery.mbat.large.* the same, lower, for the large size. The
charge is drawn from the system font's outlines, which
menulets/MBatteryControl/glyphs.swift reads with CoreText into the JSON file
given as the argument.

Standard library only, like tools/icon.py. Output names are
battery.mbat.<percent>[.bolt][.low|.high], plus the centred ones.

Run: make symbols
"""

import json
import math
import os
import sys

OUT = os.path.join("menulets", "MBatteryControl", "Assets.xcassets")
LEVELS = range(0, 101, 5)

# BatteryIcon.swift's geometry in its points, and the scale to symbol units.
SCALE = 0.95 * 0.95 * 66.0 / 12.0
BODY_W = 23.0 * SCALE
BODY_H = 12.0 * SCALE
RADIUS = 4.0 * SCALE
NUB_GAP = 1.0 * SCALE
NUB_W = 1.5 * SCALE
NUB_H = 4.2 * SCALE
MINIMUM_FILL = 0.2

# The template's Regular-M row: baseline and cap height, in template units.
BASELINE = 1126.0
CAP_HEIGHT = 70.459
LEFT = 1391.0
MARGIN = 6.0

# The centred control's charge, as Control Center writes a control's title:
# the system font, semibold, as tall as the battery's body (13pt beside a 13pt
# body on a medium tile), 3pt after the nub.
TITLE_SIZE = BODY_H
TITLE_GAP = 3 / 13 * BODY_H
# Control Center centres a control's symbol in a box of fixed size at a fixed
# spot, and its title at a fixed spot after that box, whatever the symbol's
# margins. Room on the symbol's left with nothing drawn in it moves the drawing
# right by half the room. On a medium tile the box's centre sits 37.95pt left
# of the tile's (measured at 2x: tile 707-988px, box centre 771.6px, beside a
# 13pt body), so this much room centres the drawing on the tile.
CENTRE_ROOM = 2 * 37.95 / 13 * BODY_H
# On a large tile the box sits in the top row: its centre is 38.5pt above the
# tile's (measured at 2x: tile centre 736px, drawing centre 659px). The large
# control's drawing sits this far below the symbol's baseline, since Control
# Center aligns a symbol by its baseline and cap height, not its drawing.
LARGE_DROP = 38.5 / 13 * BODY_H

# The body is centred on the cap height, above the baseline (y grows down).
TOP = -CAP_HEIGHT / 2 - BODY_H / 2
BOTTOM = TOP + BODY_H
MID = (TOP + BOTTOM) / 2
WIDTH = BODY_W + NUB_GAP + NUB_W

# The bolt, as fractions of its box, leaned 10 degrees right like the bar's.
# It is drawn solid and larger than the body, standing out above and below
# it, with a clear gap of BOLT_GAP cut around it into the battery.
BOLT_POINTS = [(0.62, 1), (0, 0.42), (0.42, 0.42), (0.30, 0), (1, 0.62), (0.56, 0.62)]
BOLT_W = 0.60 * BODY_H
BOLT_H = 1.20 * BODY_H
BOLT_LEAN = math.radians(10)
BOLT_GAP = 0.14 * BODY_H

# The mode marks: the menu bar's chevrons (chevronIcon in BarGlyphs.swift),
# one for Low Power and three for High Power, drawn like the bolt: solid, with
# a gap of CHEVRON_GAP cut around them into the battery. The bar's proportions
# (reach 2.1, stroke 1.3, step 3.1) are scaled to CHEVRON_REACH, and by the
# mode's scale: alone, and beside the bolt, which shrinks by BOLT_BESIDE_MARK
# for both to fit the body. Three chevrons beside the bolt also close up. The
# stroke is four ninths of the bar's (a third off, twice): thinner reads better
# inside the body.
CHEVRON_REACH = 0.28 * BODY_H
CHEVRON_STROKE = 1.3 / 2.1 * 4 / 9
CHEVRON_STEP = 3.1 / 2.1
MARK_SPACING = 0.06 * BODY_H
BOLT_BESIDE_MARK = 0.85
# The chevrons get a narrower gap than the bolt's: with the full gap their cut
# read as thick dark chevrons. Stroke and gap together are 60% thinner than
# the stroke with BOLT_GAP on each side.
CHEVRON_GAP = (0.4 * (CHEVRON_STROKE * CHEVRON_REACH + 2 * BOLT_GAP) - CHEVRON_STROKE * CHEVRON_REACH) / 2
# mode: (chevrons, scale alone, scale beside the bolt, step beside the bolt, gap)
MARKS = {"low": (1, 1.0, 0.62, 1.0, CHEVRON_GAP), "high": (3, 0.8, 0.5, 0.8, CHEVRON_GAP)}


def f(v):
    return f"{v:.3f}".rstrip("0").rstrip(".")


def pill():
    """pill is the body's outline, clockwise on screen."""
    r, t, b, w = RADIUS, TOP, BOTTOM, BODY_W
    return (f"M{f(r)} {f(t)}L{f(w - r)} {f(t)}A{f(r)} {f(r)} 0 0 1 {f(w)} {f(t + r)}"
            f"L{f(w)} {f(b - r)}A{f(r)} {f(r)} 0 0 1 {f(w - r)} {f(b)}"
            f"L{f(r)} {f(b)}A{f(r)} {f(r)} 0 0 1 0 {f(b - r)}"
            f"L0 {f(t + r)}A{f(r)} {f(r)} 0 0 1 {f(r)} {f(t)}Z")


def fill(width):
    """fill is the pill cut off at width: its left end rounded, its right end
    square, or following the pill's corner once it reaches it."""
    r, t, b, w = RADIUS, TOP, BOTTOM, BODY_W
    if width <= w - r:
        return (f"M{f(r)} {f(t)}L{f(width)} {f(t)}L{f(width)} {f(b)}L{f(r)} {f(b)}"
                f"A{f(r)} {f(r)} 0 0 1 0 {f(b - r)}L0 {f(t + r)}A{f(r)} {f(r)} 0 0 1 {f(r)} {f(t)}Z")
    if width >= w:
        return pill()
    dy = math.sqrt(r * r - (width - (w - r)) ** 2)
    return (f"M{f(r)} {f(t)}L{f(w - r)} {f(t)}A{f(r)} {f(r)} 0 0 1 {f(width)} {f(t + r - dy)}"
            f"L{f(width)} {f(b - r + dy)}A{f(r)} {f(r)} 0 0 1 {f(w - r)} {f(b)}"
            f"L{f(r)} {f(b)}A{f(r)} {f(r)} 0 0 1 0 {f(b - r)}"
            f"L0 {f(t + r)}A{f(r)} {f(r)} 0 0 1 {f(r)} {f(t)}Z")


def nub():
    """nub is the terminal: square against the body, rounded on the far side."""
    x0 = BODY_W + NUB_GAP
    t, b = MID - NUB_H / 2, MID + NUB_H / 2
    r = min(NUB_W, NUB_H / 2)
    return (f"M{f(x0)} {f(t)}L{f(x0 + NUB_W - r)} {f(t)}A{f(r)} {f(r)} 0 0 1 {f(x0 + NUB_W)} {f(t + r)}"
            f"L{f(x0 + NUB_W)} {f(b - r)}A{f(r)} {f(r)} 0 0 1 {f(x0 + NUB_W - r)} {f(b)}"
            f"L{f(x0)} {f(b)}Z")


def bolt(cx=BODY_W / 2, scale=1.0):
    """bolt is the bolt's polygon, centred on the body at cx, counter-clockwise
    on screen so that it cuts a hole in a clockwise shape under the nonzero
    rule."""
    cy = MID
    bolt_w, bolt_h = BOLT_W * scale, BOLT_H * scale
    pts = []
    for fx, fy in BOLT_POINTS:
        # The fractions run up from the box's bottom; y grows down here.
        x = cx - bolt_w / 2 + fx * bolt_w - cx
        y = cy + bolt_h / 2 - fy * bolt_h - cy
        c, s = math.cos(BOLT_LEAN), math.sin(BOLT_LEAN)
        pts.append((cx + x * c - y * s, cy + x * s + y * c))
    area = sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(pts, pts[1:] + pts[:1]))
    return pts if area < 0 else pts[::-1]


def counter_clockwise(pts):
    area = sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(pts, pts[1:] + pts[:1]))
    return pts if area < 0 else pts[::-1]


def band(apex, reach, half_width):
    """band is a chevron pointing right with its point at x apex on the body's
    middle line: every point within half_width across of the two 45-degree
    arms, cut off flat reach above and below the middle."""
    a, h, w = apex, reach, half_width
    return counter_clockwise([(a - h - w, MID - h), (a - w, MID), (a - h - w, MID + h),
                              (a - h + w, MID + h), (a + w, MID), (a - h + w, MID - h)])


def chevrons(count, scale, left, closer=1.0, cut=BOLT_GAP):
    """chevrons is a mode mark of count chevrons at scale, its ink starting at
    x left: the solid chevrons, and their gaps of cut: one each, or one around
    them all where they would overlap, since overlapping holes fill each other
    in."""
    reach = CHEVRON_REACH * scale
    # Across a 45-degree arm, the stroke is wider by the square root of two.
    half = CHEVRON_STROKE * reach * math.sqrt(2) / 2
    step = CHEVRON_STEP * reach * closer
    first = left + reach + half
    shapes = [band(first + i * step, reach, half) for i in range(count)]
    wide = half + cut * math.sqrt(2)
    if 2 * wide < step:
        # Gaps that don't meet: one each, so the battery shows between.
        return shapes, [band(first + i * step, reach + cut, wide) for i in range(count)]
    span = (count - 1) * step / 2
    return shapes, [band(first + span, reach + cut, half + span + cut * math.sqrt(2))]


def chevrons_width(count, scale, closer=1.0):
    reach = CHEVRON_REACH * scale
    return reach + CHEVRON_STROKE * reach * math.sqrt(2) + (count - 1) * CHEVRON_STEP * reach * closer


def marks(mode, with_bolt):
    """marks are the solid shapes and their gaps for the mode's chevrons and
    the bolt: each alone centred on the body, or both side by side, chevrons
    first, as the bar puts its chevrons before the battery."""
    shapes, gaps = [], []
    if mode:
        count, alone, beside, closer, cut = MARKS[mode]
        if with_bolt:
            width = chevrons_width(count, beside, closer)
            xs = [x for x, _ in bolt(0, BOLT_BESIDE_MARK)]
            bolt_w = max(xs) - min(xs)
            # The gaps touch, not overlap: overlapping holes fill each other in.
            pad = cut + BOLT_GAP + MARK_SPACING
            total = width + pad + bolt_w
            left = BODY_W / 2 - total / 2
            chevron, gap = chevrons(count, beside, left, closer, cut)
            shape = bolt(left + width + pad + bolt_w / 2 - (max(xs) + min(xs)) / 2,
                         BOLT_BESIDE_MARK)
            shapes += chevron + [shape]
            gaps += gap + [grow(shape, BOLT_GAP)]
        else:
            width = chevrons_width(count, alone)
            chevron, gap = chevrons(count, alone, BODY_W / 2 - width / 2, cut=cut)
            shapes += chevron
            gaps += gap
    elif with_bolt:
        shape = bolt()
        shapes.append(shape)
        gaps.append(grow(shape, BOLT_GAP))
    return shapes, gaps


def clip(pts, axis, limit, below):
    """clip keeps the part of a polygon on one side of a line, x or y (axis 0
    or 1) at limit: the side below it if below, else the side above.
    Sutherland-Hodgman against one edge, exact for any polygon."""
    def inside(p):
        return p[axis] <= limit if below else p[axis] >= limit
    out = []
    for a, b in zip(pts, pts[1:] + pts[:1]):
        if inside(a):
            out.append(a)
        if inside(a) != inside(b):
            t = (limit - a[axis]) / (b[axis] - a[axis])
            p = [a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])]
            p[axis] = limit
            out.append(tuple(p))
    return out


def within_body(pts):
    """within_body clips a polygon to the body's box. A hole has to stay
    inside the shape it is cut from: under the nonzero rule, the part of a
    reversed outline outside it would be filled instead."""
    for axis, limit, below in ((0, 0, False), (0, BODY_W, True), (1, TOP, False), (1, BOTTOM, True)):
        pts = clip(pts, axis, limit, below)
    return pts


def grow(pts, distance):
    """grow moves every edge of a polygon outward by distance, meeting the
    moved edges at their intersections, so the outline keeps its corners."""
    area = sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(pts, pts[1:] + pts[:1]))
    lines = []
    for a, b in zip(pts, pts[1:] + pts[:1]):
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = math.hypot(dx, dy)
        nx, ny = (dy / length, -dx / length) if area > 0 else (-dy / length, dx / length)
        lines.append(((a[0] + nx * distance, a[1] + ny * distance), (dx, dy)))
    out = []
    for (p1, d1), (p2, d2) in zip(lines[-1:] + lines[:-1], lines):
        cross = d1[0] * d2[1] - d1[1] * d2[0]
        t = ((p2[0] - p1[0]) * d2[1] - (p2[1] - p1[1]) * d2[0]) / cross
        out.append((p1[0] + t * d1[0], p1[1] + t * d1[1]))
    return out


def polygon(pts):
    if len(pts) < 3:
        return ""
    return "M" + "L".join(f"{f(x)} {f(y)}" for x, y in pts) + "Z"


def title(text, font):
    """title is text drawn from the font's outlines (see
    menulets/MBatteryControl/glyphs.swift) as CoreText lays it out: its ink
    TITLE_GAP after the nub, its cap height centred on the body as Control
    Center centres a title on its symbol. Returns the path and the x its ink
    ends at."""
    scale = TITLE_SIZE / font["size"]
    laid = font["strings"][text]
    x0 = WIDTH + TITLE_GAP - laid["inkLeft"] * scale
    baseline = MID + font["capHeight"] * scale / 2
    path = []
    for glyph, x in laid["glyphs"]:
        for command, *coords in font["glyphs"][glyph]:
            # Font units run up from the baseline; y grows down here.
            points = [f"{f(x0 + (x + cx) * scale)} {f(baseline - cy * scale)}"
                      for cx, cy in zip(coords[::2], coords[1::2])]
            path.append(command + " ".join(points))
    return "".join(path), x0 + laid["inkRight"] * scale


def svg(percent, with_bolt, text=None, drop=0.0, mode=None):
    """svg is one symbol: the battery at percent, with the bolt and the mode's
    chevrons, and with text (title's result) the centred controls' charge
    beside it, and its room. drop moves the drawing down from the template's
    baseline."""
    width = BODY_W * max(MINIMUM_FILL, min(1.0, percent / 100))
    track = pill() + nub()
    charge = fill(width)
    shapes, gaps = marks(mode, with_bolt)
    for gap in gaps:
        gap = within_body(gap)
        track += polygon(gap)
        charge += polygon(clip(gap, 0, width, True))
    for shape in shapes:
        # Clockwise, so it fills in the gap's hole as well as outside the
        # body: the charge layer, drawn at full strength.
        charge += polygon(shape[::-1])
    left, right = LEFT - MARGIN, LEFT + WIDTH + MARGIN
    if text:
        path, end = text
        charge += path
        # A line of no length: it widens the symbol and draws nothing.
        track += f"M{f(-CENTRE_ROOM)} {f(MID)}L{f(-CENTRE_ROOM)} {f(MID)}Z"
        left, right = LEFT - CENTRE_ROOM, LEFT + end + MARGIN
    guides = []
    for row, base in (("S", 696.0), ("M", BASELINE), ("L", 1556.0)):
        guides.append(f'<line id="Baseline-{row}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" '
                      f'x1="263" x2="3036" y1="{f(base)}" y2="{f(base)}"/>')
        guides.append(f'<line id="Capline-{row}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" '
                      f'x1="263" x2="3036" y1="{f(base - CAP_HEIGHT)}" y2="{f(base - CAP_HEIGHT)}"/>')
    margins = (f'<line id="left-margin-Regular-M" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" '
               f'x1="{f(left)}" x2="{f(left)}" y1="1030.79" y2="1150.12"/>'
               f'<line id="right-margin-Regular-M" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" '
               f'x1="{f(right)}" x2="{f(right)}" y1="1030.79" y2="1150.12"/>')
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<!-- Generated by tools/symbols.py; edit that, not this. -->
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <!--template version: 4.0-->
 <style>
.hierarchical-0:secondary {{opacity:0.4;fill:#000000;}}
.hierarchical-1:primary {{fill:#000000;}}
.monochrome-0 {{fill:#000000;}}
.monochrome-1 {{fill:#000000;}}
 </style>
 <g id="Notes">
  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
 </g>
 <g id="Guides">
  {"".join(guides)}
  {margins}
 </g>
 <g id="Symbols">
  <g id="Regular-M" transform="matrix(1 0 0 1 {f(LEFT)} {f(BASELINE + drop)})">
   <path class="hierarchical-0:secondary monochrome-0 SFSymbolsPreviewWireframe" d="{track}"/>
   <path class="hierarchical-1:primary monochrome-1 SFSymbolsPreviewWireframe" d="{charge}"/>
  </g>
 </g>
</svg>
"""


def write(name, content):
    folder = os.path.join(OUT, f"{name}.symbolset")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, f"{name}.svg"), "w") as fh:
        fh.write(content)
    contents = {"info": {"author": "xcode", "version": 1},
                "symbols": [{"filename": f"{name}.svg", "idiom": "universal"}]}
    with open(os.path.join(folder, "Contents.json"), "w") as fh:
        json.dump(contents, fh, indent=2)
        fh.write("\n")


def main():
    if len(sys.argv) != 2:
        print("usage: symbols.py glyphs.json (from menulets/MBatteryControl/glyphs.swift)", file=sys.stderr)
        return 2
    with open(sys.argv[1]) as fh:
        font = json.load(fh)
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "Contents.json"), "w") as fh:
        json.dump({"info": {"author": "xcode", "version": 1}}, fh, indent=2)
        fh.write("\n")
    for mode, suffix in ((None, ""), ("low", ".low"), ("high", ".high")):
        for percent in LEVELS:
            write(f"battery.mbat.{percent}{suffix}", svg(percent, False, mode=mode))
            write(f"battery.mbat.{percent}.bolt{suffix}", svg(percent, True, mode=mode))
        for family, drop in (("centred", 0.0), ("large", LARGE_DROP)):
            for percent in range(101):
                # The battery as the other control draws it, at the nearest 5%.
                step = (percent + 2) // 5 * 5
                text = title(f"{percent}%", font)
                write(f"battery.mbat.{family}.{percent}{suffix}", svg(step, False, text, drop, mode))
                write(f"battery.mbat.{family}.{percent}.bolt{suffix}", svg(step, True, text, drop, mode))
    for family, drop in (("centred", 0.0), ("large", LARGE_DROP)):
        write(f"battery.mbat.{family}.none", svg(0, False, title("—", font), drop))
    return 0


if __name__ == "__main__":
    sys.exit(main())
