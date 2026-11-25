import Foundation
import Network
import SentinelCore

struct InterfaceAddress: Identifiable, Equatable {
    let interface: String
    let family: String
    let address: String
    var id: String { "\(interface)|\(address)" }

    /// Plain-language guess from the BSD interface name.
    var interfaceHint: String {
        if interface.hasPrefix("en") { return "Wi-Fi or wired" }
        if interface.hasPrefix("pdp_ip") { return "Cellular data" }
        if interface.hasPrefix("utun") || interface.hasPrefix("ipsec") { return "Tunnel (VPN or system service)" }
        if interface.hasPrefix("bridge") || interface.hasPrefix("ap") { return "Personal Hotspot" }
        if interface.hasPrefix("awdl") || interface.hasPrefix("llw") { return "Apple peer-to-peer link" }
        return "Other"
    }
}

/// What iOS reports about this app's own network path.
struct ConnectionSnapshot: Equatable {
    var isOnline: Bool
    var statusText: String
    var interfaceTypes: [String]
    var isExpensive: Bool
    var isConstrained: Bool
    var supportsIPv4: Bool
    var supportsIPv6: Bool
    var supportsDNS: Bool
    var addresses: [InterfaceAddress]
    var updatedAt: Date
    /// Default gateways iOS reports for this path (NWPath.gateways).
    var gateways: [String] = []
    /// BSD names of the interfaces the path uses, for example "en0" for Wi-Fi.
    var interfaceNames: [String] = []
    /// IPv4 networks assigned to this device's active interfaces, with their netmask.
    var ipv4Networks: [LocalInterfaceNetwork] = []

    var usesWiFi: Bool { interfaceTypes.contains("Wi-Fi") }

    var headline: String {
        guard isOnline else { return statusText }
        return interfaceTypes.isEmpty ? "Online" : "Online via \(interfaceTypes.joined(separator: " + "))"
    }
}

/// One observed change of the connection, kept for this session only.
struct ConnectionChange: Identifiable, Equatable {
    let id = UUID()
    let at: Date
    let text: String
}

/// Observes the app's own connectivity with `NWPathMonitor`. This is passive
/// status only: it sends no probes and sees no traffic.
final class ConnectionMonitor: ObservableObject {
    @Published private(set) var snapshot: ConnectionSnapshot?
    /// Changes seen since Sentinel started, newest first (at most 30).
    @Published private(set) var changes: [ConnectionChange] = []
    var onFirstUpdate: (() -> Void)?

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "sentinel.connection-monitor")
    private var reported = false

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = ConnectionMonitor.makeSnapshot(path)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.recordChange(from: self.snapshot, to: snapshot)
                self.snapshot = snapshot
                if !self.reported {
                    self.reported = true
                    self.onFirstUpdate?()
                }
            }
        }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    private func recordChange(from old: ConnectionSnapshot?, to new: ConnectionSnapshot) {
        var parts: [String] = []
        if old == nil {
            parts.append("First reading: \(new.headline)")
        } else if let old = old {
            if old.headline != new.headline { parts.append("\(old.headline) → \(new.headline)") }
            let oldV4 = old.ipv4Networks.map { "\($0.interface) \($0.address)" }, newV4 = new.ipv4Networks.map { "\($0.interface) \($0.address)" }
            if oldV4 != newV4 { parts.append("IPv4 addresses: \(newV4.isEmpty ? "none" : newV4.joined(separator: ", "))") }
            if old.gateways != new.gateways { parts.append("Gateway: \(new.gateways.isEmpty ? "none reported" : new.gateways.joined(separator: ", "))") }
            if old.supportsIPv6 != new.supportsIPv6 { parts.append("IPv6 \(new.supportsIPv6 ? "available" : "unavailable")") }
        }
        guard !parts.isEmpty else { return }
        changes.insert(ConnectionChange(at: new.updatedAt, text: parts.joined(separator: " · ")), at: 0)
        if changes.count > 30 { changes.removeLast(changes.count - 30) }
    }

    func refreshAddresses() {
        guard var current = snapshot else { return }
        current.addresses = ConnectionMonitor.interfaceAddresses()
        current.ipv4Networks = ConnectionMonitor.ipv4Networks()
        current.updatedAt = Date()
        snapshot = current
    }

    private static func makeSnapshot(_ path: NWPath) -> ConnectionSnapshot {
        var types: [String] = []
        if path.usesInterfaceType(.wifi) { types.append("Wi-Fi") }
        if path.usesInterfaceType(.cellular) { types.append("Cellular") }
        if path.usesInterfaceType(.wiredEthernet) { types.append("Wired") }
        if path.usesInterfaceType(.other) { types.append("Other") }
        let status: String
        switch path.status {
        case .satisfied: status = "Online"
        case .unsatisfied: status = "No network connection"
        case .requiresConnection: status = "Connection must be activated"
        @unknown default: status = "Unknown"
        }
        let gateways: [String] = path.gateways.map { endpoint in
            if case .hostPort(let host, _) = endpoint { return "\(host)" }
            return "\(endpoint)"
        }
        var snapshot = ConnectionSnapshot(isOnline: path.status == .satisfied, statusText: status, interfaceTypes: types,
                                          isExpensive: path.isExpensive, isConstrained: path.isConstrained,
                                          supportsIPv4: path.supportsIPv4, supportsIPv6: path.supportsIPv6,
                                          supportsDNS: path.supportsDNS, addresses: interfaceAddresses(), updatedAt: Date())
        snapshot.gateways = gateways
        snapshot.interfaceNames = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map { $0.name }
        snapshot.ipv4Networks = ipv4Networks()
        return snapshot
    }

    /// IPv4 address and netmask of each active, non-loopback interface (getifaddrs). No permission is needed.
    static func ipv4Networks() -> [LocalInterfaceNetwork] {
        var result: [LocalInterfaceNetwork] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, let mask = entry.pointee.ifa_netmask,
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  Int32(address.pointee.sa_family) == AF_INET else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4(UInt32(bigEndian: $0.pointee.sin_addr.s_addr)) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4(UInt32(bigEndian: $0.pointee.sin_addr.s_addr)) }
            guard let network = IPv4Network(address: ip, netmask: netmask) else { continue }
            let item = LocalInterfaceNetwork(interface: String(cString: entry.pointee.ifa_name), address: ip, network: network)
            if !result.contains(item) { result.append(item) }
        }
        return result.sorted { ($0.interface, $0.address) < ($1.interface, $1.address) }
    }

    /// Addresses assigned to this device's active, non-loopback interfaces.
    static func interfaceAddresses() -> [InterfaceAddress] {
        var result: [InterfaceAddress] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                                     nil, 0, NI_NUMERICHOST)
            guard status == 0 else { continue }
            var text = String(cString: host)
            if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
            let item = InterfaceAddress(interface: String(cString: entry.pointee.ifa_name),
                                        family: family == AF_INET ? "IPv4" : "IPv6", address: text)
            if !result.contains(item) { result.append(item) }
        }
        return result.sorted { ($0.interface, $0.family, $0.address) < ($1.interface, $1.family, $1.address) }
    }
}
