import AppKit

/// menuTextFont and menuTextColor are the text of the system Battery menu's
/// rows, measured from it: a 19px cap height at 2x, which is 13.5pt, and an
/// opaque dark gray of 30/255 in a light menu. The gray is deliberate: black at
/// partial opacity would take on the tint of whatever is behind the menu, where
/// Apple's text stays one slightly gray colour. In a dark menu it is the label
/// colour's white, which was not measured. One definition, so every row, line
/// and title in the menu reads the same.
let menuTextFont = NSFont.systemFont(ofSize: 13.5)
let menuTextColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor.white.withAlphaComponent(0.85)
        : NSColor(white: 30.0 / 255, alpha: 1)
}

/// infoTextFont is the font of the detail lines under the menu's title ("Power
/// Source: …", the charge, a running boost). Measured from the system menu:
/// 12pt regular, a size below the rows' 13.5pt.
let infoTextFont = NSFont.systemFont(ofSize: 12)

/// secondaryTextColor is the gray of the detail lines and the section headings:
/// the exact flat colour of "Power Source: Battery" in the system menu,
/// #41423E, sampled from a screenshot of it. In a dark menu it is the label
/// colour's white at 60%, which was not measured.
let secondaryTextColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor.white.withAlphaComponent(0.6)
        : NSColor(srgbRed: 65.0 / 255, green: 66.0 / 255, blue: 62.0 / 255, alpha: 1)
}

/// menuLeftInset is the margin to the left of everything in the menu: headline
/// text, badges, ticks and plain row text alike. One value, so they stay in line.
let menuLeftInset: CGFloat = 12

/// menuTopMargin is the empty space above the menu's first row.
let menuTopMargin: CGFloat = 3

/// menuHoverColor is the highlight of a selectable row: the menu's own colour
/// darkened by about 11%, measured from the system Battery menu. It is the
/// label colour at low opacity, so it darkens a light menu and lightens a dark
/// one, and it replaces the accent blue AppKit would draw.
let menuHoverColor = NSColor.labelColor.withAlphaComponent(0.11)

/// onMain runs `work` on the main thread, in the tracking mode as well. An
/// open menu runs only that mode, and the main dispatch queue waits until it
/// closes, so a click's action and the reading after it would only show once
/// the menu was gone. Safe to call from any thread.
func onMain(_ work: @escaping () -> Void) {
    RunLoop.main.perform(inModes: [.common, .eventTracking], block: work)
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

/// MenuRowView is one row of the menu, with a highlight it draws itself.
///
/// It is a custom view because AppKit highlights a standard menu item in the
/// system accent colour and offers no way to change that. A custom view has to
/// do what a standard item does for free — track the mouse, draw the highlight,
/// close the menu and fire the action on click — and this does exactly that.
/// The menu item that holds it still carries the action, the target and any
/// submenu.
final class MenuRowView: NSView {
    enum Accessory {
        case none
        /// check is a tick at the left that `checked` shows or hides.
        case check
        /// chevron marks a row that opens a submenu.
        case chevron
    }

    private let selectable: Bool
    private let hasSubmenu: Bool
    private let icon = NSImageView()
    private let label: NSTextField
    private let tick = NSTextField(labelWithString: "✓")
    private var hovering = false {
        didSet { needsDisplay = true }
    }

    /// onEnter tells the menu this row was entered, so it can put out the others
    /// in the same menu. Exit events are not reliably delivered when the mouse
    /// moves quickly, so a row never relies on its own exit to stop being lit.
    var onEnter: ((MenuRowView) -> Void)?
    /// closesMenu is for a row that leads out of the menu, such as one that
    /// opens System Settings. Every other row keeps the menu open, so a
    /// change of mode or setting shows in place.
    var closesMenu = false

    /// setLit is how the menu says which row is highlighted. It is the main
    /// source of truth; the mouse events here are a fallback for it.
    func setLit(_ on: Bool) {
        hovering = on && selectable
    }

    /// badge is the round icon of an Energy Mode row, which also says whether
    /// the row's mode is the one in force.
    var badge: NSImage? {
        didSet { icon.image = badge }
    }

    /// counter is a short figure shown after the label, such as the minutes
    /// left on a boost. Empty hides it.
    var counter = "" {
        didSet { layoutCounter() }
    }
    private let counterLabel = NSTextField(labelWithString: "")
    private var trailingMargin: CGFloat = 18

    /// title is the row's text; setting it refits the row.
    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            label.sizeToFit()
            layoutCounter()
        }
    }

    /// appIcon is an app's icon before the title, as macOS's Battery menu
    /// shows one beside each app using significant energy; nil for none.
    var appIcon: NSImage? {
        didSet {
            icon.image = appIcon
            icon.isHidden = appIcon == nil
            if icon.superview == nil {
                icon.imageScaling = .scaleProportionallyUpOrDown
                addSubview(icon)
            }
            icon.frame = NSRect(x: menuLeftInset, y: (frame.height - appIconSize) / 2,
                                width: appIconSize, height: appIconSize)
            label.frame.origin.x = appIcon == nil ? menuLeftInset : icon.frame.maxX + appIconGap
            layoutCounter()
        }
    }
    private let appIconSize: CGFloat = 16
    private let appIconGap: CGFloat = 6

    /// checked shows the tick on a row with a `.check` accessory.
    var checked = false {
        didSet { tick.isHidden = !checked }
    }

    init(title: String, glyph: EnergyGlyph?, selectable: Bool,
         accessory: Accessory = .none, hasSubmenu: Bool = false) {
        self.selectable = selectable
        self.hasSubmenu = hasSubmenu
        self.label = NSTextField(labelWithString: title)
        // 22pt like the system menu's plain items; the Energy Mode rows are
        // taller for their badge.
        let height: CGFloat = glyph == nil ? 22 : 32
        let width: CGFloat = 200
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        autoresizingMask = [.width]

        var textX: CGFloat = menuLeftInset
        if let glyph {
            // The badge's canvas includes its right-hand margin, so the label
            // starts where the canvas ends.
            let size = energyBadge(glyph, active: false).size
            icon.frame = NSRect(x: menuLeftInset, y: (height - size.height) / 2, width: size.width, height: size.height)
            icon.imageScaling = .scaleNone
            addSubview(icon)
            badge = energyBadge(glyph, active: false)
            textX = icon.frame.maxX
        } else if accessory == .check {
            tick.font = .systemFont(ofSize: 12, weight: .semibold)
            tick.textColor = .labelColor
            tick.sizeToFit()
            tick.frame.origin = NSPoint(x: menuLeftInset, y: (height - tick.frame.height) / 2)
            tick.isHidden = true
            addSubview(tick)
            textX = menuLeftInset + 20
        }

        label.font = menuTextFont
        // A row that can't be selected is drawn disabled, as a standard menu
        // item would be: dim text, and a dim badge.
        label.textColor = selectable ? menuTextColor : .disabledControlTextColor
        icon.alphaValue = selectable ? 1 : 0.5
        label.sizeToFit()
        label.frame.origin = NSPoint(x: textX, y: (height - label.frame.height) / 2)
        addSubview(label)

        // The row is as wide as its text needs, so a menu made of these (the
        // Settings submenu) fits its options instead of a fixed width. A menu
        // with a wider item still stretches the row (see autoresizingMask).
        trailingMargin = accessory == .chevron ? 34 : 18
        counterLabel.font = infoTextFont
        counterLabel.textColor = secondaryTextColor
        counterLabel.isHidden = true
        addSubview(counterLabel)
        layoutCounter()

        if accessory == .chevron {
            let chevron = NSTextField(labelWithString: "›")
            chevron.font = .systemFont(ofSize: 15, weight: .semibold)
            chevron.textColor = .secondaryLabelColor
            chevron.sizeToFit()
            chevron.frame.origin = NSPoint(x: frame.width - 22, y: (height - chevron.frame.height) / 2)
            chevron.autoresizingMask = [.minXMargin]
            addSubview(chevron)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// layoutCounter places the counter after the label, a margin's width away,
    /// and sizes the row to end after it, so the row is only as wide as it needs.
    private func layoutCounter() {
        counterLabel.stringValue = counter
        counterLabel.isHidden = counter.isEmpty
        var right = label.frame.maxX
        if !counter.isEmpty {
            counterLabel.sizeToFit()
            counterLabel.frame.origin = NSPoint(x: label.frame.maxX + menuLeftInset,
                                                y: (frame.height - counterLabel.frame.height) / 2)
            right = counterLabel.frame.maxX
        }
        setFrameSize(NSSize(width: right + trailingMargin, height: frame.height))
    }

    /// reset clears the hover, for when the menu closes under the mouse and no
    /// exit event arrives.
    func reset() {
        hovering = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        onEnter?(self)
        hovering = selectable
    }

    override func mouseExited(with event: NSEvent) {
        guard hasSubmenu else {
            hovering = false
            return
        }
        // A row with a submenu stays lit while its submenu is showing, which
        // is when the mouse has left the row for the submenu. The menu keeps
        // the item highlighted then, so ask it a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.hovering = self?.enclosingMenuItem?.isHighlighted ?? false
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering && !picturingMenu else { return }
        menuHoverColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 9, yRadius: 9).fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// mouseUp sends the item's action. Unlike a standard item it leaves the
    /// menu open, unless the row is one that closesMenu. A row that only opens
    /// a submenu has no action.
    override func mouseUp(with event: NSEvent) {
        guard selectable, let item = enclosingMenuItem, let action = item.action else { return }
        if closesMenu {
            item.menu?.cancelTracking()
        }
        let target = item.target
        onMain { NSApp.sendAction(action, to: target, from: item) }
    }
}

/// HoverButton is a borderless button that lights up like a menu row when the
/// mouse is over it, for Reload and Quit in the menu's top row.
class HoverButton: NSButton {
    private var hovering = false {
        didSet { needsDisplay = true }
    }

    /// onEnter lets the menu put out the neighbouring button, as for rows.
    var onEnter: (() -> Void)?

    /// tip is shown after a short hover. It stands in for toolTip, which
    /// macOS doesn't show for a view inside an open menu.
    var tip: String? {
        didSet { if hovering { HoverTip.update(tip, for: self) } }
    }
    private var tipTimer: Timer?

    func reset() {
        hovering = false
        hideTip()
    }

    private func hideTip() {
        tipTimer?.invalidate()
        tipTimer = nil
        HoverTip.hide(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        onEnter?()
        hovering = true
        tipTimer?.invalidate()
        // Common modes: the open menu runs its own run loop mode.
        let timer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self, self.hovering, let tip = self.tip else { return }
            HoverTip.show(tip, for: self)
        }
        RunLoop.main.add(timer, forMode: .common)
        tipTimer = timer
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        hideTip()
    }
    override func mouseDown(with event: NSEvent) {
        hideTip()
        super.mouseDown(with: event)
    }

    /// drawHover paints the hover pill, if the mouse is over the button.
    func drawHover() {
        guard hovering && !picturingMenu else { return }
        menuHoverColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHover()
        super.draw(dirtyRect)
    }
}

/// ReloadButton is the circular-arrow button in the menu's top row. It draws
/// its own face rather than showing an image, so that a press can spin the
/// drawing itself one full turn and the arrow follows the menu's colours.
final class ReloadButton: HoverButton {
    private let duration: TimeInterval = 0.7
    private var angle: CGFloat = 0
    private var spinStart: Date?
    private var spinTimer: Timer?

    /// sendAction starts the spin on every press, then does what a button does.
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        spin()
        return super.sendAction(action, to: target)
    }

    /// spin turns the arrow once, clockwise. A press during a spin restarts it.
    /// The timer runs in the common modes: the menu tracks the mouse in its own
    /// run loop mode, where a default-mode timer would never fire.
    private func spin() {
        spinTimer?.invalidate()
        spinStart = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, let start = self.spinStart else { return timer.invalidate() }
            let t = min(1, Date().timeIntervalSince(start) / self.duration)
            // Ease in and out, so it starts and settles like a control, not a gear.
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            self.angle = CGFloat(eased) * 2 * .pi
            self.needsDisplay = true
            if t >= 1 {
                self.angle = 0
                self.spinStart = nil
                timer.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        spinTimer = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHover()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius: CGFloat = 4.7

        ctx.saveGState()
        // Clockwise on screen is a negative angle with y pointing up.
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: -angle)
        ctx.translateBy(x: -c.x, y: -c.y)

        ctx.setStrokeColor(NSColor.labelColor.cgColor)
        ctx.setFillColor(NSColor.labelColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)

        // An open ring: 300 degrees, leaving a gap at the top for the arrow.
        let start: CGFloat = 70 * .pi / 180
        let end: CGFloat = start - 300 * .pi / 180
        ctx.addArc(center: c, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        ctx.strokePath()

        // The arrowhead on the end of the ring, pointing the way it turns.
        let tip = CGPoint(x: c.x + radius * cos(end), y: c.y + radius * sin(end))
        let along = CGPoint(x: sin(end), y: -cos(end))      // direction of travel
        let out = CGPoint(x: cos(end), y: sin(end))          // away from the centre
        let head = CGMutablePath()
        head.move(to: CGPoint(x: tip.x + along.x * 2.2, y: tip.y + along.y * 2.2))
        head.addLine(to: CGPoint(x: tip.x - along.x * 0.9 + out.x * 2.1, y: tip.y - along.y * 0.9 + out.y * 2.1))
        head.addLine(to: CGPoint(x: tip.x - along.x * 0.9 - out.x * 2.1, y: tip.y - along.y * 0.9 - out.y * 2.1))
        head.closeSubpath()
        ctx.addPath(head)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

/// InfoItem is a line of read-only detail in the menu: the power source, the
/// charge, a running boost or watcher.
///
/// It is a label in a custom view rather than a disabled menu item, because
/// AppKit draws every disabled item dimmed whatever colour it is given, and
/// these lines should read in the normal text colour. Setting `title` updates
/// the label and refits the row, so it is used like any other item.
final class InfoItem: NSMenuItem {
    private let label = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    /// lineGap (init) is the distance between the text of two lines in a row of
    /// these, so the row is the text's line height plus that.
    private let row: NSView

    init(color: NSColor = secondaryTextColor, lineGap: CGFloat = 9) {
        row = NSView(frame: NSRect(x: 0, y: 0, width: 1,
                                   height: ceil(infoTextFont.ascender - infoTextFont.descender + infoTextFont.leading) + lineGap))
        super.init(title: "", action: nil, keyEquivalent: "")
        for text in [label, detailLabel] {
            text.font = infoTextFont
            text.textColor = color
            row.addSubview(text)
        }
        row.autoresizingMask = [.width]
        view = row
        fit()
    }

    required init(coder: NSCoder) {
        fatalError("not used")
    }

    override var title: String {
        didSet {
            label.stringValue = title
            fit()
        }
    }

    /// detail is a second piece of text on the same line, after the title. It
    /// sits a fixed gap away, the width of the menu's left margin, rather than
    /// a run of spaces that would depend on the font.
    var detail = "" {
        didSet {
            detailLabel.stringValue = detail
            fit()
        }
    }

    /// fit sizes the row to its text, like MenuRowView, so a long line widens
    /// the menu and a short one doesn't.
    private func fit() {
        label.sizeToFit()
        label.frame.origin = NSPoint(x: menuLeftInset, y: (row.frame.height - label.frame.height) / 2)
        var right = label.frame.maxX
        detailLabel.isHidden = detail.isEmpty
        if !detail.isEmpty {
            detailLabel.sizeToFit()
            detailLabel.frame.origin = NSPoint(x: label.frame.maxX + menuLeftInset,
                                               y: (row.frame.height - detailLabel.frame.height) / 2)
            right = detailLabel.frame.maxX
        }
        row.setFrameSize(NSSize(width: right + 18, height: row.frame.height))
    }
}

/// HoverTip is the one floating tip a HoverButton shows: a small panel above
/// the menu's level, under the button, kept on screen.
enum HoverTip {
    private static var panel: NSPanel?
    private static var label: NSTextField?
    private static weak var owner: NSView?
    private static let maxWidth: CGFloat = 260
    private static let padding = NSSize(width: 8, height: 5)

    static func show(_ text: String, for view: NSView) {
        owner = view
        let panel = self.panel ?? makePanel()
        guard let label, let window = view.window, let screen = window.screen ?? NSScreen.main else { return }
        label.stringValue = text
        label.preferredMaxLayoutWidth = maxWidth
        let fit = label.sizeThatFits(NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
        let size = NSSize(width: ceil(fit.width) + 2 * padding.width, height: ceil(fit.height) + 2 * padding.height)
        label.frame = NSRect(x: padding.width, y: padding.height, width: ceil(fit.width), height: ceil(fit.height))

        let button = window.convertToScreen(view.convert(view.bounds, to: nil))
        var origin = NSPoint(x: button.midX - size.width / 2, y: button.minY - 6 - size.height)
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - 4 - size.width)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    /// update swaps the text of a tip already showing for view, such as a
    /// toggle's after a click.
    static func update(_ text: String?, for view: NSView) {
        guard owner === view, panel?.isVisible == true else { return }
        if let text { show(text, for: view) } else { hide(for: view) }
    }

    static func hide(for view: NSView) {
        guard owner === view else { return }
        panel?.orderOut(nil)
        owner = nil
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 5
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        let text = NSTextField(wrappingLabelWithString: "")
        text.font = .systemFont(ofSize: 11)
        text.textColor = .labelColor
        background.addSubview(text)
        panel.contentView = background
        self.panel = panel
        self.label = text
        return panel
    }
}
