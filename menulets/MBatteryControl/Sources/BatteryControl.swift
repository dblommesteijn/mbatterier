import AppIntents
import SwiftUI
import WidgetKit

@main
struct MBatteryControlBundle: WidgetBundle {
    var body: some Widget {
        BatteryControl()
        CentredBatteryControl()
        LargeBatteryControl()
    }
}

/// BatteryControl is the battery in Control Center, after macOS's own: the
/// glyph alone in the small size, glyph and charge in the medium and large
/// ones (the system drops the title when there is no room for it). A tap
/// opens the MBatterier menu, as a tap on Apple's opens its battery details.
///
/// It shows what the menulet last read, from the App Group (see
/// ControlSnapshot); the menulet reloads it whenever that changes.
struct BatteryControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlSnapshot.kind, provider: Provider()) { snapshot in
            // Control Center ignores colour on a control's glyph and shows the
            // tint only while the button is pressed. A toggle that is on was
            // tried to show it at rest: it stayed grey and took no taps.
            ControlWidgetButton(action: OpenMenuIntent()) {
                Label(title(snapshot), image: symbol(snapshot))
            }
            .tint(tint(snapshot))
        }
        .displayName("Battery")
        .description("Battery charge and power mode from MBatterier. Opens its menu.")
    }

    struct Provider: ControlValueProvider {
        /// previewValue is what the Control Center gallery shows: the
        /// screenshot's 43% in Low Power, without the mode's chevron: the
        /// gallery would show it whatever the mode.
        var previewValue: ControlSnapshot {
            ControlSnapshot(percent: 43, onAC: false, tint: .low)
        }

        func currentValue() async throws -> ControlSnapshot {
            ControlSnapshot.read() ?? ControlSnapshot(percent: ControlSnapshot.unknown, onAC: false, tint: nil)
        }
    }
}

/// CentredBatteryControl is the battery for the medium size, laid out as
/// Apple's own: battery and charge side by side, 3pt apart, centred on the
/// tile. Nothing a control sends sets its layout, public or private: Control
/// Center centres a control's symbol in a box at a fixed spot and writes its
/// title at a fixed spot after it. So this one has no title. Battery and
/// charge are one symbol, with room on its left that moves the drawing to the
/// middle of a medium tile (tools/symbols.py). In the small size that room
/// pushes it out of the circle, which is what BatteryControl is for.
struct CentredBatteryControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        centredConfiguration(kind: ControlSnapshot.centredKind, family: "centred")
            .displayName("Battery (Centred)")
            .description("Battery and charge centred, for the medium size. Opens the MBatterier menu.")
            // Shown and added in its size (WidgetKitSPI.swiftinterface).
            .preferredControlSize(.medium)
    }
}

/// LargeBatteryControl is CentredBatteryControl for the large size, whose
/// box sits in the tile's top row: its drawing sits lower in the symbol, by
/// as much as the tile's middle is below that row.
struct LargeBatteryControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        centredConfiguration(kind: ControlSnapshot.largeKind, family: "large")
            .displayName("Battery (Centred, Large)")
            .description("Battery and charge centred, for the large size. Opens the MBatterier menu.")
            .preferredControlSize(.large)
    }
}

/// centredConfiguration is a centred control: no title, the symbols of
/// family as its glyph.
@MainActor
private func centredConfiguration(kind: String, family: String) -> some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: kind, provider: BatteryControl.Provider()) { snapshot in
        ControlWidgetButton(action: OpenMenuIntent()) {
            Image(centredSymbol(snapshot, family: family))
        }
        .tint(tint(snapshot))
    }
}

/// title is the charge as the system battery writes it, or a dash without a
/// reading: never a stale number.
private func title(_ snapshot: ControlSnapshot) -> String {
    snapshot.percent == ControlSnapshot.unknown ? "—" : "\(snapshot.percent)%"
}

/// symbol picks the nearest of the battery symbols tools/symbols.py draws
/// after the menu bar's battery, one per 5%: controls take symbols only, not
/// drawn images. On the adapter it has the bolt cut out of it, as the bar's
/// has, and in Low or High Power the bar's chevrons (marks). Without a
/// reading it is the empty one.
private func symbol(_ snapshot: ControlSnapshot) -> String {
    if snapshot.percent == ControlSnapshot.unknown { return "battery.mbat.0" }
    let step = (min(100, max(0, snapshot.percent)) + 2) / 5 * 5
    return "battery.mbat.\(step)" + marks(snapshot)
}

/// centredSymbol is a centred control's symbol from family: the battery with
/// the charge drawn beside it, one per percent, or with a dash without a
/// reading.
private func centredSymbol(_ snapshot: ControlSnapshot, family: String) -> String {
    if snapshot.percent == ControlSnapshot.unknown { return "battery.mbat.\(family).none" }
    let percent = min(100, max(0, snapshot.percent))
    return "battery.mbat.\(family).\(percent)" + marks(snapshot)
}

/// marks is the symbol name's suffix for what is drawn on the battery: the
/// bolt on the adapter, then one chevron in Low Power or three in High Power,
/// standing in for the mode colour Control Center won't show.
private func marks(_ snapshot: ControlSnapshot) -> String {
    var suffix = snapshot.onAC ? ".bolt" : ""
    switch snapshot.mode {
    case .low: suffix += ".low"
    case .high: suffix += ".high"
    case nil: break
    }
    return suffix
}

/// tint is the mode colour, the same yellow and purple as the menu bar's
/// battery (barFillColor in the menulet).
private func tint(_ snapshot: ControlSnapshot) -> Color? {
    switch snapshot.tint {
    case .low: return .yellow
    case .high: return .purple
    case nil: return nil
    }
}

/// OpenMenuIntent is the control's tap. The extension can't reach the
/// menulet's status item, so it writes a request into the App Group that the
/// menulet answers by dropping its menu down.
struct OpenMenuIntent: AppIntent {
    static let title: LocalizedStringResource = "Open MBatterier"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        try ControlSnapshot.requestMenu()
        return .result()
    }
}
