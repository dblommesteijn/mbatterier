import AppKit

/// chevronIcon draws a triple chevron for High Power, or a single one for
/// Low Power, in the mode's colour. It sits before the battery as a dedicated
/// mark, so the mode is legible even at a glance that skips the battery's
/// colour, and in a monochrome bar that has none.
func chevronIcon(count: Int = 3, height: CGFloat = iconSize.height, color: NSColor) -> NSImage {
    let size = NSSize(width: 5 + CGFloat(count - 1) * 3.1, height: height)
    return NSImage(size: size, flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.3)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let midY = size.height / 2
        let reach: CGFloat = 2.1   // half-height of each chevron
        let step: CGFloat = 3.1    // spacing between the three
        for i in 0..<count {
            let x = 1.4 + CGFloat(i) * step
            ctx.move(to: CGPoint(x: x, y: midY + reach))
            ctx.addLine(to: CGPoint(x: x + 2.1, y: midY))
            ctx.addLine(to: CGPoint(x: x, y: midY - reach))
            ctx.strokePath()
        }
        return true
    }
}

/// barHeight is the canvas of the whole menu bar item. Every element is
/// centred on its middle line.
let barHeight: CGFloat = 22

/// barPadding is the space on each side of every element of the bar, measured
/// from its ink rather than its canvas, so the gap between any two is twice
/// this whatever they are and whichever are shown.
let barPadding: CGFloat = 2

/// BarPart is one element of the menu bar item: a mark, or a piece of text.
/// A mark is centred on its ink; text keeps its own vertical placement (see
/// barText), so digits and letters share a baseline.
struct BarPart {
    let image: NSImage
    let isText: Bool
}

/// barTextPart draws text for the bar onto a barHeight canvas, its cap height
/// centred on the middle line. Monospaced digits keep a countdown steady.
func barTextPart(_ text: String, color: NSColor) -> BarPart {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    let width = ceil(string.size().width) + 2
    let image = NSImage(size: NSSize(width: width, height: barHeight), flipped: false) { _ in
        // draw(at:) places the bottom of the line box, a descender below the
        // baseline.
        string.draw(at: NSPoint(x: 1, y: barHeight / 2 - font.capHeight / 2 + font.descender))
        return true
    }
    return BarPart(image: image, isText: true)
}

/// inkBounds is the part of image that has any ink, in points. It is found
/// in a 2x bitmap, the menu bar's own resolution on a Retina screen.
func inkBounds(_ image: NSImage) -> CGRect {
    let scale: CGFloat = 2
    let w = Int(ceil(image.size.width * scale)), h = Int(ceil(image.size.height * scale))
    guard w > 0, h > 0,
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32),
          let data = rep.bitmapData else { return CGRect(origin: .zero, size: image.size) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
    NSGraphicsContext.restoreGraphicsState()

    var minX = w, maxX = -1, minY = h, maxY = -1
    for y in 0..<h {
        for x in 0..<w where data[(y * w + x) * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= 0 else { return CGRect(origin: .zero, size: image.size) }
    // The bitmap's rows run top-down; the image's y runs bottom-up.
    return CGRect(x: CGFloat(minX) / scale, y: CGFloat(h - 1 - maxY) / scale,
                  width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
}

/// composeBar lays the parts out left to right as one image: each trimmed to
/// its ink, with barPadding either side. The item is this one image rather
/// than a title beside an image, because AppKit puts a gap of its own between
/// those two that nothing here controls.
///
/// None of the parts is a template — the colour is the mode — so the caller
/// passes resolved colours and redraws on an appearance change.
func composeBar(_ parts: [BarPart]) -> NSImage {
    let placed = parts.map { ($0, inkBounds($0.image)) }
    let width = placed.reduce(0) { $0 + $1.1.width + 2 * barPadding }
    let image = NSImage(size: NSSize(width: ceil(width), height: barHeight), flipped: false) { _ in
        var x: CGFloat = 0
        for (part, ink) in placed {
            x += barPadding
            let y = part.isText ? 0 : (barHeight / 2 - ink.midY)
            part.image.draw(in: NSRect(x: x - ink.minX, y: y,
                                       width: part.image.size.width, height: part.image.size.height))
            x += ink.width + barPadding
        }
        return true
    }
    image.isTemplate = false
    return image
}
