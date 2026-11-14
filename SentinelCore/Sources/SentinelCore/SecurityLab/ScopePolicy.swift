import Foundation

/// What kind of destination an IP address is.
public enum AddressClass: String, Equatable {
    case loopback
    case privateNetwork
    case linkLocal
    case cloudMetadata
    case multicast
    case unspecified
    case reserved
    case publicInternet

    /// Never reachable through Security Lab, whatever the user enters.
    public var alwaysBlocked: Bool {
        switch self {
        case .linkLocal, .cloudMetadata, .multicast, .unspecified, .reserved: return true
        case .loopback, .privateNetwork, .publicInternet: return false
        }
    }

    public var isLocal: Bool { self == .loopback || self == .privateNetwork }

    public var label: String {
        switch self {
        case .loopback: return "loopback"
        case .privateNetwork: return "private network"
        case .linkLocal: return "link-local"
        case .cloudMetadata: return "cloud metadata service"
        case .multicast: return "multicast"
        case .unspecified: return "unspecified address"
        case .reserved: return "reserved range"
        case .publicInternet: return "public internet"
        }
    }
}

public enum AddressClassifier {
    /// Addresses of cloud instance-metadata services. Blocked even when a link-local rule would not apply.
    public static let metadataAddresses: Set<String> = [
        "169.254.169.254", "169.254.170.2", "169.254.170.23", "100.100.100.200", "192.0.0.192",
        "fd00:ec2::254", "fd00:ec2::23"
    ]

    /// Host names of cloud metadata services.
    public static let metadataHostNames: Set<String> = [
        "metadata", "metadata.google.internal", "metadata.goog", "instance-data", "instance-data.ec2.internal",
        "metadata.azure.com", "metadata.tencentyun.com", "metadata.platformequinix.com"
    ]

    public static func isMetadataHost(_ host: String) -> Bool {
        let lower = normalizedHost(host)
        if metadataHostNames.contains(lower) { return true }
        if let v4 = parseIPv4(lower) { return metadataAddresses.contains(v4.map { String($0) }.joined(separator: ".")) }
        if let v6 = parseIPv6(lower) { return metadataAddresses.contains(where: { parseIPv6($0) == v6 }) }
        return false
    }

    public static func normalizedHost(_ host: String) -> String {
        var lower = host.lowercased()
        if lower.hasPrefix("[") && lower.hasSuffix("]") { lower = String(lower.dropFirst().dropLast()) }
        while lower.hasSuffix(".") { lower.removeLast() }
        return lower
    }

    /// Nil when `address` is not an IP literal.
    public static func classify(_ address: String) -> AddressClass? {
        let host = normalizedHost(address)
        if let v4 = parseIPv4(host) { return classify(v4: v4) }
        if let v6 = parseIPv6(host) { return classify(v6: v6, text: host) }
        return nil
    }

    static func classify(v4 b: [UInt8]) -> AddressClass {
        let text = b.map { String($0) }.joined(separator: ".")
        if metadataAddresses.contains(text) { return .cloudMetadata }
        switch (b[0], b[1]) {
        case (0, _): return .unspecified
        case (127, _): return .loopback
        case (10, _): return .privateNetwork
        case (172, 16...31): return .privateNetwork
        case (192, 168): return .privateNetwork
        case (100, 64...127): return .privateNetwork // carrier-grade NAT, treated as local
        case (169, 254): return .linkLocal
        case (224...239, _): return .multicast
        case (240...255, _): return .reserved
        case (192, 0) where b[2] == 0: return .reserved
        case (198, 18...19): return .reserved
        default: return .publicInternet
        }
    }

    static func classify(v6 b: [UInt8], text: String) -> AddressClass {
        if metadataAddresses.contains(where: { parseIPv6($0) == b }) { return .cloudMetadata }
        if b.allSatisfy({ $0 == 0 }) { return .unspecified }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return .loopback }
        // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible forms take the IPv4 classification.
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return classify(v4: Array(b[12..<16])) }
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return .linkLocal }
        if (b[0] & 0xfe) == 0xfc { return .privateNetwork }
        if b[0] == 0xff { return .multicast }
        // NAT64 well-known prefix 64:ff9b::/96 embeds an IPv4 address.
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b && b[4..<12].allSatisfy({ $0 == 0 }) {
            return classify(v4: Array(b[12..<16]))
        }
        return .publicInternet
    }

    /// Strict dotted-quad parser. Rejects octal, hex and shortened forms, which some resolvers would accept.
    public static func parseIPv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  !(part.count > 1 && part.hasPrefix("0")), let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    public static func parseIPv6(_ text: String) -> [UInt8]? {
        var body = text
        if let percent = body.firstIndex(of: "%") { body = String(body[..<percent]) } // zone index
        guard body.contains(":"), body.count <= 45 else { return nil }
        var tail: [UInt8] = []
        if let lastColon = body.lastIndex(of: ":"), body[body.index(after: lastColon)...].contains(".") {
            guard let v4 = parseIPv4(String(body[body.index(after: lastColon)...])) else { return nil }
            tail = v4
            body = String(body[...lastColon]) + "0:0"
        }
        let halves = body.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ part: String) -> [UInt16]? {
            if part.isEmpty { return [] }
            var result: [UInt16] = []
            for group in part.split(separator: ":", omittingEmptySubsequences: false) {
                guard !group.isEmpty, group.count <= 4, let value = UInt16(group, radix: 16) else { return nil }
                result.append(value)
            }
            return result
        }
        guard let head = groups(halves[0]) else { return nil }
        var all: [UInt16]
        if halves.count == 2 {
            guard let rest = groups(halves[1]), head.count + rest.count < 8 else { return nil }
            all = head + Array(repeating: 0, count: 8 - head.count - rest.count) + rest
        } else {
            guard head.count == 8 else { return nil }
            all = head
        }
        var bytes: [UInt8] = []
        for group in all { bytes.append(UInt8(group >> 8)); bytes.append(UInt8(group & 0xff)) }
        if !tail.isEmpty { bytes.replaceSubrange(12..<16, with: tail) }
        return bytes
    }
}

/// One explicitly entered target.
public struct ScopedTarget: Codable, Equatable, Identifiable {
    public var url: URL
    public var host: String
    public var port: Int
    /// The user explicitly selected this as a local-network target, allowing loopback and private addresses.
    public var localNetwork: Bool

    public var id: String { url.absoluteString }
    public var isHTTPS: Bool { url.scheme?.lowercased() == "https" }
}

public enum ScopeError: Error, Equatable, CustomStringConvertible {
    case invalidURL(String)
    case unsupportedScheme(String)
    case credentialsInURL
    case cloudMetadata(String)
    case tooManyTargets(Int)
    case notInScope(String)
    case blockedAddress(host: String, address: String, kind: AddressClass)
    case localNotSelected(host: String, address: String)
    case noAddresses(String)
    case connectedElsewhere(host: String, address: String)

    public var description: String {
        switch self {
        case .invalidURL(let text): return "“\(text)” is not a valid http or https URL."
        case .unsupportedScheme(let scheme): return "Only http and https are supported, not \(scheme)."
        case .credentialsInURL: return "Remove the user name and password from the URL. Exposure Check never sends credentials."
        case .cloudMetadata(let host): return "\(host) is a cloud metadata service. Security Lab never contacts metadata endpoints."
        case .tooManyTargets(let max): return "Enter at most \(max) targets."
        case .notInScope(let host): return "\(host) is not one of the targets you entered, so it was not contacted."
        case .blockedAddress(let host, let address, let kind):
            return "\(host) resolved to \(address) (\(kind.label)). That kind of address is never contacted."
        case .localNotSelected(let host, let address):
            return "\(host) resolved to the local address \(address), but you did not mark it as a local-network target. Nothing was sent."
        case .noAddresses(let host): return "\(host) did not resolve to any address."
        case .connectedElsewhere(let host, let address):
            return "The connection to \(host) reached \(address), which the scope does not allow. Its response was discarded."
        }
    }
}

/// The set of targets an assessment may contact. Built only from what the user typed; discovered hosts
/// (redirect targets, links, certificate names) are never added.
public struct TargetScope: Equatable {
    public static let maxTargets = 5
    public let targets: [ScopedTarget]

    /// Parses user-entered URLs. A target is local-network when the user flagged it, or when its host is
    /// literally a loopback/private IP or a `.local` name, which the user cannot have meant otherwise.
    public static func parse(_ entries: [(text: String, localNetwork: Bool)]) throws -> TargetScope {
        let cleaned = entries.map { (text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), localNetwork: $0.localNetwork) }
            .filter { !$0.text.isEmpty }
        guard cleaned.count <= maxTargets else { throw ScopeError.tooManyTargets(maxTargets) }
        var targets: [ScopedTarget] = []
        for entry in cleaned {
            let target = try parseTarget(entry.text, localNetwork: entry.localNetwork)
            if !targets.contains(where: { $0.url == target.url }) { targets.append(target) }
        }
        return TargetScope(targets: targets)
    }

    public static func parseTarget(_ text: String, localNetwork: Bool) throws -> ScopedTarget {
        guard let components = URLComponents(string: text), let rawScheme = components.scheme else {
            throw ScopeError.invalidURL(Redactor.standard.url(text))
        }
        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else { throw ScopeError.unsupportedScheme(scheme) }
        guard components.user == nil, components.password == nil else { throw ScopeError.credentialsInURL }
        guard let rawHost = components.host, !rawHost.isEmpty else { throw ScopeError.invalidURL(Redactor.standard.url(text)) }
        let host = AddressClassifier.normalizedHost(rawHost)
        if AddressClassifier.isMetadataHost(host) { throw ScopeError.cloudMetadata(host) }
        if let kind = AddressClassifier.classify(host), kind.alwaysBlocked {
            throw ScopeError.blockedAddress(host: host, address: host, kind: kind)
        }
        let literalLocal = AddressClassifier.classify(host)?.isLocal == true || host.hasSuffix(".local") || host == "localhost"
        var normalized = components
        normalized.scheme = scheme
        normalized.fragment = nil
        if normalized.path.isEmpty { normalized.path = "/" }
        guard let url = normalized.url else { throw ScopeError.invalidURL(Redactor.standard.url(text)) }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        return ScopedTarget(url: url, host: host, port: port, localNetwork: localNetwork || literalLocal)
    }

    public init(targets: [ScopedTarget]) {
        self.targets = targets
    }

    /// The in-scope target a URL belongs to: same host, and either the entered port or the standard
    /// port of the other scheme (so http→https on the same host can be followed). Nil when out of scope.
    public func target(for url: URL) -> ScopedTarget? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil, let rawHost = url.host else { return nil }
        let host = AddressClassifier.normalizedHost(rawHost)
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return targets.first { $0.host == host && ($0.port == port || port == 80 || port == 443) }
    }

    /// Validates every address a host resolved to. All must be allowed: a mixed answer could be used to
    /// steer the connection to the blocked one.
    public func validate(resolved addresses: [String], for target: ScopedTarget) throws {
        guard !addresses.isEmpty else { throw ScopeError.noAddresses(target.host) }
        for address in addresses {
            guard let kind = AddressClassifier.classify(address) else { continue }
            try validate(address: address, kind: kind, for: target)
        }
    }

    /// Validates the address a connection actually reached, when the platform reports it.
    public func validate(connectedAddress address: String, for target: ScopedTarget) throws {
        guard let kind = AddressClassifier.classify(address) else { return }
        do {
            try validate(address: address, kind: kind, for: target)
        } catch {
            throw ScopeError.connectedElsewhere(host: target.host, address: address)
        }
    }

    private func validate(address: String, kind: AddressClass, for target: ScopedTarget) throws {
        if kind.alwaysBlocked { throw ScopeError.blockedAddress(host: target.host, address: address, kind: kind) }
        if kind.isLocal && !target.localNetwork { throw ScopeError.localNotSelected(host: target.host, address: address) }
    }
}
