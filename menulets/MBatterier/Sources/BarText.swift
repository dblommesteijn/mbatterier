import Foundation

/// barText renders the menu bar title: just the time estimate, "2:41".
///
/// The percentage is deliberately not here. The icon's fill already carries
/// the level, and a number repeating it made the item wide for no new
/// information. Nor does the source or the charging state appear in words —
/// that is the icon's job too, so the bar stays short.
///
/// The result is empty whenever pmset has no estimate, which is the normal
/// case on the adapter: the item is then its icons alone. A Mac with no
/// battery is the one case that still needs a mark, since its icon says
/// nothing.
func barText(percent: Int, remainingMinutes: Int) -> String {
    guard percent >= 0 else { return "—" }
    guard remainingMinutes > 0 else { return "" }
    return hoursMinutes(remainingMinutes)
}


/// countdownMinutesText is the bar's form of a boost countdown: whole minutes
/// only, rounded up, so a boost never reads "0m" while it still has seconds
/// left. An hour and a half is "90m" — minutes only, no hours. The menu keeps
/// the full MM:SS form from `countdownText`.
func countdownMinutesText(seconds: Int) -> String {
    "\((max(0, seconds) + 59) / 60)m"
}

/// barCountdownText is the bar's boost countdown: the CLI's own MM:SS form
/// with seconds, whole minutes without.
func barCountdownText(seconds: Int, withSeconds: Bool) -> String {
    withSeconds ? countdownText(seconds: seconds) : countdownMinutesText(seconds: seconds)
}

/// hoursMinutes renders minutes as h:mm — zero-padded minute, unpadded hour.
/// This is the battery estimate, which is only ever accurate to the minute.
func hoursMinutes(_ minutes: Int) -> String {
    String(format: "%d:%02d", minutes / 60, minutes % 60)
}

/// countdownText renders a boost's remaining seconds the way the CLI's own
/// `formatRemaining` does: MM:SS, or H:MM:SS from an hour up. The two are
/// deliberately the same, so the bar and the terminal never disagree about
/// how much of a boost is left.
func countdownText(seconds: Int) -> String {
    let left = max(0, seconds)
    let h = left / 3600
    let m = (left % 3600) / 60
    let s = left % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
}

/// stateWords spells the same reading out for the menu, where there is room
/// for it and where the icon isn't there to carry the source.
func stateWords(_ status: Status) -> String {
    guard status.percent >= 0 else { return "No battery" }
    var parts = ["\(status.percent)%"]
    switch (status.onAC, status.charging) {
    case (true, true):
        parts.append("charging")
        if status.remainingMinutes > 0 {
            parts.append("\(hoursMinutes(status.remainingMinutes)) to full")
        }
    case (true, false):
        // The resting state with a charge limit in place: plugged in, holding.
        parts.append("on the adapter, not charging")
    case (false, _):
        parts.append("on battery")
        if status.remainingMinutes > 0 {
            parts.append("\(hoursMinutes(status.remainingMinutes)) left")
        }
    }
    return parts.joined(separator: ", ")
}

/// sourceWords names the power source the way macOS's own Battery menu does,
/// which names a slow charger in place of the adapter.
func sourceWords(_ status: Status) -> String {
    guard status.onAC else { return "Power Source: Battery" }
    return "Power Source: " + (status.slowCharger ? "Slow Charger" : "Power Adapter")
}

/// chargeWords is the charge and what it is doing, written to follow the power
/// source on the same line: "78% - 2:41 remaining". The source is already
/// named in front of it, so it only says what the source doesn't.
func chargeWords(_ status: Status) -> String {
    guard status.percent >= 0 else { return "No battery" }
    let pct = "\(status.percent)%"
    switch (status.onAC, status.charging, status.remainingMinutes) {
    case (true, true, let m) where m > 0:
        return "\(pct) - \(hoursMinutes(m)) to full"
    case (true, true, _):
        return "\(pct) - charging"
    case (true, false, _):
        // What macOS calls "Charged to 80% Limit": plugged in and holding.
        return "\(pct) - not charging"
    case (false, _, let m) where m > 0:
        return "\(pct) - \(hoursMinutes(m)) remaining"
    default:
        return pct
    }
}

/// limitWords is the charge-limit line: "Will Stop Charging at 80%" on the way
/// up, macOS's "Charged to 80% Limit" once it holds there. Like the system menu
/// it says nothing on battery, where the limit doesn't apply.
func limitWords(_ status: Status) -> String? {
    guard status.chargeLimit > 0, status.onAC, status.percent >= 0 else { return nil }
    if status.charging || status.percent < status.chargeLimit {
        return "Will Stop Charging at \(status.chargeLimit)%"
    }
    return "Charged to \(status.chargeLimit)% Limit"
}

/// modeWords names the power mode per source, as `mbat status` prints it.
func modeWords(_ status: Status) -> String {
    let battery = status.modes["battery"] ?? "n/a"
    let ac = status.modes["ac"] ?? "n/a"
    if battery == ac {
        return "Power mode: \(battery)"
    }
    return "Power mode: \(battery) on battery, \(ac) on the adapter"
}
