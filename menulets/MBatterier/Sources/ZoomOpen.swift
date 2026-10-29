import AppKit
import os

private let zoomLog = Logger(subsystem: "it.blommesteijn.mbatterier", category: "zoom")

/// zoomDuration is how long the shape takes to grow, about as long as
/// Control Center takes to open a module's details.
private let zoomDuration: TimeInterval = 0.22
/// zoomCornerRadius matches a menu's rounded corners, so the shape the menu
/// replaces has the same outline.
private let zoomCornerRadius: CGFloat = 12

/// controlCenterGlassVariant is NSGlassEffectView's private _variant for
/// Control Center's glass: its filter matches SwiftUI's _Glass.controlCenter,
/// which Control Center draws its tiles with, input for input (macOS 27).
let controlCenterGlassVariant = 9
/// menuGlassVariant is the _variant AppKit gives a menu's glass: the frosted
/// one the menu bar's menus have.
let menuGlassVariant = 0

/// controlCenterAppearance is the appearance Control Center draws over its
/// glass: dark, with white text, whatever the system appearance.
let controlCenterAppearance = NSAppearance(named: .darkAqua)

/// useControlCenterGlass gives glass Control Center's look instead of a
/// menu's frosted one, or with `false` the menu's own back. A private
/// property: where it is gone, glass keeps its own look.
func useControlCenterGlass(_ glass: NSGlassEffectView, _ controlCenter: Bool = true) {
    guard glass.responds(to: NSSelectorFromString("set_variant:")) else { return }
    glass.setValue(controlCenter ? controlCenterGlassVariant : menuGlassVariant, forKey: "_variant")
}

/// useControlCenterGlassForMenus does that for the menu windows about to
/// open. By menuWillOpen AppKit has built them, glass included, but not shown
/// them yet, so the menu never shows its own glass first. With `false` it
/// puts the menu's own glass back, in case AppKit reuses a window it changed.
func useControlCenterGlassForMenus(_ controlCenter: Bool) {
    for window in NSApp.windows where NSStringFromClass(type(of: window)) == "NSPopupMenuWindow" {
        if let glass = window.contentView as? NSGlassEffectView { useControlCenterGlass(glass, controlCenter) }
        // The grown shape is the menu's opening: a fade-in of its own on top
        // would show the backdrop through it at the handover.
        if controlCenter {
            window.animationBehavior = .none
        } else if window.animationBehavior == .none {
            window.animationBehavior = .default
        }
    }
}

/// zoomOpen grows a menu-coloured shape from `start` to `end`, then calls
/// `open`, which is meant to open the menu over it at `end`. It stands in for
/// the menu, whose window AppKit owns and doesn't animate, so the menu seems
/// to grow out of the tile that was tapped, as Apple's module details do.
///
/// `picture` is the menu's rows as they last showed (see pictureOfOpenMenu).
/// It grows with the shape, scaled to fit it, so the text is there from the
/// start rather than appearing only when the menu replaces the shape.
/// `glass` is the menu's glass filter as it last showed (see
/// glassFilterOfOpenMenu), so the shape blurs and tints as the menu will.
///
/// The shape stays up until the menu shows over it, so nothing between them
/// shows the backdrop bare (see removeUnderMenu). `open` may run a menu's
/// tracking loop, which doesn't return until the menu closes, so that runs on
/// a timer in the tracking mode, and the shape goes for good when `open`
/// returns.
func zoomOpen(from start: NSRect, to end: NSRect, picture: NSImage?, glass: GlassFilter?,
              open: @escaping () -> Void) {
    let window = NSWindow(contentRect: start, styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.level = .popUpMenu
    window.ignoresMouseEvents = true
    window.isReleasedWhenClosed = false
    window.appearance = controlCenterAppearance

    let shape = MenuMatchedGlass()
    shape.filter = glass
    shape.cornerRadius = zoomCornerRadius
    useControlCenterGlass(shape)
    window.contentView = shape
    if let picture {
        let rows = NSImageView(frame: shape.bounds)
        rows.image = picture
        rows.imageScaling = .scaleProportionallyUpOrDown
        rows.autoresizingMask = [.width, .height]
        // In a plain holder: as the glass's content itself, the picture's own
        // size would hold the window at the menu's size from the start, and
        // the shape would slide rather than grow.
        let holder = NSView(frame: shape.bounds)
        holder.addSubview(rows)
        shape.contentView = holder
    }
    // The menu's glass from the first frame, not faded in: drawn and
    // committed before the window shows.
    window.displayIfNeeded()
    CATransaction.flush()
    window.orderFrontRegardless()

    NSAnimationContext.runAnimationGroup({ context in
        context.duration = zoomDuration
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        window.animator().setFrame(end, display: true)
    }, completionHandler: {
        let removal = removeUnderMenu(window)
        open()
        removal.invalidate()
        window.orderOut(nil)
    })
}

/// GlassFilter is the inputs of a glass's backdrop filter, by name.
typealias GlassFilter = [String: Any]

/// MenuMatchedGlass is glass that draws with an open menu's filter. A menu's
/// glass of the same variant blurs and tints differently (blur 4 against 10,
/// a refraction rim, a darker face), set up by AppKit in a way that copying
/// its properties doesn't reproduce, so its filter is copied instead. The
/// glass rebuilds its filter on every size change, so it is put back after.
final class MenuMatchedGlass: NSGlassEffectView {
    var filter: GlassFilter?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyFilter()
    }

    override func layout() {
        super.layout()
        applyFilter()
    }

    private func applyFilter() {
        guard let filter, let layer, let backdrop = backdropLayer(in: layer),
              let current = (backdrop.filters as? [NSObject])?.first,
              let keys = current.value(forKey: "inputKeys") as? [String] else { return }
        for key in keys { if let value = filter[key] { current.setValue(value, forKey: key) } }
        backdrop.filters = [current]
    }
}

/// glassFilterOfOpenMenu is the filter of an open menu's glass, for
/// MenuMatchedGlass. The window is found as pictureOfOpenMenu finds it.
func glassFilterOfOpenMenu(size: NSSize) -> GlassFilter? {
    guard let window = NSApp.windows.first(where: {
              $0.isVisible && abs($0.frame.width - size.width) < 2 && abs($0.frame.height - size.height) < 2
          }),
          let glass = window.contentView else { return nil }
    let inputs = glassFilter(of: glass)
    zoomLog.notice("recorded menu glass: \(inputs?.count ?? 0) inputs")
    return inputs
}

/// glassFilter is the inputs of the filter `glass` draws with.
private func glassFilter(of glass: NSView) -> GlassFilter? {
    guard let layer = glass.layer, let backdrop = backdropLayer(in: layer),
          let filter = (backdrop.filters as? [NSObject])?.first,
          let keys = filter.value(forKey: "inputKeys") as? [String] else { return nil }
    var inputs = GlassFilter()
    for key in keys { if let value = filter.value(forKey: key) { inputs[key] = value } }
    return inputs
}

/// logGlassDifference logs where the shape's glass differs from the menu's,
/// as the menu takes over from it.
private func logGlassDifference(shape: NSView?, menu: NSView?) {
    guard let shape, let menu, let shown = glassFilter(of: shape), let wanted = glassFilter(of: menu) else {
        func describe(_ view: NSView?) -> String {
            guard let view else { return "no view" }
            guard let layer = view.layer else { return "\(type(of: view)) no layer" }
            guard let backdrop = backdropLayer(in: layer) else { return "\(type(of: view)) no backdrop" }
            return "\(type(of: view)) filters \(String(describing: backdrop.filters))"
        }
        zoomLog.notice("handover: no glass to compare; shape \(describe(shape), privacy: .public); menu \(describe(menu), privacy: .public)")
        return
    }
    let differing = wanted.keys.sorted().filter { "\(wanted[$0]!)" != "\(shown[$0] ?? "-")" }
        .map { "\($0) menu=\(wanted[$0]!) shape=\(shown[$0] ?? "-")" }
    zoomLog.notice("handover: \(differing.count) inputs differ: \(differing.joined(separator: "; "), privacy: .public)")
}

/// backdropLayer is the CABackdropLayer glass draws with, which holds its filter.
private func backdropLayer(in layer: CALayer) -> CALayer? {
    if NSStringFromClass(type(of: layer)).contains("Backdrop") { return layer }
    for sublayer in layer.sublayers ?? [] {
        if let backdrop = backdropLayer(in: sublayer) { return backdrop }
    }
    return nil
}

/// removeUnderMenu takes `window` away once a menu window shows over it, and
/// returns the timer watching for that. It runs in the tracking mode too, the
/// only one that runs while a menu is open.
///
/// The swap has to land in one frame. The menu's glass is clear, so a shape
/// left under it shows through, lighter and with its picture of the rows as a
/// blurred ghost (recorded: 3 to 4 bright frames with the shape 50ms under).
/// Ordered out at once, the shape leaves the bare backdrop instead: a menu
/// window counts as visible once it is ordered in, before it is drawn, and
/// ordering out goes to the window server straight away. So the shape's
/// content is hidden instead, a layer change that goes out in the same commit
/// as the menu's first drawing, and its emptied window ordered out after.
private func removeUnderMenu(_ window: NSWindow) -> Timer {
    /// maxMenuWait is how long the shape waits for the menu's glass at most;
    /// emptyWindowTime how long its emptied window stays before it goes.
    let maxMenuWait: TimeInterval = 0.3
    let emptyWindowTime: TimeInterval = 0.1
    var seen: Date?
    var hidden: Date?
    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { timer in
        if let hidden {
            guard Date().timeIntervalSince(hidden) >= emptyWindowTime else { return }
            timer.invalidate()
            window.orderOut(nil)
            return
        }
        guard let menu = NSApp.windows.first(where: {
            $0.isVisible && NSStringFromClass(type(of: $0)) == "NSPopupMenuWindow"
        }) else { return }
        let drawn = menu.contentView.flatMap { glassFilter(of: $0) } != nil
        if seen == nil { seen = Date() }
        let waited = Date().timeIntervalSince(seen!)
        guard drawn || waited > maxMenuWait else { return }
        logGlassDifference(shape: window.contentView, menu: menu.contentView)
        zoomLog.notice("shape hidden after \(waited) s, menu glass \(drawn)")
        window.contentView?.isHidden = true
        hidden = Date()
    }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .eventTracking)
    return timer
}

/// pictureOfOpenMenu takes a picture of an open menu's rows, without the glass
/// behind them, for zoomOpen to grow the next time. The menu's window is the
/// app's own, found by its size; its content view is the glass, whose first
/// subview holds the rows. Call it while the menu is showing.
func pictureOfOpenMenu(size: NSSize) -> NSImage? {
    guard let window = NSApp.windows.first(where: {
              $0.isVisible && abs($0.frame.width - size.width) < 2 && abs($0.frame.height - size.height) < 2
          }),
          let rows = window.contentView?.subviews.first,
          let rep = rows.bitmapImageRepForCachingDisplay(in: rows.bounds) else { return nil }
    // A text field pictured offscreen draws its text twice, so translucent
    // text comes out more opaque than the menu shows it (60% white as 84%).
    // Its cell draws it once: the fields are left out of the picture and
    // their cells drawn into it after.
    let labels = textFields(in: rows)
    labels.forEach { $0.isHidden = true }
    picturingMenu = true
    defer { picturingMenu = false }
    rows.cacheDisplay(in: rows.bounds, to: rep)
    labels.forEach { $0.isHidden = false }
    if let context = NSGraphicsContext(bitmapImageRep: rep) {
        NSGraphicsContext.saveGraphicsState()
        for label in labels { drawCell(of: label, in: rows, into: context) }
        NSGraphicsContext.restoreGraphicsState()
    }
    let picture = NSImage(size: rows.bounds.size)
    picture.addRepresentation(rep)
    return picture
}

/// picturingMenu is set while pictureOfOpenMenu takes its picture. Rows and
/// buttons leave out their hover then: the menu opens with nothing under the
/// mouse, so the shape growing into it shouldn't show a row lit that goes out
/// when the menu takes over.
var picturingMenu = false

/// textFields is every shown text field under `view`.
private func textFields(in view: NSView) -> [NSTextField] {
    view.subviews.flatMap { sub -> [NSTextField] in
        if let field = sub as? NSTextField { return field.isHiddenOrHasHiddenAncestor ? [] : [field] }
        return textFields(in: sub)
    }
}

/// drawCell draws `label`'s cell into `context`, a picture of `rows`, where
/// the label sits in it.
private func drawCell(of label: NSTextField, in rows: NSView, into context: NSGraphicsContext) {
    var frame = label.convert(label.bounds, to: rows)
    if rows.isFlipped { frame.origin.y = rows.bounds.height - frame.maxY }
    let transform = NSAffineTransform()
    transform.translateX(by: frame.minX, yBy: frame.minY)
    if label.isFlipped {
        transform.translateX(by: 0, yBy: frame.height)
        transform.scaleX(by: 1, yBy: -1)
    }
    NSGraphicsContext.current = context
    NSGraphicsContext.saveGraphicsState()
    transform.concat()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: label.isFlipped)
    label.cell?.draw(withFrame: label.bounds, in: label)
    NSGraphicsContext.restoreGraphicsState()
}
