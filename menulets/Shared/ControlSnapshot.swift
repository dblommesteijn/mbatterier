import Foundation

/// ControlSnapshot is what the Control Center control shows: the menulet's
/// last reading, cut down to the battery and the colour it is drawn in.
///
/// The control runs sandboxed in its own extension and cannot exec the CLI,
/// so the menulet writes this into the App Group container after every read
/// and the control only ever reads it back. Nothing here is computed from the
/// system: the CLI stays the source of truth, one hop further away.
///
/// Compiled into both the menulet and the extension.
struct ControlSnapshot: Codable, Equatable, Sendable {
    /// percent is the charge, or `unknown` when the menulet has no reading.
    var percent: Int
    var onAC: Bool
    /// tint is the mode colour the battery wears, nil for none. The menulet
    /// decides it, monochrome settings included, so the control needs no
    /// settings of its own.
    var tint: Tint?
    /// mode is the power mode itself, for the chevrons drawn on the battery:
    /// Control Center draws a control's symbol in its own colour, so the
    /// marks show the mode where the tint can't. Not subject to the
    /// monochrome settings, since it has no colour. nil for Automatic, and
    /// in a snapshot written before it existed.
    var mode: Tint? = nil

    enum Tint: String, Codable, Sendable {
        case low, high
    }

    static let unknown = -1

    /// kinds are the controls' kinds, which the menulet reloads by: the
    /// battery for every size, and the ones centred on a medium and a large
    /// tile.
    static let kind = "it.blommesteijn.mbatterier.battery"
    static let centredKind = "it.blommesteijn.mbatterier.battery.centred"
    static let largeKind = "it.blommesteijn.mbatterier.battery.large"
    static let kinds = [kind, centredKind, largeKind]

    /// fileName is the snapshot's name inside the group container.
    private static let fileName = "control.json"
    /// requestFileName is the file a tap on the control writes to, for the
    /// menulet to drop its menu down. A file in the group because it is the
    /// one channel the sandbox is sure to let through: a Darwin notification
    /// posted from the extension never arrived.
    private static let requestFileName = "open-menu"

    /// groupID is the App Group both bundles are entitled to. The Makefile
    /// writes it into each Info.plist under this key, from the same TEAM it
    /// signs the entitlements with, so the two can't drift apart.
    static var groupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "MBatterierAppGroup") as? String
    }

    private static var url: URL? { fileURL(fileName) }

    /// menuRequestURL is the file the menulet watches for taps.
    static var menuRequestURL: URL? { fileURL(requestFileName) }

    private static func fileURL(_ name: String) -> URL? {
        guard let groupID else { return nil }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(name)
    }

    /// requestMenu asks the menulet to drop its menu down. It rewrites the
    /// file in place, not atomically, so the menulet's watch on it keeps
    /// pointing at the same file.
    static func requestMenu() throws {
        guard let url = menuRequestURL else { throw CocoaError(.fileNoSuchFile) }
        try Data("\(Date().timeIntervalSince1970)".utf8).write(to: url)
    }

    /// read returns the last snapshot, nil when there is none yet or it can't
    /// be read.
    static func read() -> ControlSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ControlSnapshot.self, from: data)
    }

    /// write replaces the snapshot atomically, so the control never reads a
    /// half-written file.
    func write() throws {
        guard let url = Self.url else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
