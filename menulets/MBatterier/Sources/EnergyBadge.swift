import AppKit

/// EnergyGlyph is what a badge in the Energy Mode section depicts.
enum EnergyGlyph {
    case automatic, low, high, off
}

/// activeColor is the disc colour of the mode in force, matching the bar:
/// purple for High Power, yellow for Low Power, and macOS's blue for
/// Automatic, where the bar itself has no colour to call out.
private func activeColor(_ glyph: EnergyGlyph) -> NSColor? {
    switch glyph {
    case .automatic: return .systemBlue
    case .low: return .systemYellow
    case .high: return .systemPurple
    case .off: return nil
    }
}

/// terminal is the battery's terminal: flat against the body, rounded on the
/// far side.
private func terminal(_ r: CGRect) -> CGPath {
    let radius = min(r.width, r.height / 2)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: r.minX, y: r.minY))
    path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
    path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY),
                tangent2End: CGPoint(x: r.maxX, y: r.minY + radius), radius: radius)
    path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
    path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY),
                tangent2End: CGPoint(x: r.maxX - radius, y: r.maxY), radius: radius)
    path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
    path.closeSubpath()
    return path
}

/// energyBadge draws the round icon macOS puts beside each Energy Mode row: a
/// pale disc with a battery glyph, or the mode's colour behind a white glyph
/// while that mode is in force. The same badge in the same place is what marks
/// the active row, so there is no checkmark.
///
/// Proportions are measured from the system menu: a 26pt disc, a dim 17x9pt
/// battery ring with a half-round terminal, and inside it a full bar for
/// Automatic, a short block for Low Power and three play triangles for High
/// Power. The canvas is wider than the disc by 8pt, which is the gap between
/// the icon and the row's text.
func energyBadge(_ glyph: EnergyGlyph, active: Bool) -> NSImage {
    let diameter: CGFloat = 26
    let margin: CGFloat = 8
    let image = NSImage(size: NSSize(width: diameter + margin, height: diameter), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
        let disc = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let tint = active ? activeColor(glyph) : nil

        // Colours are resolved here, in the draw handler, so the badge follows
        // the menu's light or dark appearance without being redrawn.
        let discColor = tint ?? NSColor.labelColor.withAlphaComponent(0.14)
        // White does not read on the yellow disc, as with the bar's digits.
        let ink: NSColor = tint == nil ? NSColor.labelColor.withAlphaComponent(0.6)
            : (glyph == .low ? NSColor(white: 0.2, alpha: 1) : .white)
        // The ring and terminal are the same ink at half strength, so the
        // fill inside them is what reads first.
        let dim = ink.withAlphaComponent(ink.alphaComponent * 0.5)
        ctx.setFillColor(discColor.cgColor)
        ctx.fillEllipse(in: disc)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let c = CGPoint(x: disc.midX, y: disc.midY)
        if glyph == .off {
            // The power symbol: a ring open at the top, and a stroke into it.
            ctx.setStrokeColor(ink.cgColor)
            ctx.setLineWidth(1.6)
            ctx.addArc(center: c, radius: 5.2, startAngle: 2 * .pi / 3, endAngle: .pi / 3, clockwise: false)
            ctx.strokePath()
            ctx.move(to: CGPoint(x: c.x, y: c.y + 0.8))
            ctx.addLine(to: CGPoint(x: c.x, y: c.y + 5.8))
            ctx.strokePath()
            return true
        }

        // The battery: a dim ring and terminal, then the fill inside them.
        let body = CGRect(x: c.x - 8.9, y: c.y - 4.4, width: 17, height: 8.8)
        ctx.setStrokeColor(dim.cgColor)
        ctx.setLineWidth(1.4)
        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 0.7, dy: 0.7), cornerWidth: 2.6, cornerHeight: 2.6,
                           transform: nil))
        ctx.strokePath()
        ctx.setFillColor(dim.cgColor)
        ctx.addPath(terminal(CGRect(x: body.maxX + 0.7, y: c.y - 1.7, width: 1.7, height: 3.4)))
        ctx.fillPath()

        let inner = body.insetBy(dx: 2.0, dy: 1.9)
        ctx.setFillColor(ink.cgColor)
        switch glyph {
        case .automatic:
            ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 1.2, cornerHeight: 1.2, transform: nil))
            ctx.fillPath()
        case .low:
            let block = CGRect(x: inner.minX, y: inner.minY, width: 3.3, height: inner.height)
            ctx.addPath(CGPath(roundedRect: block, cornerWidth: 1, cornerHeight: 1, transform: nil))
            ctx.fillPath()
        case .high:
            for i in 0..<3 {
                let x = inner.minX + 0.2 + CGFloat(i) * 4.3
                ctx.move(to: CGPoint(x: x, y: c.y + 2.3))
                ctx.addLine(to: CGPoint(x: x + 3.6, y: c.y))
                ctx.addLine(to: CGPoint(x: x, y: c.y - 2.3))
                ctx.closePath()
                ctx.fillPath()
            }
        case .off:
            break
        }
        return true
    }
    image.isTemplate = false
    return image
}

/// quitIcon draws the power symbol used for Quit: a ring open at the top with a
/// stroke into it. It is a template image, so macOS tints it with the control.
func quitIcon(size: CGFloat = 14) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let radius = size * 0.34
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(size * 0.11)
        ctx.setLineCap(.round)
        ctx.addArc(center: c, radius: radius, startAngle: 2 * .pi / 3, endAngle: .pi / 3, clockwise: false)
        ctx.strokePath()
        ctx.move(to: CGPoint(x: c.x, y: c.y + size * 0.04))
        ctx.addLine(to: CGPoint(x: c.x, y: c.y + radius + size * 0.18))
        ctx.strokePath()
        return true
    }
    image.isTemplate = true
    return image
}

/// watchIcon draws the eye of the watch toggle: open with a pupil while the
/// watcher runs, struck through while it doesn't. A template image, like Quit.
func watchIcon(on: Bool, size: CGFloat = 15) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let halfWidth = size * 0.43
        let lid = size * 0.30
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.setLineWidth(size * 0.09)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Two lids meeting at the corners of the eye.
        let eye = CGMutablePath()
        eye.move(to: CGPoint(x: c.x - halfWidth, y: c.y))
        eye.addQuadCurve(to: CGPoint(x: c.x + halfWidth, y: c.y), control: CGPoint(x: c.x, y: c.y + 2 * lid))
        eye.addQuadCurve(to: CGPoint(x: c.x - halfWidth, y: c.y), control: CGPoint(x: c.x, y: c.y - 2 * lid))
        eye.closeSubpath()
        ctx.addPath(eye)
        ctx.strokePath()

        let pupil = size * 0.14
        ctx.fillEllipse(in: CGRect(x: c.x - pupil, y: c.y - pupil, width: 2 * pupil, height: 2 * pupil))

        if !on {
            strike(ctx, center: c, size: size)
        }
        return true
    }
    image.isTemplate = true
    return image
}

/// tinted returns a template image painted in color, for the menu bar title:
/// a text attachment there isn't tinted the way a button image is, and the
/// bar's marks wear the power mode's colour, as the stopwatch does.
func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    out.isTemplate = false
    return out
}

/// strike draws the diagonal of an "off" toggle icon, with a gap cut either
/// side so it reads over the glyph beneath.
private func strike(_ ctx: CGContext, center c: CGPoint, size: CGFloat) {
    let from = CGPoint(x: c.x - size * 0.38, y: c.y + size * 0.38)
    let to = CGPoint(x: c.x + size * 0.38, y: c.y - size * 0.38)
    ctx.setLineCap(.round)
    ctx.setBlendMode(.clear)
    ctx.setLineWidth(size * 0.24)
    ctx.move(to: from)
    ctx.addLine(to: to)
    ctx.strokePath()
    ctx.setBlendMode(.normal)
    ctx.setLineWidth(size * 0.09)
    ctx.move(to: from)
    ctx.addLine(to: to)
    ctx.strokePath()
}

/// alwaysBoostIcon draws the always-on boost toggle: an infinity sign, the
/// same mark the bar shows for a boost with no deadline, struck through while
/// no such boost runs. A template image, like the watch eye.
func alwaysBoostIcon(on: Bool, size: CGFloat = 15) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        // A lemniscate of Bernoulli, wide enough to fill the box.
        let a = size * 0.44
        let path = CGMutablePath()
        let steps = 64
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let d = 1 + sin(t) * sin(t)
            let p = CGPoint(x: c.x + a * cos(t) / d, y: c.y + a * sin(t) * cos(t) / d * 1.3)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(size * 0.09)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
        if !on {
            strike(ctx, center: c, size: size)
        }
        return true
    }
    image.isTemplate = true
    return image
}
