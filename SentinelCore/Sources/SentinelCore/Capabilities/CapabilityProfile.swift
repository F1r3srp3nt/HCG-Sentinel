import Foundation

/// One recorded outcome of a real operation: when, and what proved it.
public struct CapabilityEvidence: Codable, Equatable {
    public var at: Date
    public var text: String

    public init(at: Date, text: String) {
        self.at = at
        self.text = String(text.prefix(300))
    }
}

/// Keeps each capability's last success and last failure on this device, so the Capability Center can show "last
/// successful operation" across launches. It never makes a capability verified by itself: verification is per
/// session and comes only from a real operation. Evidence texts are short descriptions written by Sentinel (counts,
/// times, status codes), never addresses, identifiers, request contents or credentials.
public final class CapabilityEvidenceStore {
    public struct Entry: Codable, Equatable {
        public var lastSuccess: CapabilityEvidence?
        public var lastFailure: CapabilityEvidence?

        public init(lastSuccess: CapabilityEvidence?, lastFailure: CapabilityEvidence?) {
            self.lastSuccess = lastSuccess
            self.lastFailure = lastFailure
        }
    }

    private struct File: Codable {
        var schema: Int
        var entries: [String: Entry]
    }

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> [CapabilityID: Entry] {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data), file.schema == 1 else {
            return [:]
        }
        var result: [CapabilityID: Entry] = [:]
        for (key, entry) in file.entries {
            // Unknown keys (a later version's capabilities) are ignored, not fatal.
            if let id = CapabilityID(rawValue: key) { result[id] = entry }
        }
        return result
    }

    public func save(_ entries: [CapabilityID: Entry]) {
        let file = File(schema: 1, entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) }))
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// What a capability needs and where it lives, shown in the Capability Center.
public struct CapabilityProfile: Equatable {
    /// Where it can work, for example "iPhone and iPad, iOS 15+ (standard and Unleashed)".
    public var platforms: String
    /// Hardware it needs, or "None beyond the iPhone".
    public var hardware: String
    /// iOS permissions and Sentinel switches it needs.
    public var permissions: [String]
    /// The screen that does the work, if it has one.
    public var section: SentinelSection?
    /// A bounded, local self-test the Capability Center may run, if one exists.
    public var selfTest: CapabilitySelfTest?
    /// True when part of the feature exists and part depends on something not yet built (stated in the summary).
    public var partial: Bool

    public init(platforms: String, hardware: String, permissions: [String], section: SentinelSection?,
                selfTest: CapabilitySelfTest? = nil, partial: Bool = false) {
        self.platforms = platforms
        self.hardware = hardware
        self.permissions = permissions
        self.section = section
        self.selfTest = selfTest
        self.partial = partial
    }
}

/// Self-tests the Capability Center can run. Each performs one real, local, bounded operation; none contacts a
/// host the user did not choose, and each says exactly what it proved.
public enum CapabilitySelfTest: String, Equatable, CaseIterable {
    /// Reads this device's interface addresses and network path.
    case readConnection
    /// One ICMP Echo to 127.0.0.1 (this iPhone's own loopback). Proves ICMP sockets work here, nothing about networks.
    case loopbackPing
    /// Parses a synthetic capture generated on the device. Proves the parser, not any real traffic.
    case syntheticCapture
    /// Scans a synthetic file written to a temporary folder. Proves the scanner and its redaction.
    case syntheticSecretScan
    /// Runs the on-device security checks.
    case deviceSecurityChecks

    public var title: String {
        switch self {
        case .readConnection: return "Read this device's connection"
        case .loopbackPing: return "Ping this iPhone's own loopback address"
        case .syntheticCapture: return "Parse a synthetic capture"
        case .syntheticSecretScan: return "Scan a synthetic test file"
        case .deviceSecurityChecks: return "Run the device security checks"
        }
    }

    public var scope: String {
        switch self {
        case .readConnection: return "Reads what iOS reports about this app's connection. Nothing is sent."
        case .loopbackPing: return "Sends one ICMP Echo to 127.0.0.1 and waits up to 2 s. Nothing leaves the iPhone."
        case .syntheticCapture: return "Generates a small pcapng in memory and decodes it. Labelled synthetic; it shows the parser works, not that any traffic was seen."
        case .syntheticSecretScan: return "Writes one file with a fake key to a temporary folder, scans it and deletes it. The finding must come back redacted."
        case .deviceSecurityChecks: return "Read-only checks on this iPhone (passcode, biometrics, app package, environment). Nothing is changed."
        }
    }
}

/// The eight classes the owner asked every capability to be sorted into. Derived from the code's own facts
/// (implementation, environment, switch, verification), never set by hand.
public enum CapabilityClass: String, CaseIterable, Equatable {
    case verified = "Implemented and verified"
    case unverified = "Implemented, not yet verified"
    case disabled = "Implemented, turned off"
    case partial = "Partially implemented"
    case interfaceOnly = "Interface only"
    case externalHardware = "External hardware required"
    case unsupported = "Unsupported on this platform"
    case research = "Future research"
}

/// Capability Center filters.
public enum CapabilityFilter: String, CaseIterable, Identifiable {
    case all = "All", verified = "Verified", unverified = "Unverified", disabled = "Disabled", unavailable = "Unavailable", planned = "Planned"

    public var id: String { rawValue }

    public func matches(_ state: CapabilityState) -> Bool {
        switch self {
        case .all: return true
        case .verified: return state.classification == .verified
        case .unverified: return state.classification == .unverified || state.classification == .partial && state.readiness != .disabled
        case .disabled: return state.classification == .disabled
        case .unavailable: return [.unsupported, .externalHardware].contains(state.classification) || state.readiness == .failed
        case .planned: return [.interfaceOnly, .research].contains(state.classification)
        }
    }
}

public extension CapabilityState {
    var profile: CapabilityProfile { CapabilityCatalog.profile(for: id) }

    var classification: CapabilityClass {
        if descriptor.tier == .feasibility { return .research }
        switch descriptor.implementation {
        case .notIncluded: return .research
        case .interfaceOnly: return .interfaceOnly
        case .included: break
        }
        if case .unsupported = environment { return .unsupported }
        if case .verified = verification { return .verified }
        if !userEnabled { return .disabled }
        if profile.partial { return .partial }
        if descriptor.tier == .externalNode { return .externalHardware }
        return .unverified
    }
}
