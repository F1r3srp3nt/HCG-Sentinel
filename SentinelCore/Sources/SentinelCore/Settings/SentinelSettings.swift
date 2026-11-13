import Foundation

/// User-controlled settings. Every form of active collection and every outside connection defaults to off.
///
/// Three master switches:
/// * `scanningEnabled` — Bluetooth LE discovery and nearby Wi-Fi discovery requests.
/// * `remoteConnectionsEnabled` — the external analysis node, the privileged helper and test requests to your
///   endpoints.
/// * `animationsEnabled` — visual animation only.
public struct SentinelSettings: Codable, Equatable {
    public var animationsEnabled = true
    public var previewMode = false

    public var scanningEnabled = false
    public var bluetoothContinuousUpdates = false
    public var bluetoothAutoStopSeconds = 60

    public var captureRetention = RetentionPolicy.sevenDays

    public var remoteConnectionsEnabled = false
    public var radioNodeAddress = ""

    /// Allowed destinations for test requests. The first is the primary one that "/path" URLs use.
    public var testEndpoints: [String] = []
    public var requestTimeoutSeconds = 30

    public var helperPort = 47_655

    public var diagnosticLoggingEnabled = false

    public init() {}

    /// Keys used by earlier versions, read once to migrate stored settings.
    private enum LegacyKeys: String, CodingKey {
        case bluetoothScanningEnabled, radioNodeEnabled, helperEnabled, testEndpoint
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let d = SentinelSettings()
        animationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .animationsEnabled) ?? d.animationsEnabled
        previewMode = try c.decodeIfPresent(Bool.self, forKey: .previewMode) ?? d.previewMode
        scanningEnabled = try c.decodeIfPresent(Bool.self, forKey: .scanningEnabled)
            ?? legacy.decodeIfPresent(Bool.self, forKey: .bluetoothScanningEnabled) ?? d.scanningEnabled
        bluetoothContinuousUpdates = try c.decodeIfPresent(Bool.self, forKey: .bluetoothContinuousUpdates) ?? d.bluetoothContinuousUpdates
        bluetoothAutoStopSeconds = try c.decodeIfPresent(Int.self, forKey: .bluetoothAutoStopSeconds) ?? d.bluetoothAutoStopSeconds
        captureRetention = (try? c.decodeIfPresent(RetentionPolicy.self, forKey: .captureRetention)) ?? d.captureRetention
        if let value = try c.decodeIfPresent(Bool.self, forKey: .remoteConnectionsEnabled) {
            remoteConnectionsEnabled = value
        } else {
            let node = try legacy.decodeIfPresent(Bool.self, forKey: .radioNodeEnabled) ?? false
            let helper = try legacy.decodeIfPresent(Bool.self, forKey: .helperEnabled) ?? false
            remoteConnectionsEnabled = node || helper
        }
        radioNodeAddress = try c.decodeIfPresent(String.self, forKey: .radioNodeAddress) ?? d.radioNodeAddress
        if let list = try c.decodeIfPresent([String].self, forKey: .testEndpoints) {
            testEndpoints = list
        } else if let single = try legacy.decodeIfPresent(String.self, forKey: .testEndpoint) {
            testEndpoints = [single]
        }
        requestTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .requestTimeoutSeconds) ?? d.requestTimeoutSeconds
        helperPort = try c.decodeIfPresent(Int.self, forKey: .helperPort) ?? d.helperPort
        diagnosticLoggingEnabled = try c.decodeIfPresent(Bool.self, forKey: .diagnosticLoggingEnabled) ?? d.diagnosticLoggingEnabled
        normalize()
    }

    /// Clamps values to their allowed ranges.
    public mutating func normalize() {
        bluetoothAutoStopSeconds = [0, 30, 60, 120, 300].contains(bluetoothAutoStopSeconds) ? bluetoothAutoStopSeconds : 60
        requestTimeoutSeconds = min(max(requestTimeoutSeconds, 5), 120)
        helperPort = (1024...65_535).contains(helperPort) ? helperPort : 47_655
        radioNodeAddress = String(radioNodeAddress.prefix(256))
        var seen = Set<String>()
        testEndpoints = testEndpoints
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256)) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        testEndpoints = Array(testEndpoints.prefix(TestEndpoint.maxEndpoints))
    }
}

public protocol SettingsStore: AnyObject {
    func load() -> SentinelSettings
    func save(_ settings: SentinelSettings)
}

public final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "sentinel.settings.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> SentinelSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(SentinelSettings.self, from: data) else { return SentinelSettings() }
        return settings
    }

    public func save(_ settings: SentinelSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }
}

public final class InMemorySettingsStore: SettingsStore {
    private var value: SentinelSettings
    public init(_ value: SentinelSettings = SentinelSettings()) { self.value = value }
    public func load() -> SentinelSettings { value }
    public func save(_ settings: SentinelSettings) { value = settings }
}
