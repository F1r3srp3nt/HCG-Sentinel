import Foundation

// MARK: - IPv4 networks

/// An IPv4 address as a 32-bit number.
public struct IPv4: Equatable, Hashable, Comparable, CustomStringConvertible {
    public var value: UInt32

    public init(_ value: UInt32) { self.value = value }

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let octet = UInt32(part), octet <= 255,
                  !(part.count > 1 && part.first == "0") else { return nil }
            value = value << 8 | octet
        }
        self.value = value
    }

    public var description: String {
        "\(value >> 24).\(value >> 16 & 0xff).\(value >> 8 & 0xff).\(value & 0xff)"
    }

    public static func < (lhs: IPv4, rhs: IPv4) -> Bool { lhs.value < rhs.value }

    /// RFC 1918 private space, plus link-local (169.254/16). These are the only ranges Sentinel will sweep.
    public var isPrivateOrLinkLocal: Bool {
        value & 0xff00_0000 == 0x0a00_0000          // 10.0.0.0/8
            || value & 0xfff0_0000 == 0xac10_0000   // 172.16.0.0/12
            || value & 0xffff_0000 == 0xc0a8_0000   // 192.168.0.0/16
            || value & 0xffff_0000 == 0xa9fe_0000   // 169.254.0.0/16
    }

    public var isLoopback: Bool { value >> 24 == 127 }
}

/// An IPv4 network in CIDR form.
public struct IPv4Network: Equatable, Hashable, CustomStringConvertible {
    public let network: IPv4
    public let prefix: Int

    public init?(address: IPv4, prefix: Int) {
        guard (0...32).contains(prefix) else { return nil }
        self.prefix = prefix
        self.network = IPv4(address.value & IPv4Network.mask(prefix))
    }

    /// From an address and a dotted netmask, as getifaddrs reports them. Nil for a non-contiguous mask.
    public init?(address: IPv4, netmask: IPv4) {
        let ones = netmask.value.nonzeroBitCount
        guard IPv4Network.mask(ones) == netmask.value else { return nil }
        self.init(address: address, prefix: ones)
    }

    /// "192.168.1.0/24", or a single address "192.168.1.7" (as /32).
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let pieces = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let address = IPv4(String(pieces[0])) else { return nil }
        if pieces.count == 2 {
            guard let prefix = Int(pieces[1]), String(prefix) == pieces[1] else { return nil }
            self.init(address: address, prefix: prefix)
        } else {
            self.init(address: address, prefix: 32)
        }
    }

    static func mask(_ prefix: Int) -> UInt32 { prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix) }

    public var description: String { "\(network)/\(prefix)" }
    public var netmask: IPv4 { IPv4(IPv4Network.mask(prefix)) }
    public var addressCount: UInt64 { UInt64(1) << UInt64(32 - prefix) }
    public var broadcast: IPv4 { IPv4(network.value | ~IPv4Network.mask(prefix)) }

    public func contains(_ address: IPv4) -> Bool { address.value & IPv4Network.mask(prefix) == network.value }
    public func contains(_ other: IPv4Network) -> Bool { other.prefix >= prefix && contains(other.network) }

    /// Usable host addresses: the network and broadcast addresses are left out for prefixes up to /30.
    public var hosts: [IPv4] {
        guard prefix < 31 else { return (0..<addressCount).map { IPv4(network.value + UInt32($0)) } }
        return (1..<(addressCount - 1)).map { IPv4(network.value + UInt32($0)) }
    }
}

/// One IPv4 address assigned to this device, with its network.
public struct LocalInterfaceNetwork: Equatable {
    public var interface: String
    public var address: IPv4
    public var network: IPv4Network

    public init(interface: String, address: IPv4, network: IPv4Network) {
        self.interface = interface
        self.address = address
        self.network = network
    }
}

// MARK: - Scope

/// What the user asked to sweep, checked before a single packet is sent.
public struct DiscoveryScope: Equatable {
    /// At most a /24: 254 hosts.
    public static let maxHosts = 254
    public static let minimumPrefix = 24

    public let range: IPv4Network
    public let hosts: [IPv4]
    /// The device's own network that contains the range, if any.
    public let localNetwork: LocalInterfaceNetwork?
    public let excludesOwnAddress: IPv4?

    public enum Refusal: Error, Equatable {
        case invalid(String)
        case notPrivate(String)
        case tooLarge(String)
        case notConfirmed
        case outsideLocalNetworks(String)

        public var message: String {
            switch self {
            case .invalid(let text): return "\"\(text)\" is not an IPv4 address or range. Use a form like 192.168.1.0/24 or 192.168.1.20."
            case .notPrivate(let range): return "\(range) is not a private network address. Sentinel sweeps only private ranges (10.x, 172.16–31.x, 192.168.x, 169.254.x); it never sweeps public or internet ranges."
            case .tooLarge(let range): return "\(range) is larger than a /24. Sentinel sweeps at most 254 addresses at a time; choose a /24 or smaller."
            case .notConfirmed: return "Confirm that this network is yours, or that you are authorised to test it, before sweeping."
            case .outsideLocalNetworks(let range): return "\(range) is not part of any network this iPhone is connected to right now. Join that network first, or choose a range inside your current one."
            }
        }
    }

    /// Validates a range. It must be private, at most a /24, inside a network this device is on, and confirmed.
    public static func make(_ text: String, localNetworks: [LocalInterfaceNetwork], confirmedAuthorization: Bool) -> Result<DiscoveryScope, Refusal> {
        guard let range = IPv4Network(text) else { return .failure(.invalid(text.trimmingCharacters(in: .whitespaces))) }
        guard range.network.isPrivateOrLinkLocal, range.broadcast.isPrivateOrLinkLocal else { return .failure(.notPrivate(range.description)) }
        guard range.prefix >= minimumPrefix else { return .failure(.tooLarge(range.description)) }
        guard let local = localNetworks.first(where: { $0.network.contains(range) }) else {
            return .failure(.outsideLocalNetworks(range.description))
        }
        guard confirmedAuthorization else { return .failure(.notConfirmed) }
        let hosts = range.hosts.filter { $0 != local.address }
        return .success(DiscoveryScope(range: range, hosts: Array(hosts.prefix(maxHosts)), localNetwork: local,
                                       excludesOwnAddress: range.contains(local.address) ? local.address : nil))
    }

    /// The suggested range for a local network: the /24 around the device's address (or the network itself if smaller).
    public static func suggestedRange(for local: LocalInterfaceNetwork) -> IPv4Network? {
        guard local.address.isPrivateOrLinkLocal else { return nil }
        if local.network.prefix >= minimumPrefix { return local.network }
        return IPv4Network(address: local.address, prefix: minimumPrefix)
    }
}

// MARK: - Results

/// How an address answered. Each is a direct observation, never an inference.
public enum HostResponse: Equatable {
    case icmpEchoReply(milliseconds: Double)
    case tcpAccepted(port: Int, milliseconds: Double)
    case tcpRefused(port: Int, milliseconds: Double)

    public var milliseconds: Double {
        switch self {
        case .icmpEchoReply(let ms), .tcpAccepted(_, let ms), .tcpRefused(_, let ms): return ms
        }
    }

    public var methodText: String {
        switch self {
        case .icmpEchoReply: return "ICMP echo reply"
        case .tcpAccepted(let port, _): return "TCP \(port) accepted a connection"
        case .tcpRefused(let port, _): return "TCP \(port) refused (reset), so something answered"
        }
    }
}

public struct DiscoveredHost: Equatable, Identifiable {
    public enum Status: Equatable {
        /// The address answered at least one probe: verified.
        case responded(HostResponse)
        /// Nothing answered within the time limits. Not evidence that nothing is there: many devices ignore all
        /// unsolicited traffic.
        case noResponse
    }

    public var address: IPv4
    public var status: Status
    /// Reverse DNS (PTR) name, if the network's resolver has one. Reported by DNS, not verified with the device.
    public var reverseName: String?
    public var probedAt: Date
    public var id: UInt32 { address.value }

    public init(address: IPv4, status: Status, reverseName: String?, probedAt: Date) {
        self.address = address
        self.status = status
        self.reverseName = reverseName
        self.probedAt = probedAt
    }

    public var responded: Bool {
        if case .responded = status { return true }
        return false
    }
}

// MARK: - Sweep

/// Probes one address. The default uses real sockets; tests substitute their own.
public protocol HostProber: AnyObject {
    func echo(_ address: IPv4, timeout: TimeInterval) -> HostResponse?
    func connect(_ address: IPv4, port: Int, timeout: TimeInterval) -> HostResponse?
    func reverseName(_ address: IPv4) -> String?
}

public final class SocketHostProber: HostProber {
    public init() {}

    public func echo(_ address: IPv4, timeout: TimeInterval) -> HostResponse? {
        guard let target = ProbeAddress(numeric: address.description) else { return nil }
        let prober = SocketPingProber()
        defer { prober.finish() }
        guard (try? prober.prepare(method: .icmpEcho, address: target)) != nil else { return nil }
        if case .reply(let ms) = prober.probe(sequence: 1, timeout: timeout) { return .icmpEchoReply(milliseconds: ms) }
        return nil
    }

    public func connect(_ address: IPv4, port: Int, timeout: TimeInterval) -> HostResponse? {
        guard let target = ProbeAddress(numeric: address.description) else { return nil }
        switch ProbeSockets.tcpConnect(target, port: UInt16(port), timeout: timeout) {
        case .connected(let ms): return .tcpAccepted(port: port, milliseconds: ms)
        case .refused(let ms): return .tcpRefused(port: port, milliseconds: ms)
        case .timedOut, .failed: return nil
        }
    }

    public func reverseName(_ address: IPv4) -> String? {
        guard let target = ProbeAddress(numeric: address.description) else { return nil }
        return ProbeSockets.reverseName(target)
    }
}

/// A conservative sweep of a confirmed scope: per address one ICMP echo, then (only if that got no reply) one TCP
/// connection attempt to each of a few common ports, stopping at the first answer. At most `concurrency` addresses
/// are in flight; nothing is retried; nothing runs after cancel.
public final class LocalSweep {
    public static let ports = [80, 443, 22, 445]
    public static let maxConcurrency = 8

    public struct Limits: Equatable {
        public var echoTimeout: TimeInterval = 1
        public var connectTimeout: TimeInterval = 0.8
        public var concurrency = 4

        public init() {}
    }

    public enum Event: Equatable {
        case host(DiscoveredHost)
        case progress(done: Int, total: Int)
        case finished(cancelled: Bool)
    }

    public let scope: DiscoveryScope
    public let limits: Limits
    private let prober: HostProber
    private let callbackQueue: DispatchQueue
    private let lock = NSLock()
    private var cancelled = false
    private let now: () -> Date

    public init(scope: DiscoveryScope, limits: Limits = Limits(), prober: HostProber = SocketHostProber(),
                callbackQueue: DispatchQueue = .main, now: @escaping () -> Date = Date.init) {
        self.scope = scope
        var bounded = limits
        bounded.concurrency = min(max(limits.concurrency, 1), LocalSweep.maxConcurrency)
        self.limits = bounded
        self.prober = prober
        self.callbackQueue = callbackQueue
        self.now = now
    }

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    public func start(_ handler: @escaping (Event) -> Void) {
        let queue = OperationQueue()
        queue.name = "sentinel.local-sweep"
        queue.maxConcurrentOperationCount = limits.concurrency
        let total = scope.hosts.count
        var done = 0
        let counter = NSLock()
        for address in scope.hosts {
            queue.addOperation { [weak self] in
                guard let self = self, !self.isCancelled else { return }
                let host = self.probe(address)
                guard !self.isCancelled else { return }
                counter.lock(); done += 1; let finished = done; counter.unlock()
                self.callbackQueue.async {
                    handler(.host(host))
                    handler(.progress(done: finished, total: total))
                }
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            queue.waitUntilAllOperationsAreFinished()
            let wasCancelled = self?.isCancelled ?? true
            self?.callbackQueue.async { handler(.finished(cancelled: wasCancelled)) }
        }
    }

    func probe(_ address: IPv4) -> DiscoveredHost {
        var response = prober.echo(address, timeout: limits.echoTimeout)
        if response == nil {
            for port in LocalSweep.ports {
                if isCancelled { break }
                if let answer = prober.connect(address, port: port, timeout: limits.connectTimeout) {
                    response = answer
                    break
                }
            }
        }
        let name = response == nil || isCancelled ? nil : prober.reverseName(address)
        return DiscoveredHost(address: address, status: response.map { .responded($0) } ?? .noResponse,
                              reverseName: name, probedAt: now())
    }
}
