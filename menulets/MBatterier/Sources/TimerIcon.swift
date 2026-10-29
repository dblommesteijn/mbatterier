import AppKit

/// timerIcon draws the stopwatch that marks a running boost: a ring, a hand,
/// and the crown and lugs that stop a bare circle from reading as a bullet.
///
/// Unlike `batteryIcon` this one is **not** a template image, and is drawn in
/// an explicit colour. It goes into the title as a text attachment, and an
/// attachment's pixels are composited as they are — AppKit's automatic
/// template tinting applies to a status item's `image`, not to anything inside
/// its attributed title. So the caller passes the resolved label colour and
/// redraws when the menu bar's appearance changes.
func timerIcon(tint: NSColor, size: CGFloat = 11) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
        let s = size
        ctx.setStrokeColor(tint.cgColor)
        ctx.setFillColor(tint.cgColor)

        // The dial, inset to leave room for the crown above it.
        let dial = CGRect(x: s * 0.12, y: s * 0.06, width: s * 0.76, height: s * 0.76)
        ctx.setLineWidth(s * 0.1)
        ctx.strokeEllipse(in: dial)

        let centre = CGPoint(x: dial.midX, y: dial.midY)

        // The crown, and the two lugs it sits between.
        ctx.setLineWidth(s * 0.09)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: centre.x, y: dial.maxY + s * 0.02))
        ctx.addLine(to: CGPoint(x: centre.x, y: s * 0.97))
        ctx.strokePath()
        for dx in [-1.0, 1.0] as [CGFloat] {
            ctx.move(to: CGPoint(x: centre.x + dx * s * 0.22, y: dial.maxY - s * 0.04))
            ctx.addLine(to: CGPoint(x: centre.x + dx * s * 0.30, y: s * 0.92))
            ctx.strokePath()
        }

        // One hand, pointing up and to the right, so the dial reads as a
        // clock face rather than an empty ring.
        ctx.setLineWidth(s * 0.1)
        ctx.move(to: centre)
        ctx.addLine(to: CGPoint(x: centre.x + s * 0.2, y: centre.y + s * 0.22))
        ctx.strokePath()
        return true
    }
    return image
}
