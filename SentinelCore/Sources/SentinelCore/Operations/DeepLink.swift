import Foundation

/// Sections of the app that can be opened by URL (`hcgsentinel://open/<section>`).
///
/// Links are navigation only. There is deliberately no link that starts a scan,
/// sends a request, connects to anything or changes a setting, so a shortcut
/// surface such as Nexus can never trigger an operation by itself.
public enum SentinelSection: String, CaseIterable, Identifiable {
    case dashboard, network, networkCheck, bluetooth, radio, requests, capabilities, settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .network: return "Network Inspector"
        case .networkCheck: return "Check My Network"
        case .bluetooth: return "Bluetooth Explorer"
        case .radio: return "Radio Lab"
        case .requests: return "Request Composer"
        case .capabilities: return "Capabilities"
        case .settings: return "Settings"
        }
    }
}

public enum DeepLink {
    public static let scheme = "hcgsentinel"

    public static func section(from url: URL) -> SentinelSection? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "open",
              url.query == nil, url.fragment == nil, url.user == nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 1 else { return nil }
        let name = String(parts[0]).lowercased()
        return SentinelSection.allCases.first { $0.rawValue.lowercased() == name }
    }

    public static func url(for section: SentinelSection) -> URL {
        URL(string: "\(scheme)://open/\(section.rawValue)")!
    }
}

/// Read-only status summary intended for a future Nexus status surface.
/// See docs/NEXUS_INTEGRATION.md. It carries counts and labels only: no
/// identifiers, addresses, packet data or credentials.
public struct NexusStatusSnapshot: Codable, Equatable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var generatedAt: Date
    public var activeOperations: [String]
    public var verifiedCapabilities: Int
    public var totalCapabilities: Int
    public var previewMode: Bool

    public init(generatedAt: Date, activeOperations: [String], verifiedCapabilities: Int, totalCapabilities: Int, previewMode: Bool) {
        self.schemaVersion = NexusStatusSnapshot.schemaVersion
        self.generatedAt = generatedAt
        self.activeOperations = activeOperations
        self.verifiedCapabilities = verifiedCapabilities
        self.totalCapabilities = totalCapabilities
        self.previewMode = previewMode
    }
}
