// Write the outlines tools/symbols.py draws the centred control's charge with,
// as JSON on stdout.
//
// Control Center writes a control's title in the system font, semibold. The
// centred control has no title, so its charge is drawn into the symbol from
// the same font, read here with CoreText: every glyph's outline, and each
// string's glyphs as CoreText lays them out ("0%" to "100%", and "—" for no
// reading). Units are those of a 1000pt font, y up from the baseline.
//
// Run: make symbols

import AppKit
import CoreText

let size: CGFloat = 1000
let font = NSFont.systemFont(ofSize: size, weight: .semibold) as CTFont

/// commands is a glyph's outline as path commands: ["M", x, y], ["L", x, y],
/// ["Q", x1, y1, x, y], ["C", x1, y1, x2, y2, x, y] and ["Z"].
func commands(_ glyph: CGGlyph) -> [[Any]] {
    guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { return [] }
    var out: [[Any]] = []
    path.applyWithBlock { element in
        let p = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: out.append(["M", p[0].x, p[0].y])
        case .addLineToPoint: out.append(["L", p[0].x, p[0].y])
        case .addQuadCurveToPoint: out.append(["Q", p[0].x, p[0].y, p[1].x, p[1].y])
        case .addCurveToPoint: out.append(["C", p[0].x, p[0].y, p[1].x, p[1].y, p[2].x, p[2].y])
        case .closeSubpath: out.append(["Z"])
        @unknown default: break
        }
    }
    return out
}

var glyphs: [String: [[Any]]] = [:]
var strings: [String: [String: Any]] = [:]
for text in (0...100).map({ "\($0)%" }) + ["—"] {
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: [.font: font]))
    var placed: [[Any]] = []
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var ids = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(), &ids)
        CTRunGetPositions(run, CFRange(), &positions)
        for (id, position) in zip(ids, positions) {
            glyphs["\(id)"] = glyphs["\(id)"] ?? commands(id)
            placed.append(["\(id)", position.x])
        }
    }
    let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    strings[text] = ["glyphs": placed, "inkLeft": ink.minX, "inkRight": ink.maxX]
}

let out: [String: Any] = [
    "font": CTFontCopyPostScriptName(font) as String,
    "size": size,
    "capHeight": CTFontGetCapHeight(font),
    "glyphs": glyphs,
    "strings": strings,
]
let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
