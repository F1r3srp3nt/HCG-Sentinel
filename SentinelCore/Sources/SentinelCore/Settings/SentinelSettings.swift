import Foundation

/// User-controlled settings. Every form of active collection defaults to off.
public struct SentinelSettings: Codable, Equatable {
    public var animationsEnabled = true
    public var previewMode = false

    public var bluetoothScanningEnabled = false
    public var bluetoothContinuousUpdates = false
    public var bluetoothAutoStopSeconds = 60

    public var captureRetention = RetentionPolicy.sevenDays

    public var radioNodeEnabled = false
    public var radioNodeAddress = ""

    public var testEndpoint = ""
    public var requestTimeoutSeconds = 30

    public var helperEnabled = false
    public var helperPort = 47_655

    public var diagnosticLoggingEnabled = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SentinelSettings()
        animationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .animationsEnabled) ?? d.animationsEnabled
        previewMode = try c.decodeIfPresent(Bool.self, forKey: .previewMode) ?? d.previewMode
        bluetoothScanningEnabled = try c.decodeIfPresent(Bool.self, forKey: .bluetoothScanningEnabled) ?? d.bluetoothScanningEnabled
        bluetoothContinuousUpdates = try c.decodeIfPresent(Bool.self, forKey: .bluetoothContinuousUpdates) ?? d.bluetoothContinuousUpdates
        bluetoothAutoStopSeconds = try c.decodeIfPresent(Int.self, forKey: .bluetoothAutoStopSeconds) ?? d.bluetoothAutoStopSeconds
        captureRetention = (try? c.decodeIfPresent(RetentionPolicy.self, forKey: .captureRetention)) ?? d.captureRetention
        radioNodeEnabled = try c.decodeIfPresent(Bool.self, forKey: .radioNodeEnabled) ?? d.radioNodeEnabled
        radioNodeAddress = try c.decodeIfPresent(String.self, forKey: .radioNodeAddress) ?? d.radioNodeAddress
        testEndpoint = try c.decodeIfPresent(String.self, forKey: .testEndpoint) ?? d.testEndpoint
        requestTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .requestTimeoutSeconds) ?? d.requestTimeoutSeconds
        helperEnabled = try c.decodeIfPresent(Bool.self, forKey: .helperEnabled) ?? d.helperEnabled
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
        testEndpoint = String(testEndpoint.prefix(256))
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
