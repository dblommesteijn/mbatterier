import AppKit
import os

/// controlCenterBundleID is the process that draws Control Center's panel and
/// the system's own menu bar items.
private let controlCenterBundleID = "com.apple.controlcenter"

/// minimumWindowHeight tells the open panel's window from Control Center's
/// menu bar items, which are its windows too but only as tall as the bar.
private let minimumWindowHeight: CGFloat = 100

/// The open panel's corner, measured from the screen rather than the window:
/// the panel is drawn inside a larger transparent window that runs off the
/// right of the screen and up into the menu bar, so the window's bounds don't
/// say where the panel is. The panel sits this far from the screen's right
/// edge and below the menu bar.
private let panelRightInset: CGFloat = 10
private let panelTopGap: CGFloat = 5

private let log = Logger(subsystem: "it.blommesteijn.mbatterier", category: "controlcenter")

/// controlCenterCorner is the top right corner of the open Control Center
/// panel in screen coordinates (AppKit's, origin bottom left), or nil when it
/// isn't open. Window bounds and owners need no Screen Recording permission;
/// only titles would.
func controlCenterCorner() -> NSPoint? {
    guard let primary = NSScreen.screens.first else { return nil }
    guard let window = controlCenterPanelWindow() else {
        log.notice("Control Center not open")
        return nil
    }
    // Window bounds are measured from the primary screen's top left, AppKit's
    // from its bottom left. The panel is on the screen the window is on.
    let flipped = NSRect(x: window.minX, y: primary.frame.maxY - window.maxY,
                         width: window.width, height: window.height)
    let screen = NSScreen.screens.first { $0.frame.intersects(flipped) } ?? primary
    let corner = NSPoint(x: screen.frame.maxX - panelRightInset, y: screen.visibleFrame.maxY - panelTopGap)
    log.notice("window \(String(describing: window), privacy: .public) corner \(String(describing: corner), privacy: .public)")
    return corner
}

/// controlCenterIsOpen says whether Control Center's panel is on screen,
/// without logging: the collapse asks it every frame while it waits.
func controlCenterIsOpen() -> Bool {
    controlCenterPanelWindow() != nil
}

/// controlCenterPanelWindow is the bounds of Control Center's open panel
/// window (CG's, origin top left), or nil when it isn't open.
private func controlCenterPanelWindow() -> CGRect? {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return nil }
    return windows.lazy.compactMap { info -> CGRect? in
        guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == controlCenterBundleID,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              rect.height >= minimumWindowHeight else { return nil }
        return rect
    }.first
}
