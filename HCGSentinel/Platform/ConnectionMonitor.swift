import Foundation
import Network

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

    var headline: String {
        guard isOnline else { return statusText }
        return interfaceTypes.isEmpty ? "Online" : "Online via \(interfaceTypes.joined(separator: " + "))"
    }
}

/// Observes the app's own connectivity with `NWPathMonitor`. This is passive
/// status only: it sends no probes and sees no traffic.
final class ConnectionMonitor: ObservableObject {
    @Published private(set) var snapshot: ConnectionSnapshot?
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

    func refreshAddresses() {
        guard var current = snapshot else { return }
        current.addresses = ConnectionMonitor.interfaceAddresses()
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
        return ConnectionSnapshot(isOnline: path.status == .satisfied, statusText: status, interfaceTypes: types,
                                  isExpensive: path.isExpensive, isConstrained: path.isConstrained,
                                  supportsIPv4: path.supportsIPv4, supportsIPv6: path.supportsIPv6,
                                  supportsDNS: path.supportsDNS, addresses: interfaceAddresses(), updatedAt: Date())
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
