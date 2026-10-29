import AppKit

/// PowerMode is the pmset power mode, as the bar needs to colour it.
enum PowerMode {
    case automatic, low, high

    init(_ name: String?) {
        switch name {
        case "low": self = .low
        case "high": self = .high
        default: self = .automatic
        }
    }
}

/// barFillColor is the colour of the battery's fill, which is how the bar
/// shows the power mode: macOS's own yellow for Low Power (the same cue the
/// system battery icon uses), purple for High Power, and the bar's own label
/// colour for Automatic, where there is nothing to call out.
/// With monochrome every mode is the bar's own colour, as Automatic is.
func barFillColor(_ mode: PowerMode, label: NSColor, monochrome: Bool = false) -> NSColor {
    if monochrome { return label }
    switch mode {
    case .automatic: return label
    case .low: return .systemYellow
    case .high: return .systemPurple
    }
}

/// minimumFill keeps a sliver of colour visible on a nearly empty battery.
/// Without it the fill vanishes below about 20% and takes the mode colour
/// with it — exactly when the mode matters most.
private let minimumFill: CGFloat = 0.2

// The icon's geometry, in points. These are the whole of the shape's design,
// so a change in proportion is a change here and nowhere else. The margin is
// kept off the top and bottom rather than baked into the canvas, so growing
// bodyHeight grows the icon rather than cropping it.
private let bodyWidth: CGFloat = 23
private let bodyHeight: CGFloat = 12
private let margin: CGFloat = 1.5
private let cornerRadius: CGFloat = 4
// Measured from the system battery: the terminal is flat against the body and
// rounded on the far side, 1.5pt by 4.2pt, a point away from it.
private let nubWidth: CGFloat = 1.5
private let nubHeight: CGFloat = 4.2
private let nubGap: CGFloat = 1.0
/// trackAlpha is how opaque the white behind the fill is, and nubAlpha the
/// terminal's. Both are tuned so they *render* like the system battery over
/// the menu bar (about 48% and 56% white), which takes a little less than
/// those figures because the image is composited again by the bar.
private let trackAlpha: CGFloat = 0.45
private let nubAlpha: CGFloat = 0.53

/// iconSize is the canvas every glyph in the bar is drawn into, so the
/// battery, the bolt and the chevron share a baseline and a centre line.
let iconSize = NSSize(width: bodyWidth + nubGap + nubWidth + 0.6,
                      height: bodyHeight + margin * 2)

/// terminalPath is the battery's terminal: square on the side that meets the
/// body and fully rounded on the far side, like a half-disc stretched to fit.
private func terminalPath(_ r: CGRect) -> CGPath {
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

/// batteryIcon draws the bar's battery: a borderless rounded pill filled from
/// the left to the charge, in the colour of the power mode, with the terminal
/// nub and the charge as a whole number inside it.
///
/// There is no outline. The shape is the fill itself over a faint track, so
/// the colour is the first thing read and the level the second.
///
/// The number is cut out of the pill, so it is transparent and the bar shows
/// through it, over the fill and the track alike. Pass `showPercent: false`
/// for a plain swatch.
///
/// This is **not** a template image: it carries real colour, so AppKit will
/// not tint it and the caller passes the resolved label colour and redraws
/// when the bar's appearance changes.
func batteryIcon(percent: Int, mode: PowerMode, label: NSColor,
                 showPercent: Bool = true, onAC: Bool = false, charging: Bool = false,
                 monochrome: Bool = false) -> NSImage {
    let color = barFillColor(mode, label: label, monochrome: monochrome)

    let image = NSImage(size: iconSize, flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
        let body = CGRect(x: 0, y: margin, width: bodyWidth, height: bodyHeight)
        let pill = CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                          transform: nil)

        // The track, so the pill keeps its shape at a low charge. Translucent
        // white rather than a tint of the mode colour: a tint of the label
        // colour reads as gray, and white lets the bar show through while
        // still looking like a clear battery.
        ctx.setFillColor(NSColor.white.withAlphaComponent(trackAlpha).cgColor)
        ctx.addPath(pill)
        ctx.fillPath()

        // The terminal nub, in the same white and a little stronger, so it
        // reads as part of the outline this icon no longer has rather than
        // as charge.
        ctx.setFillColor(NSColor.white.withAlphaComponent(nubAlpha).cgColor)
        let nub = CGRect(x: body.maxX + nubGap, y: body.midY - nubHeight / 2,
                         width: nubWidth, height: nubHeight)
        ctx.addPath(terminalPath(nub))
        ctx.fillPath()

        // The charge, clipped to the pill so its left end stays rounded and
        // its right end is square.
        let fraction = max(minimumFill, min(1, CGFloat(max(0, percent)) / 100))
        let fillRect = CGRect(x: body.minX, y: body.minY, width: body.width * fraction, height: body.height)
        ctx.saveGState()
        ctx.addPath(pill)
        ctx.clip()
        ctx.setFillColor(color.cgColor)
        ctx.fill(fillRect)
        ctx.restoreGState()

        guard showPercent, percent >= 0 else { return true }

        // Centre the digits on the pill by their cap height rather than the
        // line box, so they sit optically in the middle: digits have no
        // descenders, and a line-box centre would ride them high.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        func text(_ colour: NSColor) -> NSAttributedString {
            NSAttributedString(string: "\(percent)", attributes: [.font: font, .foregroundColor: colour])
        }
        let size = text(.black).size()

        // On the adapter a bolt follows the number, inside the pill. The pair
        // is centred together. Three digits leave no room for it, so a full
        // battery shows the number alone.
        // Measured from the system battery: 4pt wide and 7pt tall, the height of
        // the digits, with its left tip about 1.5pt past the last digit's ink.
        let boltSize = CGSize(width: 4.5, height: 9)
        let boltGap: CGFloat = 1.1
        let hasBolt = onAC && size.width + boltGap + boltSize.width <= body.width - 3
        let groupWidth = size.width + (hasBolt ? boltGap + boltSize.width : 0)
        // The pair sits half a point right of the middle, as in the system
        // battery; the number alone keeps its 1pt nudge. The digits are centred
        // on the pill, 0.5pt higher than they were.
        let origin = CGPoint(x: body.midX - groupWidth / 2 + (hasBolt ? 0.3 : 1),
                             y: body.midY - font.capHeight / 2 + font.descender - 0.75)

        // The digits and the bolt are cut out of the pill, fill and track
        // alike, so the menu bar shows through them. Transparent marks need no
        // colour of their own and never switch over at the fill's edge.
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        text(.black).draw(at: origin)
        if hasBolt {
            let digitsMid = origin.y - font.descender + font.capHeight / 2
            // The bolt sits 1pt above the digits' centre.
            let box = CGRect(x: origin.x + size.width + boltGap, y: digitsMid - boltSize.height / 2 + 1,
                             width: boltSize.width, height: boltSize.height)
            // A solid bolt, cleared as fully as the digits so the bar shows
            // through it the same way. Points are fractions of the box.
            let pts: [(CGFloat, CGFloat)] = [(0.62, 1), (0, 0.42), (0.42, 0.42),
                                             (0.30, 0), (1, 0.62), (0.56, 0.62)]
            ctx.setFillColor(NSColor.black.cgColor)
            // Leaned 10 degrees to the right (clockwise) about its own centre.
            ctx.saveGState()
            ctx.translateBy(x: box.midX, y: box.midY)
            ctx.rotate(by: -10 * .pi / 180)
            ctx.translateBy(x: -box.midX, y: -box.midY)
            ctx.move(to: CGPoint(x: box.minX + box.width * pts[0].0, y: box.minY + box.height * pts[0].1))
            for p in pts.dropFirst() {
                ctx.addLine(to: CGPoint(x: box.minX + box.width * p.0, y: box.minY + box.height * p.1))
            }
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.restoreGState()
        return true
    }
    // Real colour, so never a template.
    image.isTemplate = false
    return image
}
