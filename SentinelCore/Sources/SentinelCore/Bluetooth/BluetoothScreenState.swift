import Foundation

/// What Bluetooth Explorer's status card shows. Each situation the user can be in has its own kind, title and next
/// step, so "permission denied", "Bluetooth off", "scanning" and "nothing found" never look alike.
public struct BluetoothScreenStatus: Equatable {
    public enum Kind: String, Equatable, CaseIterable {
        /// Sentinel's Scanning switch is off. The user can turn it on from this screen.
        case scanningSwitchOff
        case permissionDenied
        case restricted
        case bluetoothOff
        case unsupported
        case resetting
        /// Started; iOS has not reported that Bluetooth is ready (it may be showing the permission prompt).
        case starting
        /// Scanning, and nothing has been heard yet in this scan.
        case scanningNothingYet
        /// Scanning for a while with nothing heard: likely nothing nearby is advertising.
        case scanningNoResults
        case scanningWithResults
        /// Not scanning. Earlier results, if any, are still listed.
        case stopped
    }

    public enum Action: Equatable {
        case start
        case stop
        case turnOnScanningAndStart
        case openSystemSettings
        case none
    }

    public var kind: Kind
    public var title: String
    public var detail: String
    public var primaryAction: Action
    /// SF Symbol name; every one exists on iOS 14.
    public var symbol: String
    public var isActive: Bool { kind == .starting || kind == .scanningNothingYet || kind == .scanningNoResults || kind == .scanningWithResults }
    public var isProblem: Bool {
        [.permissionDenied, .restricted, .bluetoothOff, .unsupported, .resetting].contains(kind)
    }

    /// After this many seconds of scanning with nothing heard, the card says so plainly.
    public static let quietAfter: TimeInterval = 15

    public static func derive(state: BluetoothScanState, scanningEnabled: Bool, heardThisScan: Int, listed: Int,
                              now: Date) -> BluetoothScreenStatus {
        switch state {
        case .blocked(.disabledInSettings):
            return switchOff
        case .blocked(.permissionDenied):
            return BluetoothScreenStatus(kind: .permissionDenied, title: "Bluetooth permission denied",
                                         detail: "Sentinel is not allowed to use Bluetooth, so it cannot hear any device. Allow it in iOS Settings › Sentinel › Bluetooth, then come back and start the scan.",
                                         primaryAction: .openSystemSettings, symbol: "lock.fill")
        case .blocked(.restricted):
            return BluetoothScreenStatus(kind: .restricted, title: "Bluetooth is restricted",
                                         detail: "Screen Time or a device-management profile blocks Bluetooth for apps on this iPhone. Sentinel cannot change that.",
                                         primaryAction: .none, symbol: "nosign")
        case .blocked(.poweredOff):
            return BluetoothScreenStatus(kind: .bluetoothOff, title: "Bluetooth is off",
                                         detail: "Turn Bluetooth on in Control Centre or iOS Settings, then start the scan again. Sentinel never switches it on for you.",
                                         primaryAction: .start, symbol: "power")
        case .blocked(.unsupported):
            return BluetoothScreenStatus(kind: .unsupported, title: "Bluetooth LE is not available",
                                         detail: "This device has no Bluetooth LE radio that apps can use. The iOS Simulator never has one; use a physical iPhone.",
                                         primaryAction: .none, symbol: "exclamationmark.triangle.fill")
        case .blocked(.resetting):
            return BluetoothScreenStatus(kind: .resetting, title: "Bluetooth is restarting",
                                         detail: "The system Bluetooth service is restarting. Try again in a moment.",
                                         primaryAction: .start, symbol: "arrow.clockwise")
        case .waitingForRadio:
            return BluetoothScreenStatus(kind: .starting, title: "Starting…",
                                         detail: "Waiting for iOS to report that Bluetooth is ready. If iOS asks for Bluetooth permission, choose Allow.",
                                         primaryAction: .stop, symbol: "hourglass")
        case .scanning(let since):
            if heardThisScan > 0 {
                return BluetoothScreenStatus(kind: .scanningWithResults, title: "Scanning · \(heardThisScan) device\(heardThisScan == 1 ? "" : "s") heard",
                                             detail: "Listening for Bluetooth LE advertisements. Devices appear below as they are heard.",
                                             primaryAction: .stop, symbol: "dot.radiowaves.left.and.right")
            }
            if now.timeIntervalSince(since) >= quietAfter {
                return BluetoothScreenStatus(kind: .scanningNoResults, title: "Scanning · nothing heard yet",
                                             detail: "No advertisement in \(Int(now.timeIntervalSince(since))) s. Nothing nearby may be advertising; many devices only advertise when they are pairing, charging or in use.",
                                             primaryAction: .stop, symbol: "magnifyingglass")
            }
            return BluetoothScreenStatus(kind: .scanningNothingYet, title: "Scanning…",
                                         detail: "Listening for Bluetooth LE advertisements. Many devices advertise only every few seconds.",
                                         primaryAction: .stop, symbol: "dot.radiowaves.left.and.right")
        case .idle:
            if !scanningEnabled { return switchOff }
            return BluetoothScreenStatus(kind: .stopped, title: listed > 0 ? "Stopped · \(listed) device\(listed == 1 ? "" : "s") listed" : "Not scanning",
                                         detail: listed > 0 ? "Results from earlier scans stay listed until you clear them. Start again to see what is advertising now."
                                                            : "Start a scan to list Bluetooth LE devices advertising nearby. It stops by itself at the time limit.",
                                         primaryAction: .start, symbol: "stop.circle")
        }
    }

    private static let switchOff = BluetoothScreenStatus(
        kind: .scanningSwitchOff, title: "Scanning is off",
        detail: "Sentinel only scans after you allow it. Turning scanning on here does the same as the Scanning switch in Settings, and starts one scan.",
        primaryAction: .turnOnScanningAndStart, symbol: "pause.circle")
}

/// One received signal-strength reading.
public struct RSSIReading: Equatable {
    public var dBm: Int
    public var at: Date

    public init(dBm: Int, at: Date) {
        self.dBm = dBm
        self.at = at
    }
}
