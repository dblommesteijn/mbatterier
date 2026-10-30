import Foundation

/// Status is the `mbat status --json` document.
///
/// It mirrors `statusDoc` in `src/cmd/mbatterier/main.go` — the two change
/// together. Nothing here is computed: this app reads no system API and no
/// power setting of its own, because the rules behind them live in the CLI and
/// are tested there. When the bar needs something new, the CLI grows a field.
/// (The app does listen for changes, in AppDelegate.watchForChanges, but only
/// as a prompt to ask the CLI again.)
struct Status: Decodable {
    /// percent is the battery charge, or `noBattery` on a Mac without one.
    var percent: Int
    var onAC: Bool
    var charging: Bool
    /// remainingMinutes is 0 when pmset gave no estimate, which is normal
    /// right after plugging in and on a full battery.
    var remainingMinutes: Int
    /// modes holds the power mode per source, keyed "battery" and "ac".
    var modes: [String: String]
    /// chargeLimit is the limit set in System Settings, 0 when there is none.
    var chargeLimit: Int
    /// slowCharger is macOS's own verdict on the adapter in use.
    var slowCharger: Bool
    /// chargeToFull is macOS's "Charge to Full Now": the charge is held short
    /// of full, and `mbatterier charge full` lets it through.
    var chargeToFull: Bool
    var boost: Holder?
    var watch: Holder?

    /// noBattery is the percent of a Mac that pmset reports no battery for.
    static let noBattery = -1

    /// Holder is a running boost or watcher. A watcher has no deadline; its
    /// label holds its thresholds.
    struct Holder: Decodable {
        var label: String
        var remainingSeconds: Int?
        var untilUnplug: Bool?
        /// always is a boost that runs until stopped.
        var always: Bool?

        enum CodingKeys: String, CodingKey {
            case label, always
            case remainingSeconds = "remaining_seconds"
            case untilUnplug = "until_unplug"
        }
    }

    enum CodingKeys: String, CodingKey {
        case percent, charging, modes, boost, watch
        case onAC = "on_ac"
        case remainingMinutes = "remaining_minutes"
        case chargeLimit = "charge_limit"
        case slowCharger = "slow_charger"
        case chargeToFull = "charge_to_full"
    }

    /// The CLI leaves both charging fields out when they are unset, so they
    /// default here instead of failing the decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        percent = try c.decode(Int.self, forKey: .percent)
        onAC = try c.decode(Bool.self, forKey: .onAC)
        charging = try c.decode(Bool.self, forKey: .charging)
        remainingMinutes = try c.decode(Int.self, forKey: .remainingMinutes)
        modes = try c.decode([String: String].self, forKey: .modes)
        chargeLimit = try c.decodeIfPresent(Int.self, forKey: .chargeLimit) ?? 0
        slowCharger = try c.decodeIfPresent(Bool.self, forKey: .slowCharger) ?? false
        chargeToFull = try c.decodeIfPresent(Bool.self, forKey: .chargeToFull) ?? false
        boost = try c.decodeIfPresent(Holder.self, forKey: .boost)
        watch = try c.decodeIfPresent(Holder.self, forKey: .watch)
    }
}

/// EnergyUse is the `mbat energy --json` document: the user's apps using
/// significant energy, highest first. It mirrors `energyDoc` in
/// `src/cmd/mbatterier/energy.go`; like Status, nothing in it is computed here.
struct EnergyUse: Decodable {
    var apps: [App]

    struct App: Decodable {
        var name: String
        var impact: Double
    }
}

/// StatusError is why a reading failed, phrased for the tooltip.
enum StatusError: LocalizedError {
    case notInstalled(String)
    case failed(Int32, String)
    case undecodable(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let path):
            return "\(path) is missing.\nRun: make install-system"
        case .failed(let code, let message):
            let detail = message.isEmpty ? "" : "\n\(message)"
            return "mbatterier status --json exited \(code)\(detail)"
        case .undecodable(let message):
            return "could not read mbatterier's output: \(message)"
        }
    }
}

/// StatusReader runs the CLI. That is the only way this app learns anything.
enum StatusReader {
    /// The binary is named by absolute path and never resolved through $PATH,
    /// the same root-safety rule the Go code follows. This is the root-owned
    /// copy that `make install-system` installs.
    static let binaryPath = "/usr/local/bin/mbatterier"

    /// run invokes the CLI with args and returns nothing but success. It is
    /// how every action the menu offers is performed: the app never touches
    /// `pmset` itself, so a click here goes through exactly the code path the
    /// terminal and Alfred use, locks and revert rules included.
    ///
    /// `boost` and `low` need root. The binary re-execs itself through
    /// `sudo -n` when it has no terminal, so this works only with the
    /// passwordless sudoers rule in place — the same requirement Alfred has.
    @discardableResult
    static func run(_ args: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw StatusError.notInstalled(binaryPath)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binaryPath)
        task.arguments = args
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        try task.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw StatusError.failed(task.terminationStatus, message)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// readEnergy asks the CLI for the apps using significant energy. The CLI
    /// re-runs itself through sudo for it, so it needs the same sudoers rule as
    /// a boost. Sampling takes 15 seconds, so this is never part of
    /// the 15 s refresh.
    static func readEnergy() throws -> EnergyUse {
        let out = try run(["energy", "--json"])
        do {
            return try JSONDecoder().decode(EnergyUse.self, from: Data(out.utf8))
        } catch {
            throw StatusError.undecodable(error.localizedDescription)
        }
    }

    static func read() throws -> Status {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw StatusError.notInstalled(binaryPath)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binaryPath)
        task.arguments = ["status", "--json"]
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        try task.run()
        // Drain both pipes before waiting, or a full pipe buffer would
        // deadlock against a process that cannot finish writing.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw StatusError.failed(task.terminationStatus, message)
        }
        do {
            return try JSONDecoder().decode(Status.self, from: data)
        } catch {
            throw StatusError.undecodable(error.localizedDescription)
        }
    }
}
