import AppKit
import os

private let zoomLog = Logger(subsystem: "it.blommesteijn.mbatterier", category: "zoom")

/// zoomDuration and zoomCurve are how the shape grows. Control Center opens a
/// module's details (recorded at 60fps) in about 0.23s, but most of the way
/// in the first part and then a slow settle into place, which reads as
/// slower than an even ease-out of the same length; a little longer and a
/// curve with a long soft tail comes closer.
private let zoomDuration: TimeInterval = 0.30
private let zoomCurve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
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
/// a timer in the tracking mode. When `open` returns the menu has closed, and
/// the shape collapses from where the menu was back into `start`, the way
/// it grew. `closing` gives the menu's rows and size as it closed.
func zoomOpen(from start: NSRect, to end: NSRect, picture: NSImage?, glass: GlassFilter?,
              open: @escaping () -> Void, closing: @escaping () -> (picture: NSImage?, size: NSSize)) {
    let window = ZoomWindow(contentRect: start, styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    // A level above menus: Control Center's panel, fading out after the tap,
    // is at the menu level too and sometimes brings itself to the front again,
    // over the shape (recorded), so the menu's arrival over it flashed. The
    // shape is hidden as the menu shows, so being above the menu does no harm.
    window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    window.ignoresMouseEvents = true
    window.isReleasedWhenClosed = false
    window.appearance = controlCenterAppearance

    let shape = MenuMatchedGlass()
    shape.filter = glass
    shape.cornerRadius = zoomCornerRadius
    useControlCenterGlass(shape)
    window.contentView = shape
    // Always there, also without a picture yet, so the collapse has
    // somewhere to put the one taken while the menu was open.
    let rows = NSImageView(frame: shape.bounds)
    rows.image = picture.map { topAligned($0, in: end.size) }
    rows.imageScaling = .scaleAxesIndependently
    rows.autoresizingMask = [.width, .height]
    // In a plain holder: as the glass's content itself, the picture's own
    // size would hold the window at the menu's size from the start, and
    // the shape would slide rather than grow.
    let holder = NSView(frame: shape.bounds)
    holder.addSubview(rows)
    shape.contentView = holder
    // The menu's glass from the first frame, not faded in: drawn and
    // committed before the window shows.
    window.displayIfNeeded()
    CATransaction.flush()
    window.orderFrontRegardless()

    NSAnimationContext.runAnimationGroup({ context in
        context.duration = zoomDuration
        context.timingFunction = zoomCurve
        window.animator().setFrame(end, display: true)
    }, completionHandler: {
        // The last step of the animation may not have reached the screen
        // yet, and the menu replaces the shape in the next commit: the menu
        // jumped the last few points (recorded). The end frame shows first.
        window.setFrame(end, display: true)
        CATransaction.flush()
        let handover = Timer(timeInterval: 1.0 / 60, repeats: false) { _ in
            handOver(window, rows: rows, from: start, to: end, open: open, closing: closing)
        }
        RunLoop.main.add(handover, forMode: .common)
    })
}

/// handOver opens the menu over the grown shape and, once the menu closes,
/// collapses the shape back into `start`.
private func handOver(_ window: NSWindow, rows: NSImageView, from start: NSRect, to end: NSRect,
                      open: () -> Void, closing: @escaping () -> (picture: NSImage?, size: NSSize)) {
    let removal = removeUnderMenu(window)
    var collapsed = false
    var closeWatch: Timer?
    let collapse = {
        guard !collapsed else { return }
        collapsed = true
        removal.invalidate()
        closeWatch?.invalidate()
        MenuDrawSignal.onDraw = nil
        let closed = closing()
        // Where the menu is as it closes: it keeps its top left where it
        // opened, but may have grown or shrunk while open.
        let from = menuWindow(at: end)?.frame
            ?? NSRect(x: end.minX, y: end.maxY - closed.size.height,
                      width: closed.size.width, height: closed.size.height)
        zoomClose(window, rows: rows, picture: closed.picture, from: from, to: start)
        // The shape now shows the menu; the menu's own fade underneath
        // would show through the glass around it as it shrinks.
        menuWindow(at: end)?.orderOut(nil)
    }
    closeWatch = watchMenuClosing(at: end, then: collapse)
    collapseZoom = collapse
    // A click on another menu bar item (the Control Center button) takes the
    // menu away at once, without the fade watchMenuClosing waits for: the
    // system hides it as the click lands, before any app hears of it
    // (recorded: gone in the click's frame, with the click reaching a
    // listen-only event tap 15 ms later, a global monitor 40 ms later). So
    // the shape stands in for the menu while the pointer is in the menu bar,
    // where no click can be meant for the menu (watchMenuBar), and the tap
    // starts the collapse from there.
    let clickWatch = watchClicks(then: collapse)
    let barWatch = watchMenuBar(window, rows: rows, menuAt: end, picture: { closing().picture })
    open()
    clickWatch()
    barWatch()
    collapseZoom = nil
    // In case the menu closed without either noticing.
    collapse()
}

/// topAligned redraws `picture` at `size`: scaled to its width and pinned to
/// its top, as the menu lays its rows out. The picture is from the last time
/// the menu showed, and the menu may have another height now (an app joining
/// or leaving the energy list); scaled to fit, it was centred, so its rows sat
/// lower or higher than the menu's, with a different margin above and below.
/// Done once, so the image view can scale the result on the GPU as the shape
/// grows: drawn per frame instead, it froze while AppKit's fade of the closing
/// menu held the main thread (recorded).
private func topAligned(_ picture: NSImage, in size: NSSize) -> NSImage {
    guard picture.size.width > 0, size.width > 0, size.height > 0 else { return picture }
    let height = picture.size.height * size.width / picture.size.width
    let image = NSImage(size: size)
    image.lockFocus()
    picture.draw(in: NSRect(x: 0, y: size.height - height, width: size.width, height: height))
    image.unlockFocus()
    return image
}

/// watchMenuBar shows the shape in the menu's place while the pointer is in
/// the menu bar, the menu's window made transparent under it, and puts the
/// menu back when the pointer leaves; it returns what stops watching. The
/// picture is of the rows with nothing lit, as they are with the pointer out
/// of the menu. A timer in the tracking mode, which the menu runs.
private func watchMenuBar(_ window: NSWindow, rows: NSImageView, menuAt end: NSRect,
                          picture: @escaping () -> NSImage?) -> () -> Void {
    var standingIn = false
    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
        guard let menu = menuWindow(at: end), menu.alphaValue > 0 || standingIn else { return }
        let inBar = pointerInMenuBar()
        guard inBar != standingIn, window.contentView?.isHidden == false else { return }
        standingIn = inBar
        if inBar {
            if let picture = picture() { rows.image = topAligned(picture, in: menu.frame.size) }
            window.setFrame(menu.frame, display: true)
            window.hasShadow = true
            window.displayIfNeeded()
            CATransaction.flush()
            window.alphaValue = 1
            menu.alphaValue = 0
        } else {
            menu.alphaValue = 1
            window.alphaValue = 0
            window.hasShadow = false
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .eventTracking)
    return {
        timer.invalidate()
        // AppKit may show the same window for the next menu.
        for menu in NSApp.windows where NSStringFromClass(type(of: menu)) == "NSPopupMenuWindow" {
            menu.alphaValue = 1
        }
    }
}

/// watchClicks calls `then` on any mouse down while the menu is open, and
/// returns what stops watching. The tap runs on the main run loop in the
/// common modes, which the menu's tracking mode is one of.
private func watchClicks(then: @escaping () -> Void) -> () -> Void {
    final class Box { let then: () -> Void; init(_ then: @escaping () -> Void) { self.then = then } }
    let box = Unmanaged.passRetained(Box(then))
    let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
    if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                   eventsOfInterest: mask, callback: { _, type, event, info in
        if type == .leftMouseDown, let info {
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().then()
        }
        return Unmanaged.passUnretained(event)
    }, userInfo: box.toOpaque()), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) {
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(tap)
            box.release()
        }
    }
    let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in then() }
    return {
        monitor.map(NSEvent.removeMonitor)
        box.release()
    }
}

/// watchMenuClosing calls `then` as the menu at `end` starts to close. AppKit
/// fades a closing menu out by lowering its window's alpha frame by frame
/// (measured: 0.86, 0.71, 0.55 … over 0.25s), and tells menuDidClose and
/// didEndTracking only once it is gone, so the first drop in alpha is the
/// earliest sign. A submenu closing doesn't count: only the menu's own
/// window is watched.
private func watchMenuClosing(at end: NSRect, then: @escaping () -> Void) -> Timer {
    let timer = Timer(timeInterval: 1.0 / 240, repeats: true) { timer in
        guard let menu = menuWindow(at: end) else { return }
        // Exactly 0 is watchMenuBar's stand-in, not a fade.
        guard menu.alphaValue < 1 && menu.alphaValue > 0 else { return }
        timer.invalidate()
        then()
    }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .eventTracking)
    return timer
}

/// menuWindow is the visible menu window whose top left is at `end`'s, the
/// menu zoomOpen opened rather than one of its submenus.
private func menuWindow(at end: NSRect) -> NSWindow? {
    NSApp.windows.first { $0.isVisible && isMenuWindow($0, at: end) }
}

private func isMenuWindow(_ window: NSWindow, at end: NSRect) -> Bool {
    NSStringFromClass(type(of: window)) == "NSPopupMenuWindow"
        && abs(window.frame.minX - end.minX) < 2 && abs(window.frame.maxY - end.maxY) < 2
}

/// collapseZoom starts the open shape's collapse, set while a menu zoomOpen
/// opened is showing, for menuDidClose: a fallback should watchMenuClosing
/// miss the menu's fade.
var collapseZoom: (() -> Void)?

/// zoomClose shrinks the shape zoomOpen grew from `from`, where the menu
/// was, back into `to`, then takes it away: the menu seems to go back into
/// the tile it came from.
private func zoomClose(_ window: NSWindow, rows: NSImageView, picture: NSImage?, from: NSRect, to: NSRect) {
    if let picture { rows.image = topAligned(picture, in: from.size) }
    window.setFrame(from, display: false)
    window.contentView?.isHidden = false
    window.hasShadow = true
    window.displayIfNeeded()
    CATransaction.flush()
    window.alphaValue = 1
    window.orderFrontRegardless()
    // The tile is only there to shrink into once Control Center is back,
    // which a click on its menu bar button brings, a moment later (recorded:
    // its panel appeared about 0.45 s after the click, then faded in over
    // 0.15 s). Until then the shape stays where the menu was. Any other way
    // out leaves no tile to go back to, and the shape fades where it is.
    guard pointerInMenuBar() else { return fadeOut(window) }
    waitForControlCenter { open in
        open ? shrink(window, to: to) : fadeOut(window)
    }
}

/// shrink takes the shape back into the tile it grew from.
private func shrink(_ window: NSWindow, to: NSRect) {
    NSAnimationContext.runAnimationGroup({ context in
        context.duration = zoomDuration
        context.timingFunction = zoomCurve
        window.animator().setFrame(to, display: true)
    }, completionHandler: {
        window.orderOut(nil)
    })
    // Faded out towards the end: the curve's long soft tail, which settles
    // the opening into place, would otherwise leave a tile-sized shape
    // lingering over Control Center's own tile.
    NSAnimationContext.runAnimationGroup { context in
        context.duration = zoomDuration
        context.timingFunction = CAMediaTimingFunction(name: .easeIn)
        window.animator().alphaValue = 0
    }
}

/// fadeOut fades the shape where it is, as AppKit fades a closing menu
/// (measured: 0.25 s).
private func fadeOut(_ window: NSWindow) {
    NSAnimationContext.runAnimationGroup({ context in
        context.duration = menuFadeDuration
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        window.animator().alphaValue = 0
    }, completionHandler: {
        window.orderOut(nil)
    })
}

private let menuFadeDuration: TimeInterval = 0.25

/// controlCenterWait is how long the shape waits for Control Center to come
/// back after a click in the menu bar; the panel was seen after 0.45 s. A
/// click on another menu bar item brings none, and the shape fades then.
private let controlCenterWait: TimeInterval = 0.8

/// pointerInMenuBar is whether the mouse is in the menu bar, where the click
/// that closed the menu was.
private func pointerInMenuBar() -> Bool {
    let pointer = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) else { return false }
    return pointer.y >= screen.visibleFrame.maxY
}

/// waitForControlCenter calls `then(true)` as soon as Control Center's panel
/// is on screen, or `then(false)` after controlCenterWait. A timer in the
/// tracking mode too, should a menu be open meanwhile.
private func waitForControlCenter(then: @escaping (Bool) -> Void) {
    let started = Date()
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
        let open = controlCenterIsOpen()
        guard open || Date().timeIntervalSince(started) > controlCenterWait else { return }
        timer.invalidate()
        then(open)
    }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .eventTracking)
}

/// ZoomWindow is the window the shape grows in. It has the active look a
/// menu's window has: glass in an inactive window leaves out the light rim
/// along its edges, which the menu's glass draws, so the rim appeared only
/// when the menu took over. A private method AppKit asks; where it is gone,
/// the shape just lacks the rim.
final class ZoomWindow: NSWindow {
    @objc func _hasActiveAppearance() -> Bool { true }
}

/// GlassFilter is how a glass's backdrop layer draws: its filter's inputs, by
/// name, and how far past its edges it samples what is behind it, which its
/// edge refraction bends in (the menu's glass samples 11pt, a glass whose
/// filter was replaced only 0.5pt).
struct GlassFilter {
    var inputs: [String: Any]
    var marginWidth: Any?
}

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
        for key in keys { if let value = filter.inputs[key] { current.setValue(value, forKey: key) } }
        backdrop.filters = [current]
        if let margin = filter.marginWidth { backdrop.setValue(margin, forKey: "marginWidth") }
    }
}

/// glassFilterOfOpenMenu is the filter of an open menu's glass, for
/// MenuMatchedGlass. The window is found as pictureOfOpenMenu finds it.
func glassFilterOfOpenMenu(size: NSSize) -> GlassFilter? {
    guard let window = openMenuWindow(size: size),
          let glass = window.contentView else { return nil }
    let inputs = glassFilter(of: glass)
    zoomLog.notice("recorded menu glass: \(inputs?.inputs.count ?? 0) inputs")
    return inputs
}

/// glassFilter is the inputs of the filter `glass` draws with.
private func glassFilter(of glass: NSView) -> GlassFilter? {
    guard let layer = glass.layer, let backdrop = backdropLayer(in: layer),
          let filter = (backdrop.filters as? [NSObject])?.first,
          let keys = filter.value(forKey: "inputKeys") as? [String] else { return nil }
    var inputs: [String: Any] = [:]
    for key in keys { if let value = filter.value(forKey: key) { inputs[key] = value } }
    return GlassFilter(inputs: inputs, marginWidth: backdrop.value(forKey: "marginWidth"))
}

/// backdropLayer is the CABackdropLayer glass draws with, which holds its filter.
private func backdropLayer(in layer: CALayer) -> CALayer? {
    if NSStringFromClass(type(of: layer)).contains("Backdrop") { return layer }
    for sublayer in layer.sublayers ?? [] {
        if let backdrop = backdropLayer(in: sublayer) { return backdrop }
    }
    return nil
}

/// removeUnderMenu empties `window` as the menu draws over it, and returns
/// the timer that empties it anyway if the menu doesn't draw in time, and
/// then makes it a transparent, drawn window. It stays up, so the collapse
/// can show it in the frame the menu goes (see collapseZoom). The timer runs in the tracking mode too,
/// the only one that runs while a menu is open.
///
/// The swap has to land in one frame. The menu's glass is clear, so a shape
/// left under it shows through, lighter and with its picture of the rows as a
/// blurred ghost (recorded: one such frame whenever the swap lagged). Ordered
/// out early, the shape leaves the bare backdrop instead: a menu window counts
/// as visible once it is ordered in, before it is drawn, and ordering out goes
/// to the window server straight away. So the shape's content is hidden, a
/// layer change, from within the menu's first drawing (see MenuDrawSignal),
/// which puts it in the same commit as that drawing. Watching for the menu
/// with the timer instead missed that commit about one time in six.
private func removeUnderMenu(_ window: NSWindow) -> Timer {
    /// maxMenuWait is how long the shape waits for the menu to draw at most.
    let maxMenuWait: TimeInterval = 0.5
    let started = Date()
    var hidden: Date?
    func hide(_ reason: String) {
        guard hidden == nil else { return }
        MenuDrawSignal.onDraw = nil
        window.contentView?.isHidden = true
        hidden = Date()
        zoomLog.notice("shape hidden after \(hidden!.timeIntervalSince(started)) s: \(reason, privacy: .public)")
    }
    MenuDrawSignal.onDraw = { hide("menu drawing") }
    // Once the menu is up, the shape is drawn again in a transparent window:
    // ready for the collapse to show with a change of alpha alone. Shown by
    // drawing its glass afresh, it came about 60 ms after a menu that went
    // at once, a frame or more with neither (recorded).
    let ready: TimeInterval = 0.1
    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { timer in
        if hidden == nil && Date().timeIntervalSince(started) > maxMenuWait { hide("timed out") }
        guard let hidden, Date().timeIntervalSince(hidden) >= ready else { return }
        timer.invalidate()
        window.alphaValue = 0
        window.hasShadow = false
        window.contentView?.isHidden = false
        window.displayIfNeeded()
    }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .eventTracking)
    return timer
}

/// MenuDrawSignal is a menu item's view that says when the menu draws, from
/// within that drawing, for removeUnderMenu. Put it on an item that is always
/// shown. It draws nothing itself.
final class MenuDrawSignal: NSView {
    static var onDraw: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        guard !picturingMenu else { return }
        Self.onDraw?()
    }
}

/// openMenuWindow is the app's showing menu window of `size`. Only menu
/// windows: the shape zoomOpen grew stays up, emptied, at the menu's size
/// while the menu is open, and a picture of it is a blank one.
func openMenuWindow(size: NSSize) -> NSWindow? {
    NSApp.windows.first {
        $0.isVisible && NSStringFromClass(type(of: $0)) == "NSPopupMenuWindow"
            && abs($0.frame.width - size.width) < 2 && abs($0.frame.height - size.height) < 2
    }
}

/// pictureOfOpenMenu takes a picture of an open menu's rows, without the glass
/// behind them, for zoomOpen to grow the next time. The menu's window is the
/// app's own, found by its size; its content view is the glass, whose first
/// subview holds the rows. Call it while the menu is showing.
func pictureOfOpenMenu(size: NSSize) -> NSImage? {
    guard let window = openMenuWindow(size: size),
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

