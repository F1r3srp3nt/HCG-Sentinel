import Foundation

/// Every destination in Sentinel: the single navigation registry shared by the app's own navigation (tabs, sidebar,
/// Security Intelligence Center) and by links from HCG Nexus, HCG System Tester and other HCG apps
/// (`hcgsentinel://open/<section>`). Both go through the same `Router.open(_:)`, so a link reaches exactly the screen
/// a tap inside Sentinel reaches, with the same checks inside it.
///
/// Links are navigation only. There is deliberately no link that starts a scan, sends a request, connects to
/// anything or changes a setting, so a shortcut surface such as Nexus can never trigger an operation by itself.
/// Raw values are part of the link contract: existing ones must never change.
public enum SentinelSection: String, CaseIterable, Identifiable {
    // Destinations HCG Nexus and HCG System Tester already link to (contract since 0.1.0).
    case dashboard, network, networkCheck, securityLab, bluetooth, radio, requests, devices, capabilities, settings
    // Added in 0.1.0~beta3.
    case center, wifi, ping, localNetwork, deviceSecurity, captureInspector, secretScanner, exposureCheck, authLab
    case externalNodes, reports, ecosystem, serverHealth

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dashboard: return "Command Center"
        case .network: return "Network Intelligence"
        case .networkCheck: return "Check My Network"
        case .securityLab: return "Security Laboratory"
        case .bluetooth: return "Bluetooth Explorer"
        case .radio: return "Radio Lab"
        case .requests: return "Request Composer"
        case .devices: return "Connected Devices"
        case .capabilities: return "Capability Center"
        case .settings: return "Settings"
        case .center: return "Security Intelligence Center"
        case .wifi: return "Wi-Fi"
        case .ping: return "Ping"
        case .localNetwork: return "Local Network"
        case .deviceSecurity: return "Device Security"
        case .captureInspector: return "Capture Inspector"
        case .secretScanner: return "Secret Scanner"
        case .exposureCheck: return "Exposure Check"
        case .authLab: return "Authentication Defense Lab"
        case .externalNodes: return "External Nodes"
        case .reports: return "Security Reports"
        case .ecosystem: return "HCG Ecosystem"
        case .serverHealth: return "HCG Server Health"
        }
    }

    /// The Security Intelligence Center area a destination belongs to.
    public var area: SentinelArea {
        switch self {
        case .dashboard, .center: return .commandCenter
        case .network, .networkCheck, .wifi, .ping, .localNetwork, .requests: return .networkIntelligence
        case .bluetooth, .radio: return .wirelessIntelligence
        case .deviceSecurity: return .deviceSecurity
        case .securityLab, .exposureCheck, .authLab: return .securityLaboratory
        case .captureInspector: return .captureInspector
        case .secretScanner: return .secretScanner
        case .externalNodes, .devices, .serverHealth: return .externalNodes
        case .capabilities: return .capabilityCenter
        case .reports: return .securityReports
        case .ecosystem: return .ecosystem
        case .settings: return .settings
        }
    }
}

/// The twelve areas of the Security Intelligence Center, in display order.
public enum SentinelArea: String, CaseIterable, Identifiable {
    case commandCenter, networkIntelligence, wirelessIntelligence, deviceSecurity, securityLaboratory, captureInspector
    case secretScanner, externalNodes, capabilityCenter, securityReports, ecosystem, settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .commandCenter: return "Command Center"
        case .networkIntelligence: return "Network Intelligence"
        case .wirelessIntelligence: return "Wireless Intelligence"
        case .deviceSecurity: return "Device Security"
        case .securityLaboratory: return "Security Laboratory"
        case .captureInspector: return "Capture Inspector"
        case .secretScanner: return "Secret Scanner"
        case .externalNodes: return "External Nodes"
        case .capabilityCenter: return "Capability Center"
        case .securityReports: return "Security Reports"
        case .ecosystem: return "HCG Ecosystem"
        case .settings: return "Settings"
        }
    }

    /// Destinations in this area, in registry order (excluding the hub itself).
    public var sections: [SentinelSection] {
        SentinelSection.allCases.filter { $0.area == self && $0 != .center }
    }
}

/// Where a link may take the user. Both are review screens; neither runs anything.
public enum DeepLinkTarget: Equatable {
    case section(SentinelSection)
    /// Opens a stored Security Lab report. Sentinel shows it only if it exists on this device.
    case report(UUID)
}

public enum DeepLink {
    public static let scheme = "hcgsentinel"

    /// Accepts `hcgsentinel://open/<section>` and `hcgsentinel://report/<uuid>`. Anything else is rejected.
    public static func target(from url: URL) -> DeepLinkTarget? {
        if let section = section(from: url) { return .section(section) }
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "report",
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil, url.port == nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 1, let id = UUID(uuidString: String(parts[0])) else { return nil }
        return .report(id)
    }

    public static func url(forReport id: UUID) -> URL {
        URL(string: "\(scheme)://report/\(id.uuidString)")!
    }

    public static func section(from url: URL) -> SentinelSection? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "open",
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil, url.port == nil else { return nil }
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
    /// Additive in schema 1: references to recent Security Lab reports (status and counts only, no contents).
    public var recentAssessments: [SecurityReportReference]?

    public init(generatedAt: Date, activeOperations: [String], verifiedCapabilities: Int, totalCapabilities: Int, previewMode: Bool,
                recentAssessments: [SecurityReportReference]? = nil) {
        self.schemaVersion = NexusStatusSnapshot.schemaVersion
        self.generatedAt = generatedAt
        self.activeOperations = activeOperations
        self.verifiedCapabilities = verifiedCapabilities
        self.totalCapabilities = totalCapabilities
        self.previewMode = previewMode
        self.recentAssessments = recentAssessments
    }
}
