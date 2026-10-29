import AppKit
import ApplicationServices

/// ActivityMonitor shows an app in Activity Monitor, as a click on an app in
/// macOS's own "Using Significant Energy" list does: it opens Activity Monitor
/// and selects the app's row. Activity Monitor has no API for that, so the row
/// is found and selected through Accessibility, which needs this app to be
/// allowed under Privacy & Security → Accessibility. The tab, the view and the
/// sorting are left as they are; without the permission, or without a matching
/// row on the tab that is showing, Activity Monitor just opens.
enum ActivityMonitor {
    private static let bundleID = "com.apple.ActivityMonitor"
    /// tries and interval bound the wait for Activity Monitor's table, which
    /// fills in a moment after launch.
    private static let tries = 25
    private static let interval: TimeInterval = 0.2

    static func show(_ app: NSRunningApplication?, named name: String) {
        // Activity Monitor lists an app by its process name, which can differ
        // from the bundle's folder name the energy list uses ("Code" for
        // "Visual Studio Code").
        let names = [app?.localizedName, app?.executableURL?.lastPathComponent, name].compactMap { $0 }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { monitor, _ in
            guard let monitor else { return }
            DispatchQueue.main.async {
                // Asks for the permission once; a no until it is granted.
                let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                guard AXIsProcessTrustedWithOptions(prompt) else { return }
                select(names, in: monitor.processIdentifier, triesLeft: tries)
            }
        }
    }

    /// select selects the first row named one of names in Activity Monitor's
    /// table and scrolls it into view, trying again while the table fills.
    private static func select(_ names: [String], in pid: pid_t, triesLeft: Int) {
        let monitor = AXUIElementCreateApplication(pid)
        if let window: AXUIElement = value(monitor, kAXMainWindowAttribute),
           let table = find(window, role: kAXOutlineRole) ?? find(window, role: kAXTableRole),
           let rows: [AXUIElement] = value(table, kAXRowsAttribute),
           let row = names.lazy.compactMap({ name in rows.first { rowName($0) == name } }).first {
            AXUIElementSetAttributeValue(table, kAXSelectedRowsAttribute as CFString, [row] as CFArray)
            AXUIElementPerformAction(row, "AXScrollToVisible" as CFString)
            return
        }
        guard triesLeft > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            select(names, in: pid, triesLeft: triesLeft - 1)
        }
    }

    /// rowName is the text of a row's first cell: the process name.
    private static func rowName(_ row: AXUIElement) -> String? {
        guard let cells: [AXUIElement] = value(row, kAXChildrenAttribute), let cell = cells.first else { return nil }
        if let text: String = value(cell, kAXValueAttribute) { return text }
        guard let parts: [AXUIElement] = value(cell, kAXChildrenAttribute) else { return nil }
        return parts.lazy.compactMap { value($0, kAXValueAttribute) as String? }.first
    }

    /// find is the first element with role under element, depth first.
    private static func find(_ element: AXUIElement, role: String, depth: Int = 0) -> AXUIElement? {
        if (value(element, kAXRoleAttribute) as String?) == role { return element }
        guard depth < 8, let children: [AXUIElement] = value(element, kAXChildrenAttribute) else { return nil }
        for child in children {
            if let found = find(child, role: role, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result as? T
    }
}
