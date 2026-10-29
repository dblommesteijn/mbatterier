import AppKit
import UniformTypeIdentifiers
import IOKit.ps
import WidgetKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// refreshEvery is the fallback poll. Changes show sooner through the
    /// triggers in watchForChanges: the power source, the power mode and the
    /// boost and watcher state each prompt a read as they happen. Each read
    /// spawns a process (~30ms), so the poll stays slow.
    private let refreshEvery: TimeInterval = 15

    /// changeSources keep the triggers alive; pendingRefresh coalesces a burst
    /// of them into one read.
    private var changeSources: [DispatchSourceFileSystemObject] = []
    private var pendingRefresh: DispatchWorkItem?

    /// glyphSize is the stopwatch's size in the title, a shade under the 13pt
    /// font's cap height so it doesn't tower over the digits.
    private let glyphSize: CGFloat = 11
    /// markSize is the eye's, larger than the stopwatch: its strokes are thin
    /// and open, so at the stopwatch's size it reads as smaller. The ∞ is
    /// wider than tall, so it reads as larger at the same size and is 2pt less.
    private let markSize: CGFloat = 16
    private let alwaysSize: CGFloat = 14

    /// defaultBoost is what the High Power row asks for. The CLI has no
    /// "set High Power indefinitely" command — a boost is always timed — so a
    /// duration has to be chosen here, and this matches `mbat boost`'s own
    /// default.
    private let defaultBoost = "1h"

    /// The two display settings. They only decide what the bar shows; the
    /// menu and tooltip always carry the full detail. Both default to on, so a
    /// fresh install shows everything.
    private enum Setting: String {
        case remainingTime = "showRemainingTime"
        case boostTime = "showBoostTime"
        /// boostSeconds writes the bar's countdown as MM:SS instead of whole
        /// minutes. Off by default.
        case boostSeconds = "showBoostSeconds"
        /// watchMode is whether the app starts a watcher when it launches.
        /// The watch button in the header sets it.
        case watchMode = "watchMode"
        /// The menu bar's marks, each one on by default.
        case watchIcon = "showWatchIcon"
        case alwaysIcon = "showAlwaysBoostIcon"
        case highPowerIcon = "showHighPowerIcon"
        case lowPowerIcon = "showLowPowerIcon"
        /// monochrome draws the bar in its own text colour, without the
        /// yellow and purple of the power modes. Off by default.
        case monochrome = "monochromeBar"
        /// lowPowerBatteryColor keeps the battery icon yellow in Low Power
        /// while the bar is monochrome. Off by default.
        case lowPowerBatteryColor = "lowPowerBatteryColor"
        /// highPowerBatteryColor does the same in High Power, in purple.
        case highPowerBatteryColor = "highPowerBatteryColor"

        var isOn: Bool {
            UserDefaults.standard.object(forKey: rawValue) as? Bool ?? !([.boostSeconds, .monochrome, .lowPowerBatteryColor, .highPowerBatteryColor].contains(self))
        }
    }

    private let remainingTimeItem = NSMenuItem(title: "Show Remaining Battery Time",
                                               action: #selector(toggleRemainingTime), keyEquivalent: "")
    private let boostTimeItem = NSMenuItem(title: "Show Boost Timer Countdown",
                                           action: #selector(toggleBoostTime), keyEquivalent: "")
    private let watchIconItem = NSMenuItem(title: "Show Watch-Mode Icon",
                                           action: #selector(toggleWatchIcon), keyEquivalent: "")
    private let boostSecondsItem = NSMenuItem(title: "Show Seconds",
                                               action: #selector(toggleBoostSeconds), keyEquivalent: "")
    private let alwaysIconItem = NSMenuItem(title: "Show Always-On Boost Icon",
                                            action: #selector(toggleAlwaysIcon), keyEquivalent: "")
    private let highPowerIconItem = NSMenuItem(title: "Show High Power Icon",
                                               action: #selector(toggleHighPowerIcon), keyEquivalent: "")
    private let lowPowerIconItem = NSMenuItem(title: "Show Low Power Icon",
                                              action: #selector(toggleLowPowerIcon), keyEquivalent: "")
    /// BarIcon is a menu bar mark that can keep a colour of its own while the
    /// rest of the bar is monochrome.
    private enum BarIcon: String, CaseIterable {
        case watch, always, highPower, lowPower

        var title: String {
            switch self {
            case .watch: return "Watch Icon Color"
            case .always: return "Always-On Icon Color"
            case .highPower: return "High Power Icon Color"
            case .lowPower: return "Low Power Icon Color"
            }
        }

        /// shown is the setting that puts the mark in the bar at all.
        var shown: Setting {
            switch self {
            case .watch: return .watchIcon
            case .always: return .alwaysIcon
            case .highPower: return .highPowerIcon
            case .lowPower: return .lowPowerIcon
            }
        }

        var key: String { rawValue + "IconColor" }

        /// color is the chosen override, monochrome when none was chosen.
        var color: IconColor {
            IconColor(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .monochrome
        }
    }

    /// IconColor is what a BarIcon is drawn in while the bar is monochrome:
    /// the bar's colour like everything else, or its power mode's colour as
    /// without monochrome. A choice saved from an older build that offered
    /// more colours reads as monochrome.
    private enum IconColor: String, CaseIterable {
        case monochrome, mode

        var title: String {
            switch self {
            case .monochrome: return "Monochrome"
            case .mode: return "Mode Color"
            }
        }
    }

    /// iconColorItems are the per-icon colour rows, shown only while the bar
    /// is monochrome and that icon is shown; colorChoices their submenus' rows.
    private var iconColorItems: [BarIcon: NSMenuItem] = [:]
    private var colorChoices: [BarIcon: [IconColor: NSMenuItem]] = [:]
    /// colorSeparators divide the Show switch from the colour choices in the
    /// submenus that have one.
    private var colorSeparators: [BarIcon: NSMenuItem] = [:]
    private let monochromeItem = NSMenuItem(title: "Monochrome Colors",
                                            action: #selector(toggleMonochrome), keyEquivalent: "")

    private let lowPowerBatteryItem = NSMenuItem(title: "Low Power Battery in Color",
                                                 action: #selector(toggleLowPowerBatteryColor), keyEquivalent: "")

    private let highPowerBatteryItem = NSMenuItem(title: "High Power Battery in Color",
                                                  action: #selector(toggleHighPowerBatteryColor), keyEquivalent: "")

    private var statusItem: NSStatusItem!
    private var readTimer: Timer?
    /// tickTimer exists only while a boost has a countdown to animate.
    private var tickTimer: Timer?
    /// lastTickSeconds is the countdown the last tick drew.
    private var lastTickSeconds: Int?

    /// reading is the last answer from the CLI, and readAt is when it arrived.
    /// The countdown is interpolated from the pair; everything else is shown
    /// exactly as read.
    private var reading: Status?
    private var readAt = Date()
    private var failure: String?
    /// actionError is the last failed click, shown until the next one works.
    private var actionError: String?
    /// controlSnapshot is what the Control Center control was last handed.
    private var controlSnapshot: ControlSnapshot?
    /// menuPicture is the menu's rows as they last showed, which the
    /// control's tap grows into the menu.
    private var menuPicture: NSImage?
    /// menuGlass is the menu's glass filter as it last showed, which the
    /// growing shape draws with, so it looks as the menu will.
    private var menuGlass: GlassFilter?

    // The menu, laid out like macOS's own Battery menu.
    /// headerItem is the menu's top row: the "Battery" headline on the left and
    /// Reload and Close on the right, all in one custom view.
    private let headerItem = NSMenuItem()
    private var menu: NSMenu!
    /// menuIsOpen freezes the menu's width while it is showing, so a countdown
    /// ticking in a line of text can't make the whole menu breathe.
    private var menuIsOpen = false
    /// menuOpenedFromControl is set while the menu is open for the control's
    /// tap: then it has Control Center's glass and dark look, from the menu bar
    /// item the system menu's own.
    private var menuOpenedFromControl = false
    /// menuWidening is how much wider than its natural width the menu is made.
    private let menuWidening: CGFloat = 1.05
    private let sourceItem = InfoItem(lineGap: 2)
    private let errorItem = InfoItem(color: .systemRed)
    /// limitItem is macOS's charge-limit line, under the source.
    private let limitItem = InfoItem(lineGap: 2)
    private let watchItem = InfoItem()
    private let holderSeparator = NSMenuItem.separator()
    /// energyRows are the lines of "Using Significant Energy", one per app
    /// the CLI reports, each with the app's icon; a click shows the app in
    /// Activity Monitor. Unused ones stay hidden. With no app, or no reading, the
    /// section says so on one line (energyNoneItem), as macOS's does, and its
    /// heading is hidden.
    private var energyRows: [NSMenuItem] = []
    private let energyNoneItem = InfoItem()
    private let energySeparator = NSMenuItem.separator()
    private var energyHeader: NSMenuItem!
    /// energyReading is set while a sample is under way, so opening the menu
    /// again meanwhile doesn't start a second one.
    private var energyReading = false
    /// energyReadAt is when the last reading finished. The list is recomputed
    /// at most once per energyRefreshEvery, as Apple's is: watching its log, a
    /// lookup takes about 0.8 s once every 62 s and about 0.1 s in between, so
    /// the menu can show an answer up to a minute old. Re-sampling on every open
    /// also made our own list flip between readings seconds apart.
    private var energyReadAt: Date?
    private let energyRefreshEvery: TimeInterval = 60
    /// menuRows are every row's view, to reset their hover when the menu closes.
    private var menuRows: [MenuRowView] = []
    private var headerButtons: [HoverButton] = []
    private var watchButton: HoverButton!
    private var alwaysButton: HoverButton!
    /// watchStartChecked is set once launch has had its chance to start the
    /// watcher, so that a watcher which later exits stays stopped. It exits
    /// when the mode is changed in macOS, and restarting it would undo that.
    private var watchStartChecked = false
    private var automaticItem: NSMenuItem!
    private var lowItem: NSMenuItem!
    private var highItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A plain status item with no custom view and no background of its own:
        // it draws straight onto the menu bar, so the wallpaper and the bar's
        // own blur show through. Any background we drew would sit on top of
        // that and be the one thing that looks wrong up there.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The whole item is one composed image (see composeBar), no title.
        statusItem.button?.imagePosition = .imageOnly
        // The menu isn't the item's own: macOS opens an item's menu 10pt below
        // the menu bar, and only its own Wi-Fi and Battery menus flush against
        // it. The item opens it itself instead, flush (see openMenuFlush).
        _ = buildMenu()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(openMenuFlush)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])

        readTimer = Timer.scheduledTimer(withTimeInterval: refreshEvery, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Both the charge and the power source can have changed while asleep,
        // and the timer did not run.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshNow),
            name: NSWorkspace.didWakeNotification, object: nil)

        // The stopwatch and the bar's other marks are drawn in an explicit
        // colour rather than tinted by AppKit (see timerIcon), so a switch
        // between a light and a dark bar has to redraw them. That is caught
        // here for a change of system appearance, and by the 15s refresh for
        // anything else, such as a wallpaper that turns the bar light.
        //
        // The button's effectiveAppearance is deliberately not observed: it
        // changes every time render sets the button's title or image, cycling
        // through dark, vibrant dark and vibrant light, so redrawing on it is
        // an endless loop that kept a core busy.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(appearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil)

        watchForChanges()
        watchForMenuRequests()

        refresh()
    }

    // MARK: - The menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        self.menu = menu
        menu.delegate = self

        // Empty space above the first row.
        let topMargin = NSMenuItem()
        topMargin.view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: menuTopMargin))
        topMargin.view?.autoresizingMask = [.width]
        menu.addItem(topMargin)
        headerItem.view = makeHeader()
        menu.addItem(headerItem)
        for item in [sourceItem, limitItem, errorItem] {
            item.isEnabled = false
            menu.addItem(item)
        }

        // The watcher sits where macOS puts "Charge to Full Now". A boost has
        // no line here; its countdown sits behind the High Power row.
        menu.addItem(holderSeparator)
        watchItem.isEnabled = false
        menu.addItem(watchItem)

        menu.addItem(.separator())
        menu.addItem(sectionHeader("Energy Mode"))
        // Same order as the system menu. The Automatic row only shows the
        // state; "Turn Off" below it is what sets it, by stopping mbatterier
        // and handing the mode back to macOS. It is an action rather than a
        // mode, so it carries no tick and no swatch.
        automaticItem = modeRow("Automatic", glyph: .automatic, action: nil)
        menu.addItem(automaticItem)
        menu.addItem(modeRow("Turn Off", glyph: .off, action: #selector(turnOff)))
        lowItem = modeRow("Low Power", glyph: .low, action: #selector(setLowPower))
        highItem = modeRow("High Power", glyph: .high, action: #selector(setHighPower))
        for item in [lowItem!, highItem!] {
            menu.addItem(item)
        }

        // Below the modes, where this tool's own rows end and the list of
        // other apps begins.
        menu.addItem(energySeparator)
        energyHeader = sectionHeader("Using Significant Energy")
        menu.addItem(energyHeader)
        energyNoneItem.isEnabled = false
        menu.addItem(energyNoneItem)
        energyRows = (0..<2).map { _ in
            let item = NSMenuItem(title: "", action: #selector(showInActivityMonitor(_:)), keyEquivalent: "")
            item.target = self
            let row = makeRow("", selectable: true)
            // It brings Activity Monitor forward, so the menu gets out of the way.
            row.closesMenu = true
            item.view = row
            menu.addItem(item)
            return item
        }
        setEnergy([])

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settings.view = makeRow("Settings", selectable: true, accessory: .chevron, hasSubmenu: true)
        let submenu = NSMenu(title: "Settings")
        submenu.delegate = self
        // The two toggles change what the menu bar shows, so they sit under a
        // heading that says so.
        submenu.addItem(sectionHeader("Menu Bar"))
        remainingTimeItem.view = makeRow("Show Remaining Battery Time", selectable: true, accessory: .check)
        boostTimeItem.view = makeRow("Show Boost Timer Countdown", selectable: true, accessory: .check)
        watchIconItem.view = makeRow("Show Watch-Mode Icon", selectable: true, accessory: .check)
        alwaysIconItem.view = makeRow("Show Always-On Boost Icon", selectable: true, accessory: .check)
        highPowerIconItem.view = makeRow("Show High Power Icon", selectable: true, accessory: .check)
        lowPowerIconItem.view = makeRow("Show Low Power Icon", selectable: true, accessory: .check)
        monochromeItem.view = makeRow("Monochrome Colors", selectable: true, accessory: .check)
        lowPowerBatteryItem.view = makeRow("Low Power Battery in Color", selectable: true, accessory: .check)
        highPowerBatteryItem.view = makeRow("High Power Battery in Color", selectable: true, accessory: .check)
        boostSecondsItem.view = makeRow("Show Seconds", selectable: true, accessory: .check)
        for item in [remainingTimeItem, boostTimeItem, boostSecondsItem, watchIconItem, alwaysIconItem, highPowerIconItem, lowPowerIconItem, monochromeItem, lowPowerBatteryItem, highPowerBatteryItem] {
            item.target = self
        }
        // The colour rows sit under Monochrome, since they only apply while
        // it is on, each right after the mark it colours.
        // With a toggle the row is the icon's own: its submenu holds the
        // Show switch above the colour choices, which wait for Monochrome.
        func colorRow(_ icon: BarIcon, title: String? = nil, toggle: NSMenuItem? = nil) -> NSMenuItem {
            let title = title ?? icon.title
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.view = makeRow(title, selectable: true, accessory: .chevron, hasSubmenu: true)
            let colors = NSMenu(title: title)
            colors.delegate = self
            if let toggle {
                colors.addItem(toggle)
                let separator = NSMenuItem.separator()
                colors.addItem(separator)
                colorSeparators[icon] = separator
            }
            var choices: [IconColor: NSMenuItem] = [:]
            for color in IconColor.allCases {
                let choice = NSMenuItem(title: color.title, action: #selector(chooseIconColor(_:)), keyEquivalent: "")
                choice.view = makeRow(color.title, selectable: true, accessory: .check)
                choice.target = self
                choice.representedObject = "\(icon.rawValue):\(color.rawValue)"
                colors.addItem(choice)
                choices[color] = choice
            }
            item.submenu = colors
            iconColorItems[icon] = item
            colorChoices[icon] = choices
            return item
        }
        // The bar's text switches first, then a divider and the colour
        // switches, then another divider and the marks with their colour
        // choices.
        submenu.addItem(remainingTimeItem)
        // The countdown's own row: its submenu holds the Show switch and the
        // seconds option.
        let countdown = NSMenuItem(title: "Boost Timer Countdown", action: nil, keyEquivalent: "")
        countdown.view = makeRow("Boost Timer Countdown", selectable: true, accessory: .chevron, hasSubmenu: true)
        let countdownMenu = NSMenu(title: "Boost Timer Countdown")
        countdownMenu.delegate = self
        countdownMenu.addItem(boostTimeItem)
        countdownMenu.addItem(boostSecondsItem)
        countdown.submenu = countdownMenu
        submenu.addItem(countdown)
        submenu.addItem(.separator())
        submenu.addItem(sectionHeader("Colors"))
        for item in [monochromeItem, highPowerBatteryItem, lowPowerBatteryItem] {
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(sectionHeader("Icons"))
        for item in [colorRow(.watch, title: "Watch-Mode Icon", toggle: watchIconItem),
                     colorRow(.always, title: "Always-On Boost Icon", toggle: alwaysIconItem),
                     colorRow(.highPower, title: "High Power Icon", toggle: highPowerIconItem),
                     colorRow(.lowPower, title: "Low Power Icon", toggle: lowPowerIconItem)] {
            submenu.addItem(item)
        }
        settings.submenu = submenu
        menu.addItem(settings)
        syncSettingItems()

        menu.addItem(.separator())
        let batterySettings = NSMenuItem(title: "Battery Settings…",
                                         action: #selector(openBatterySettings), keyEquivalent: "")
        batterySettings.target = self
        let batteryRow = makeRow("Battery Settings…", selectable: true)
        // It opens System Settings, so the menu gets out of the way.
        batteryRow.closesMenu = true
        batterySettings.view = batteryRow
        menu.addItem(batterySettings)

        widenMenu()
        return menu
    }

    /// makeHeader builds the top row. Reload and Close live here rather than
    /// at the bottom of the menu, so the menu ends with its content. Close is
    /// only the symbol; Reload keeps its label.
    private func makeHeader() -> NSView {
        let height: CGFloat = 26
        let width: CGFloat = 200
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.autoresizingMask = [.width]

        let title = NSTextField(labelWithString: "Battery")
        title.font = .systemFont(ofSize: 13.5, weight: .bold)
        title.textColor = menuTextColor
        title.sizeToFit()
        title.frame.origin = NSPoint(x: menuLeftInset, y: (height - title.frame.height) / 2)
        view.addSubview(title)

        let close = HoverButton(frame: .zero)
        close.image = quitIcon()
        close.target = self
        close.action = #selector(quit)
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.contentTintColor = .labelColor
        close.tip = "Quit MBatterier. A running boost or watcher is a separate process and keeps going."
        close.sizeToFit()
        close.frame.size = NSSize(width: close.frame.width + 8, height: 22)
        close.frame.origin = NSPoint(x: width - 12 - close.frame.width,
                                     y: (height - close.frame.height) / 2)
        let reload = ReloadButton(frame: NSRect(x: 0, y: 0, width: 26, height: 22))
        reload.target = self
        reload.action = #selector(refreshNow)
        reload.isBordered = false
        reload.tip = "Reload: read the battery and power mode now, instead of at the next 15-second refresh."
        reload.frame.origin = NSPoint(x: close.frame.minX - 4 - reload.frame.width,
                                      y: (height - reload.frame.height) / 2)
        let watch = HoverButton(frame: NSRect(x: 0, y: 0, width: 26, height: 22))
        watch.image = watchIcon(on: false)
        watch.target = self
        watch.action = #selector(toggleWatch)
        watch.isBordered = false
        watch.imagePosition = .imageOnly
        watch.contentTintColor = .labelColor
        watch.tip = watchTip(watching: false)
        watch.frame.origin = NSPoint(x: reload.frame.minX - 4 - watch.frame.width,
                                     y: (height - watch.frame.height) / 2)
        watchButton = watch
        let always = HoverButton(frame: NSRect(x: 0, y: 0, width: 26, height: 22))
        always.image = alwaysBoostIcon(on: false)
        always.target = self
        always.action = #selector(toggleAlwaysBoost)
        always.isBordered = false
        always.imagePosition = .imageOnly
        always.contentTintColor = .labelColor
        always.tip = alwaysTip(on: false)
        always.frame.origin = NSPoint(x: watch.frame.minX - 4 - always.frame.width,
                                      y: (height - always.frame.height) / 2)
        alwaysButton = always
        for button in [always, watch, reload, close] {
            // Pinned to the right edge as the menu is widened.
            button.autoresizingMask = [.minXMargin]
            view.addSubview(button)
        }
        headerButtons = [always, watch, reload, close]
        for button in headerButtons {
            button.onEnter = { [weak self] in
                self?.headerButtons.filter { $0 !== button }.forEach { $0.reset() }
            }
        }
        return view
    }

    /// watchTip explains the watch toggle in its current state.
    private func watchTip(watching: Bool, label: String? = nil) -> String {
        if watching {
            return "Watch mode is on: \(label ?? "following the battery charge").\n"
                + "Click to stop watching. The power mode stays as it is."
        }
        return "Watch mode is off.\n"
            + "Click to follow the battery: High Power from 80%, Low Power below 20%, "
            + "left alone in between. Starts with the app."
    }

    /// alwaysTip explains the always-on boost toggle in its current state.
    private func alwaysTip(on: Bool) -> String {
        if on {
            return "Always-on boost is on: High Power until you turn it off, plugged in or not.\n"
                + "Click to stop it. The power mode stays as it is."
        }
        return "Always-on boost is off.\n"
            + "Click for High Power with no time limit, which unplugging doesn't end. "
            + "Changing the mode in Control Center still does."
    }

    /// widenMenu makes the menu menuWidening times its natural width. AppKit
    /// only offers a minimum, so the natural width is measured with no minimum
    /// first.
    private func widenMenu() {
        menu.minimumWidth = 0
        menu.minimumWidth = menu.size.width * menuWidening
    }

    /// quit closes the menu first and asks afterwards: the button sits in a
    /// custom view, which doesn't close the menu on its own, and an alert shown
    /// over an open menu would fight it for the mouse.
    @objc private func quit() {
        menu.cancelTracking()
        DispatchQueue.main.async { self.confirmQuit() }
    }

    private func confirmQuit() {
        // An app with no Dock icon isn't frontmost, so bring the alert forward.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit MBatterier?"
        alert.informativeText = "The battery item disappears from the menu bar until you log in again "
            + "or open the app. A running boost or watcher is a separate process and keeps going."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    /// openMenuFlush opens the menu under the item, menuBarGap below the menu
    /// bar, closer than the 10pt macOS gives an item's own menu, and the item
    /// lit while it is open. Its left edge sits where macOS would put it.
    @objc private func openMenuFlush() {
        guard let button = statusItem.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return }
        button.highlight(true)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: window.frame.minX - popUpInset,
                               y: screen.visibleFrame.maxY - menuBarGap - popUpInset),
                   in: nil)
        button.highlight(false)
    }

    /// menuBarGap is the space between the menu bar and the menu it opens.
    private let menuBarGap: CGFloat = 1

    /// popUpInset, measured on macOS 27: a popped-up menu's window lands this
    /// far above the point it is given (asked for the menu bar's bottom, it
    /// covered the bar by 5pt), and macOS puts an item's own menu this far
    /// left of the item.
    private let popUpInset: CGFloat = 5

    /// watchForMenuRequests listens for the Control Center control's tap. The
    /// control runs sandboxed in another process and can't reach the status
    /// item, and macOS drops the URL an intent hands back, so it writes to a
    /// file in the App Group instead (see ControlSnapshot.requestMenu). The
    /// file is created here so there is something to watch before any tap.
    private func watchForMenuRequests() {
        guard let url = ControlSnapshot.menuRequestURL else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend],
                                                               queue: .main)
        source.setEventHandler { [weak self] in self?.dropMenuDown() }
        source.setCancelHandler { close(fd) }
        source.resume()
        changeSources.append(source)
    }

    /// dropMenuDown opens the menu for the control's tap: on top of Control
    /// Center, its top right corner on Control Center's, the way Apple's
    /// battery details open in place. A third-party control can't open
    /// anything inside Control Center, so this is the nearest to it. With
    /// Control Center already gone it drops down from the item as a click would.
    ///
    /// It grows out of the tapped tile, as Apple's details do (see zoomOpen).
    /// The tap carries no position, but the pointer is still on the tile, so
    /// the growth starts from a tile-sized square around it.
    ///
    /// Control Center is found before taking focus, which may close it. The
    /// app is an accessory and not frontmost, and a menu opened from a
    /// background app can be dismissed by the next focus change, so it takes
    /// focus before opening.
    private func dropMenuDown() {
        DispatchQueue.main.async {
            let corner = controlCenterCorner()
            let pointer = NSEvent.mouseLocation
            NSApp.activate(ignoringOtherApps: true)
            guard let corner else {
                self.statusItem.button?.performClick(nil)
                return
            }
            let size = self.menu.size
            let end = NSRect(x: corner.x - size.width, y: corner.y - size.height,
                             width: size.width, height: size.height)
            let tile = self.tileSize
            let start = NSRect(x: pointer.x - tile / 2, y: pointer.y - tile / 2, width: tile, height: tile)
            zoomOpen(from: start, to: end, picture: self.menuPicture, glass: self.menuGlass) {
                // Where the shape ended, 5pt under the menu bar (see
                // controlCenterCorner), allowing for popUp's own offset.
                // Dark, with white text, as Control Center draws over its
                // glass; submenus take it from the menu.
                self.menuOpenedFromControl = true
                self.menu.appearance = controlCenterAppearance
                self.menu.popUp(positioning: nil, at: NSPoint(x: end.minX, y: end.maxY - self.popUpInset), in: nil)
            }
        }
    }

    /// tileSize is about a small Control Center tile, where the menu grows from.
    private let tileSize: CGFloat = 56

    /// openBatterySettings opens the Battery pane of System Settings. It only
    /// navigates; it reads and changes no power state, so it doesn't go
    /// through the CLI.
    @objc private func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// sectionHeader is a section heading as the system Battery menu draws it:
    /// semibold 12pt in a gray that is the label colour at 60% (measured from
    /// that menu). The menu's own title, "Battery", is the one bold black
    /// headline; section headings sit a level below it. It is a label in a
    /// custom view rather than a disabled menu item, because AppKit draws a
    /// disabled item dimmed whatever colour it is given.
    private func sectionHeader(_ text: String) -> NSMenuItem {
        let height: CGFloat = 24
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: height))
        view.autoresizingMask = [.width]
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = secondaryTextColor
        label.sizeToFit()
        label.frame.origin = NSPoint(x: menuLeftInset, y: (height - label.frame.height) / 2)
        view.addSubview(label)
        // As wide as its text needs, like the rows, so a heading doesn't
        // stretch a menu whose options are narrower than 200pt.
        view.setFrameSize(NSSize(width: label.frame.maxX + 18, height: height))
        let item = NSMenuItem()
        item.view = view
        return item
    }

    /// makeRow builds a row view and keeps it, so its hover can be reset.
    private func makeRow(_ title: String, glyph: EnergyGlyph? = nil, selectable: Bool,
                         accessory: MenuRowView.Accessory = .none, hasSubmenu: Bool = false) -> MenuRowView {
        let row = MenuRowView(title: title, glyph: glyph, selectable: selectable,
                              accessory: accessory, hasSubmenu: hasSubmenu)
        row.onEnter = { [weak self] entered in self?.putOutOthers(than: entered) }
        menuRows.append(row)
        return row
    }

    /// modeRow makes a row of the Energy Mode section. The view draws its own
    /// highlight (see MenuRowView); the item still carries the action.
    private func modeRow(_ title: String, glyph: EnergyGlyph, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.isEnabled = action != nil
        item.view = makeRow(title, glyph: glyph, selectable: action != nil)
        return item
    }

    // MARK: - Actions

    /// setHighPower starts a boost. The CLI has no indefinite High Power, so
    /// this is a timed one — `--detach` so the countdown outlives this click
    /// and the app isn't holding the process.
    @objc private func setHighPower() {
        perform(["boost", defaultBoost, "--detach"])
    }

    /// turnOff runs `mbat off`: stops any boost and watcher and gives the power
    /// mode back to macOS (Automatic), so mbatterier stops managing it.
    @objc private func turnOff() {
        perform(["off"])
    }

    /// setLowPower runs `mbat low`, which is Low Power on both sources — and
    /// also stops a running boost *and* the watcher, by design, since a
    /// watcher left running would undo it on its next tick.
    @objc private func setLowPower() {
        perform(["low"])
    }

    private func perform(_ args: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try StatusReader.run(args) }
            DispatchQueue.main.async {
                if case .failure(let error) = result {
                    self.actionError = error.localizedDescription
                } else {
                    self.actionError = nil
                }
                self.refresh()
            }
        }
    }

    /// toggleWatch starts or stops the watcher with its default thresholds,
    /// and remembers the choice for the next launch. Stopping it ends in Low
    /// Power, as every stop of the watcher does; a running boost keeps going.
    @objc private func toggleWatch() {
        let start = reading?.watch == nil
        UserDefaults.standard.set(start, forKey: Setting.watchMode.rawValue)
        perform(start ? ["watch", "--detach"] : ["watch", "stop"])
    }

    /// toggleAlwaysBoost starts High Power with no deadline and no unplug
    /// guard, or stops it. Stopping keeps the power mode as it is, and a
    /// running watcher keeps running and applies its own rules again.
    @objc private func toggleAlwaysBoost() {
        let on = reading?.boost?.always == true
        perform(on ? ["boost", "stop"] : ["boost", "always", "--detach"])
    }

    @objc private func toggleRemainingTime() { toggle(.remainingTime) }
    @objc private func toggleBoostTime() { toggle(.boostTime) }
    @objc private func toggleBoostSeconds() { toggle(.boostSeconds) }
    @objc private func toggleMonochrome() { toggle(.monochrome) }
    @objc private func toggleLowPowerBatteryColor() { toggle(.lowPowerBatteryColor) }
    @objc private func toggleHighPowerBatteryColor() { toggle(.highPowerBatteryColor) }

    @objc private func chooseIconColor(_ sender: NSMenuItem) {
        guard let parts = (sender.representedObject as? String)?.split(separator: ":"), parts.count == 2,
              let icon = BarIcon(rawValue: String(parts[0])),
              let color = IconColor(rawValue: String(parts[1])) else { return }
        UserDefaults.standard.set(color.rawValue, forKey: icon.key)
        syncSettingItems()
        render()
    }

    /// barColor is what icon is drawn in. Without monochrome every mark wears
    /// the mode's colour, as before; with it, the icon's own choice decides.
    /// modeColor is the colour the icon would have without monochrome.
    private func barColor(_ icon: BarIcon, modeColor: NSColor) -> NSColor {
        guard Setting.monochrome.isOn else { return modeColor }
        switch icon.color {
        case .monochrome: return barTint()
        case .mode: return modeColor
        }
    }
    @objc private func toggleWatchIcon() { toggle(.watchIcon) }
    @objc private func toggleAlwaysIcon() { toggle(.alwaysIcon) }
    @objc private func toggleHighPowerIcon() { toggle(.highPowerIcon) }
    @objc private func toggleLowPowerIcon() { toggle(.lowPowerIcon) }

    private func toggle(_ setting: Setting) {
        UserDefaults.standard.set(!setting.isOn, forKey: setting.rawValue)
        syncSettingItems()
        updateTickTimer()
        render()
    }

    private func syncSettingItems() {
        (remainingTimeItem.view as? MenuRowView)?.checked = Setting.remainingTime.isOn
        (boostTimeItem.view as? MenuRowView)?.checked = Setting.boostTime.isOn
        (boostSecondsItem.view as? MenuRowView)?.checked = Setting.boostSeconds.isOn
        (monochromeItem.view as? MenuRowView)?.checked = Setting.monochrome.isOn
        (lowPowerBatteryItem.view as? MenuRowView)?.checked = Setting.lowPowerBatteryColor.isOn
        lowPowerBatteryItem.isHidden = !Setting.monochrome.isOn
        (highPowerBatteryItem.view as? MenuRowView)?.checked = Setting.highPowerBatteryColor.isOn
        highPowerBatteryItem.isHidden = !Setting.monochrome.isOn
        for icon in BarIcon.allCases {
            let colored = Setting.monochrome.isOn && icon.shown.isOn
            if let separator = colorSeparators[icon] {
                // The icon's own row stays; only the colour choices wait.
                separator.isHidden = !Setting.monochrome.isOn
                for item in (colorChoices[icon] ?? [:]).values { item.isHidden = !Setting.monochrome.isOn }
            } else {
                iconColorItems[icon]?.isHidden = !colored
            }
            for (color, item) in colorChoices[icon] ?? [:] {
                (item.view as? MenuRowView)?.checked = icon.color == color
            }
        }
        (watchIconItem.view as? MenuRowView)?.checked = Setting.watchIcon.isOn
        (alwaysIconItem.view as? MenuRowView)?.checked = Setting.alwaysIcon.isOn
        (highPowerIconItem.view as? MenuRowView)?.checked = Setting.highPowerIcon.isOn
        (lowPowerIconItem.view as? MenuRowView)?.checked = Setting.lowPowerIcon.isOn
    }

    /// watchForChanges asks for a read whenever something the menu shows has
    /// probably changed, instead of waiting for the next poll. These are
    /// triggers only: what changed is still read from the CLI, as everything
    /// is.
    ///
    /// - The power source: macOS's own notification, for plugging in,
    ///   unplugging and the charge moving.
    /// - The power mode: pmset writes it under /Library/Preferences, the same
    ///   directory the CLI's pmset.Changes watches.
    /// - A boost or watcher starting or stopping, from Alfred or a terminal:
    ///   their state files live in /var/run.
    private func watchForChanges() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().refreshSoon()
        }, context)?.takeRetainedValue() {
            // Common modes, so it also fires while the menu is open.
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        for path in ["/Library/Preferences", "/var/run"] {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in self?.refreshSoon() }
            source.setCancelHandler { close(fd) }
            source.resume()
            changeSources.append(source)
        }
    }

    /// refreshSoon reads shortly after a trigger, so a burst of them (setting
    /// both sources is several writes) costs one read, taken once it settled.
    private func refreshSoon() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// appearanceChanged redraws once the switch has settled into the bar.
    @objc private func appearanceChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.render() }
    }

    @objc private func refreshNow() {
        refresh()
    }

    /// menu(_:willHighlight:) is told by AppKit which item is highlighted, or
    /// nil for none, and is the one place the highlight is decided: every row of
    /// that menu is lit or put out together, so two can never stay lit. It
    /// leaves the other menu alone, so the Settings row stays lit while its
    /// submenu is open.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for row in menuRows where row.enclosingMenuItem?.menu === menu {
            row.setLit(row.enclosingMenuItem === item)
        }
        if menu === self.menu && item !== headerItem {
            headerButtons.forEach { $0.reset() }
        }
    }

    /// putOutOthers backs the delegate up for when it is not called: entering
    /// a row puts out every other row in the same menu.
    private func putOutOthers(than entered: MenuRowView) {
        let menu = entered.enclosingMenuItem?.menu
        for row in menuRows where row !== entered && row.enclosingMenuItem?.menu === menu {
            row.reset()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        widenMenu()
        menuIsOpen = true
        refresh()
        refreshEnergy()
        // Only the Control Center look is pictured: it is what zoomOpen grows.
        if menu === self.menu && menuOpenedFromControl { pictureMenuSoon() }
        useControlCenterGlassForMenus(menuOpenedFromControl)
    }

    /// pictureMenuSoon takes the picture of the menu's rows that the control's
    /// tap grows (see zoomOpen), once the menu is up and the fresh reading in
    /// it. A timer in the tracking mode, since nothing else runs while a menu
    /// is open.
    private func pictureMenuSoon() {
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self, self.menuIsOpen else { return }
            self.menuPicture = pictureOfOpenMenu(size: self.menu.size) ?? self.menuPicture
            self.menuGlass = glassFilterOfOpenMenu(size: self.menu.size) ?? self.menuGlass
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        menuRows.forEach { $0.reset() }
        headerButtons.forEach { $0.reset() }
        widenMenu()
        // A submenu closing leaves the menu open, in the look it opened with.
        if menu === self.menu {
            menuOpenedFromControl = false
            self.menu.appearance = nil
        }
    }

    /// refresh reads the CLI off the main thread and applies the result on it.
    /// The exec is cheap, but it has no business on the run loop that draws
    /// the menu bar.
    private func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try StatusReader.read() }
            DispatchQueue.main.async {
                switch result {
                case .success(let status):
                    self.reading = status
                    self.readAt = Date()
                    self.failure = nil
                    self.startWatchOnLaunch(status)
                case .failure(let error):
                    self.reading = nil
                    self.failure = error.localizedDescription
                }
                self.updateTickTimer()
                self.render()
            }
        }
    }

    /// refreshEnergy reads the apps using significant energy, off the main
    /// thread like refresh. It runs when the menu opens, at most once a minute,
    /// and not on the timer: sampling takes 15 seconds of powermetrics, a poor
    /// thing for a battery tool to do every 15 s. The previous list shows until
    /// the new one lands.
    private func refreshEnergy() {
        guard !energyReading else { return }
        if let at = energyReadAt, Date().timeIntervalSince(at) < energyRefreshEvery { return }
        energyReading = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try StatusReader.readEnergy() }
            DispatchQueue.main.async {
                self.energyReading = false
                self.energyReadAt = Date()
                // A failed read, such as an older binary without `energy` or
                // a missing sudo rule, shows the "none" line rather than raise
                // an error for a list the menu can do without.
                self.setEnergy((try? result.get())?.apps.map(\.name) ?? [])
            }
        }
    }

    /// setEnergy shows the given app names under their heading. With none,
    /// the section stays and says so on one line, without the heading, which
    /// that line already repeats.
    private func setEnergy(_ names: [String]) {
        energyHeader.isHidden = names.isEmpty
        energyNoneItem.title = "No Apps Using Significant Energy"
        energyNoneItem.isHidden = !names.isEmpty
        for (i, row) in energyRows.enumerated() {
            row.isHidden = i >= names.count
            if i < names.count {
                row.representedObject = names[i]
                (row.view as? MenuRowView)?.title = names[i]
                (row.view as? MenuRowView)?.appIcon = appIcon(names[i])
            }
        }
    }

    /// appIcon is the icon of the app the energy list names, as macOS's list
    /// shows it. The CLI names an app by its bundle's folder name, so it is
    /// matched against the running apps' bundles; an app that has quit since
    /// (the list holds an app for two minutes) gets the generic app icon.
    private func appIcon(_ name: String) -> NSImage {
        runningApp(named: name)?.icon ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }

    /// runningApp is the running app the energy list names by its bundle's
    /// folder name.
    private func runningApp(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.deletingPathExtension().lastPathComponent == name
        }
    }

    /// showInActivityMonitor opens Activity Monitor with the clicked app's
    /// row selected, leaving its tab and sorting as they are (ActivityMonitor.swift).
    @objc private func showInActivityMonitor(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        ActivityMonitor.show(runningApp(named: name), named: name)
    }

    /// startWatchOnLaunch starts the watcher on the first good reading, unless
    /// one is already running (the LaunchDaemon's, say) or the user turned
    /// watching off.
    private func startWatchOnLaunch(_ status: Status) {
        guard !watchStartChecked else { return }
        watchStartChecked = true
        if Setting.watchMode.isOn && status.watch == nil {
            perform(["watch", "--detach"])
        }
    }

    // MARK: - The interpolated countdown

    /// boostSecondsLeft is the countdown as of now: what the CLI last reported,
    /// less the time since it said so.
    ///
    /// This is the one number the app works out for itself, and it is
    /// interpolation between authoritative readings rather than a rule of its
    /// own — every read overrides it, and reaching zero makes the app read
    /// again instead of concluding the boost is over. The alternative was
    /// exec'ing the CLI once a second for the whole length of a boost.
    private func boostSecondsLeft() -> Int? {
        guard let reported = reading?.boost?.remainingSeconds else { return nil }
        return max(0, reported - Int(Date().timeIntervalSince(readAt)))
    }

    /// updateTickTimer runs a fast timer only while there is a countdown
    /// to animate. A boost until unplugged has none, and neither has a plain
    /// battery reading.
    private func updateTickTimer() {
        let wanted = reading?.boost?.remainingSeconds != nil && Setting.boostTime.isOn
        if wanted && tickTimer == nil {
            // Polled several times a second and drawn only when the second
            // changes: a once-a-second timer drifts against the clock the
            // countdown is read from, so now and then it lands twice in one
            // second and skips the next. Common modes keep it running while
            // the menu is open.
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        } else if !wanted {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    private func tick() {
        guard let left = boostSecondsLeft() else { return }
        if left == lastTickSeconds { return }
        lastTickSeconds = left
        if left == 0 {
            // The boost has probably just ended. Ask, rather than decide.
            refresh()
            return
        }
        render()
    }

    // MARK: - Drawing

    private func render() {
        guard let button = statusItem.button else { return }
        // The text changed, so the natural width may have; only while closed,
        // since an open menu keeps the width it opened with.
        defer { if !menuIsOpen { widenMenu() } }
        // Every way the bar can change runs through here, settings included.
        defer { publishControl() }

        errorItem.isHidden = actionError == nil
        if let actionError {
            errorItem.title = actionError
        }

        guard let status = reading else {
            // Never a stale number and never a crash: say it is unknown and
            // put the reason where it can be read.
            let reason = failure ?? "No reading"
            button.title = ""
            button.image = composeBar([barTextPart("—", color: barTint()),
                                       BarPart(image: batteryIcon(percent: 0, mode: .automatic, label: barTint()),
                                               isText: false)])
            button.toolTip = reason
            // One line, so the reason's line breaks become dashes.
            sourceItem.title = "No reading: " + reason.replacingOccurrences(of: "\n", with: " — ")
            sourceItem.detail = ""
            limitItem.isHidden = true
            (highItem.view as? MenuRowView)?.counter = ""
            watchItem.isHidden = true
            holderSeparator.isHidden = true
            (automaticItem.view as? MenuRowView)?.badge = energyBadge(.automatic, active: false)
            (lowItem.view as? MenuRowView)?.badge = energyBadge(.low, active: false)
            (highItem.view as? MenuRowView)?.badge = energyBadge(.high, active: false)
            return
        }

        button.title = ""
        button.image = composeBar(barParts(for: status))
        button.toolTip = tooltip(for: status)

        // The charge sits on the source's line, a fixed gap after it.
        let watching = status.watch != nil
        watchButton.image = watchIcon(on: watching)
        watchButton.tip = watchTip(watching: watching, label: status.watch?.label)
        let alwaysOn = status.boost?.always == true
        alwaysButton.image = alwaysBoostIcon(on: alwaysOn)
        alwaysButton.tip = alwaysTip(on: alwaysOn)

        sourceItem.title = sourceWords(status)
        sourceItem.detail = chargeWords(status)
        let limit = limitWords(status)
        limitItem.title = limit ?? ""
        limitItem.isHidden = limit == nil
        setHolders(status)
        setModeRows(status)
    }

    /// publishControl hands the Control Center control the battery as the bar
    /// shows it, colour included, and has it redrawn. Only on a change: render
    /// runs on every tick of a countdown, which the control doesn't show.
    private func publishControl() {
        var snapshot = ControlSnapshot(percent: ControlSnapshot.unknown, onAC: false, tint: nil)
        if let status = reading {
            let mode = currentMode(status)
            snapshot.percent = status.percent
            snapshot.onAC = status.onAC
            switch mode {
            case .low: snapshot.mode = .low
            case .high: snapshot.mode = .high
            case .automatic: break
            }
            if !Setting.monochrome.isOn || batteryKeepsModeColor(mode) {
                switch mode {
                case .low: snapshot.tint = .low
                case .high: snapshot.tint = .high
                case .automatic: break
                }
            }
        }
        guard snapshot != controlSnapshot else { return }
        // Unwritable means unsigned or unentitled: the menu bar works without.
        guard (try? snapshot.write()) != nil else { return }
        controlSnapshot = snapshot
        if #available(macOS 26, *) {
            for kind in ControlSnapshot.kinds {
                ControlCenter.shared.reloadControls(ofKind: kind)
            }
        }
    }

    /// barParts lists the bar's elements in reading order: the eye while
    /// watching, the ∞ of an always-on boost or the stopwatch of any other
    /// boost with its countdown, the battery's time estimate, the High Power
    /// chevrons or the Low Power chevron, and the battery. Any of them but the battery can be absent;
    /// composeBar spaces whatever is left evenly.
    private func barParts(for status: Status) -> [BarPart] {
        var parts: [BarPart] = []
        let label = barTint()
        // Every element wears the colour of the power mode, like the battery:
        // purple in High Power, yellow in Low Power, the bar's own colour in
        // Automatic. Monochrome makes it the bar's colour, apart from the
        // marks given their mode colour back in Settings.
        let modeColor = barFillColor(currentMode(status), label: label, monochrome: Setting.monochrome.isOn)
        let ownModeColor = barFillColor(currentMode(status), label: label)
        func mark(_ image: NSImage) { parts.append(BarPart(image: image, isText: false)) }
        func text(_ string: String) { parts.append(barTextPart(string, color: modeColor)) }

        if status.watch != nil && Setting.watchIcon.isOn {
            mark(tinted(watchIcon(on: true, size: markSize), barColor(.watch, modeColor: ownModeColor)))
        }
        if let boost = status.boost, boost.always == true {
            // An always-on boost ignores the adapter and has no deadline, so
            // its mark is the ∞ of its header toggle, in place of the stopwatch.
            if Setting.alwaysIcon.isOn {
                mark(tinted(alwaysBoostIcon(on: true, size: alwaysSize), barColor(.always, modeColor: ownModeColor)))
            }
        } else if let boost = status.boost {
            mark(timerIcon(tint: modeColor, size: glyphSize))
            // With the setting off the glyph alone says a boost is running.
            if Setting.boostTime.isOn {
                if let left = boostSecondsLeft() {
                    text(barCountdownText(seconds: left, withSeconds: Setting.boostSeconds.isOn))
                } else if boost.untilUnplug == true {
                    text("∞")
                }
            }
        }
        // Only a real estimate is optional: the "—" for a Mac with no battery
        // stays, since the icon says nothing there.
        let estimate = Setting.remainingTime.isOn || status.percent < 0
            ? barText(percent: status.percent, remainingMinutes: status.remainingMinutes) : ""
        if !estimate.isEmpty {
            text(estimate)
        }
        if currentMode(status) == .high && Setting.highPowerIcon.isOn {
            mark(chevronIcon(color: barColor(.highPower, modeColor: barFillColor(.high, label: label))))
        }
        // Low Power's mark is a single chevron: High Power's, with less push.
        if currentMode(status) == .low && Setting.lowPowerIcon.isOn {
            mark(chevronIcon(count: 1, color: barColor(.lowPower, modeColor: barFillColor(.low, label: label))))
        }
        mark(batteryIcon(percent: status.percent, mode: currentMode(status), label: label,
                         onAC: status.onAC, charging: status.charging,
                         monochrome: Setting.monochrome.isOn
                             && !batteryKeepsModeColor(currentMode(status))))
        return parts
    }

    /// batteryKeepsModeColor is whether the battery icon wears the colour of
    /// mode although the bar is monochrome, as its Colors switch says.
    private func batteryKeepsModeColor(_ mode: PowerMode) -> Bool {
        switch mode {
        case .low: return Setting.lowPowerBatteryColor.isOn
        case .high: return Setting.highPowerBatteryColor.isOn
        case .automatic: return false
        }
    }

    /// currentMode is the power mode in force on the source actually in use.
    private func currentMode(_ status: Status) -> PowerMode {
        PowerMode(status.modes[status.onAC ? "ac" : "battery"])
    }

    /// barTint resolves the colour the bar is drawing text in right now. The
    /// glyphs carry real colour rather than being tinted by AppKit, so this
    /// is what stands in for "the default colour" in them.
    private func barTint() -> NSColor {
        var color = NSColor.labelColor
        let appearance = statusItem.button?.effectiveAppearance ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? NSColor.labelColor
        }
        return color
    }

    private func tooltip(for status: Status) -> String {
        var lines = [sourceWords(status), chargeWords(status)]
        if let limit = limitWords(status) {
            lines.append(limit)
        }
        lines.append(modeWords(status))
        if let boost = status.boost {
            lines.append(boostLine(boost))
        }
        if let watch = status.watch {
            lines.append("Watch: \(watch.label)")
        }
        return lines.joined(separator: "\n")
    }

    /// boostScope turns the CLI's label into words for the menu. The CLI's
    /// "battery + adapter" means the boost covers the mode for both sources,
    /// but in a menu it reads as being on both at once. Covering both is the
    /// usual case, so it says nothing; a one-source boost is named as such.
    private func boostScope(_ boost: Status.Holder) -> String? {
        switch boost.label {
        case "battery + adapter": return nil
        case "battery", "adapter": return "\(boost.label) only"
        default: return boost.label
        }
    }

    private func boostLine(_ boost: Status.Holder) -> String {
        var parts = boostScope(boost).map { [$0] } ?? []
        if let left = boostSecondsLeft() {
            parts.append("\(countdownText(seconds: left)) left")
        } else if boost.untilUnplug == true {
            parts.append("until unplugged")
        } else if boost.always == true {
            parts.append("until stopped")
        }
        return parts.isEmpty ? "Boost: on" : "Boost: " + parts.joined(separator: ", ")
    }

    /// setHolders shows a running watcher, hiding the whole section when none
    /// is running so the menu doesn't carry an empty gap.
    private func setHolders(_ status: Status) {
        if let watch = status.watch {
            watchItem.title = "Watch: \(watch.label)"
            watchItem.isHidden = false
        } else {
            watchItem.isHidden = true
        }
        holderSeparator.isHidden = watchItem.isHidden
    }

    /// setModeRows lights the badge of whichever mode is in force on the source
    /// in use. The badge is the indicator, so no row carries a checkmark.
    private func setModeRows(_ status: Status) {
        let mode = currentMode(status)
        for (item, glyph, rowMode) in [(automaticItem, EnergyGlyph.automatic, PowerMode.automatic),
                                       (lowItem, .low, .low),
                                       (highItem, .high, .high)] {
            (item?.view as? MenuRowView)?.badge = energyBadge(glyph, active: mode == rowMode)
        }
        // A timed boost is High Power, so its countdown sits behind that row:
        // "47m left", or "47m left - battery only" for a one-source boost;
        // with seconds, "46:12 left".
        if let boost = status.boost, let left = boostSecondsLeft() {
            let time = "\(barCountdownText(seconds: left, withSeconds: Setting.boostSeconds.isOn)) left"
            (highItem.view as? MenuRowView)?.counter =
                boostScope(boost).map { "\(time) - \($0)" } ?? time
        } else {
            (highItem.view as? MenuRowView)?.counter = ""
        }
    }
}
