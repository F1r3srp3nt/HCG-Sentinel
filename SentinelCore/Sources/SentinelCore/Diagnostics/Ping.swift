import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Packets

/// ICMP Echo Request / Echo Reply packets (RFC 792, RFC 4443).
public enum ICMPEcho {
    public static let headerSize = 8
    /// 8-byte random session token followed by an 8-byte send time; replies are matched on sequence and token.
    public static let payloadSize = 16

    public static func requestType(for family: ProbeAddress.Family) -> UInt8 { family == .ipv4 ? 8 : 128 }
    public static func replyType(for family: ProbeAddress.Family) -> UInt8 { family == .ipv4 ? 0 : 129 }

    public static func request(family: ProbeAddress.Family, identifier: UInt16, sequence: UInt16, token: [UInt8]) -> [UInt8] {
        precondition(token.count == 8)
        var packet: [UInt8] = [requestType(for: family), 0, 0, 0,
                               UInt8(identifier >> 8), UInt8(identifier & 0xff),
                               UInt8(sequence >> 8), UInt8(sequence & 0xff)]
        packet += token
        packet += [UInt8](repeating: 0, count: 8)
        if family == .ipv4 {
            // For ICMPv6 the kernel computes the checksum over the pseudo-header itself.
            let sum = checksum(packet)
            packet[2] = UInt8(sum >> 8)
            packet[3] = UInt8(sum & 0xff)
        }
        return packet
    }

    /// Internet checksum (RFC 1071).
    public static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum & 0xffff)
    }

    /// The sequence number of an Echo Reply that belongs to this session, or nil for anything else. Accepts the
    /// packet with or without a leading IPv4 header (Darwin includes it on ICMP datagram sockets; Linux does not).
    public static func matchReply(_ data: [UInt8], family: ProbeAddress.Family, token: [UInt8]) -> UInt16? {
        var icmp = data[...]
        if family == .ipv4, let first = data.first, first >> 4 == 4 {
            let headerLength = Int(first & 0x0f) * 4
            guard headerLength >= 20, data.count >= headerLength + headerSize else { return nil }
            icmp = data[headerLength...]
        }
        guard icmp.count >= headerSize + payloadSize else { return nil }
        let start = icmp.startIndex
        guard icmp[start] == replyType(for: family), icmp[start + 1] == 0 else { return nil }
        guard Array(icmp[(start + headerSize)..<(start + headerSize + 8)]) == token else { return nil }
        return UInt16(icmp[start + 6]) << 8 | UInt16(icmp[start + 7])
    }
}

// MARK: - Configuration and results

/// Limits are fixed: no flood mode, no unbounded runs, no sub-second intervals.
public struct PingConfiguration: Equatable {
    public static let countRange = 1...100
    public static let intervalRange: ClosedRange<TimeInterval> = 1...10
    public static let timeoutRange: ClosedRange<TimeInterval> = 1...10
    public static let portRange = 1...65_535

    public enum Method: Equatable {
        /// ICMP Echo (a real ping).
        case icmpEcho
        /// A TCP connection attempt to one port. Not a ping: it measures connection setup, and a firewall can treat it
        /// differently from ICMP.
        case tcpConnect(port: Int)

        public var title: String {
            switch self {
            case .icmpEcho: return "ICMP Echo (ping)"
            case .tcpConnect(let port): return "TCP connect test, port \(port) (not ICMP)"
            }
        }
    }

    public var count: Int
    public var interval: TimeInterval
    public var timeout: TimeInterval
    public var method: Method

    public init(count: Int = 10, interval: TimeInterval = 1, timeout: TimeInterval = 2, method: Method = .icmpEcho) {
        self.count = min(max(count, PingConfiguration.countRange.lowerBound), PingConfiguration.countRange.upperBound)
        self.interval = min(max(interval, PingConfiguration.intervalRange.lowerBound), PingConfiguration.intervalRange.upperBound)
        self.timeout = min(max(timeout, PingConfiguration.timeoutRange.lowerBound), PingConfiguration.timeoutRange.upperBound)
        if case .tcpConnect(let port) = method {
            self.method = .tcpConnect(port: min(max(port, PingConfiguration.portRange.lowerBound), PingConfiguration.portRange.upperBound))
        } else {
            self.method = method
        }
    }
}

public enum PingProbeOutcome: Equatable {
    case reply(milliseconds: Double)
    /// TCP only: the port actively refused. The host answered, so this counts as a response with a time.
    case refused(milliseconds: Double)
    case timeout
    case error(String)

    public var milliseconds: Double? {
        switch self {
        case .reply(let ms), .refused(let ms): return ms
        case .timeout, .error: return nil
        }
    }
}

public struct PingProbeResult: Equatable, Identifiable {
    public var sequence: Int
    public var outcome: PingProbeOutcome
    public var at: Date
    public var id: Int { sequence }

    public init(sequence: Int, outcome: PingProbeOutcome, at: Date) {
        self.sequence = sequence
        self.outcome = outcome
        self.at = at
    }
}

public struct PingStatistics: Equatable {
    public var sent = 0
    public var received = 0
    public var minimum: Double?
    public var maximum: Double?
    public var average: Double?

    public var lost: Int { sent - received }
    /// 0...100, nil before anything was sent.
    public var lossPercent: Double? { sent == 0 ? nil : Double(lost) / Double(sent) * 100 }

    public init() {}

    public init(results: [PingProbeResult]) {
        sent = results.count
        let times = results.compactMap { $0.outcome.milliseconds }
        received = times.count
        minimum = times.min()
        maximum = times.max()
        average = times.isEmpty ? nil : times.reduce(0, +) / Double(times.count)
    }
}

/// Validates what the user typed as a ping target. Returns the host or a plain reason.
public enum PingTargetInput {
    public static func validate(_ raw: String) -> Result<String, ResolveFailure> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .failure(.invalidInput("Enter an IP address or a host name.")) }
        if text.contains("://") || text.contains("/") {
            return .failure(.invalidInput("Enter only the host, for example 192.168.1.1 or example.com, without http:// or a path."))
        }
        if text.count > 253 || text.contains(where: { $0.isWhitespace }) {
            return .failure(.invalidInput("\"\(text.prefix(40))\" is not a valid host name or address."))
        }
        var host = text
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return .success(host)
    }
}

// MARK: - Probing

public enum PingStartFailure: Error, Equatable {
    case resolve(ResolveFailure)
    /// The ICMP socket could not be opened (for example, the system does not allow unprivileged ICMP).
    case icmpUnavailable(String)

    public var message: String {
        switch self {
        case .resolve(let failure): return failure.message
        case .icmpUnavailable(let reason):
            return "ICMP Echo is not available to Sentinel here: \(reason). Use the TCP connect test instead; it is labelled as such and is not a ping."
        }
    }
}

/// Sends the probes. The default implementation uses real sockets; tests substitute their own.
public protocol PingProber: AnyObject {
    func resolve(_ host: String) throws -> [ProbeAddress]
    /// Opens whatever the method needs. Called once per run, before the first probe.
    func prepare(method: PingConfiguration.Method, address: ProbeAddress) throws
    func probe(sequence: UInt16, timeout: TimeInterval) -> PingProbeOutcome
    func finish()
}

/// Real probes: ICMP Echo over an unprivileged ICMP datagram socket (no root, no helper), or one TCP connection.
public final class SocketPingProber: PingProber {
    private var fd: Int32 = -1
    private var address: ProbeAddress?
    private var method: PingConfiguration.Method = .icmpEcho
    private let token: [UInt8] = (0..<8).map { _ in UInt8.random(in: 0...255) }
    private let identifier = UInt16.random(in: 1...UInt16.max)

    public init() {}

    deinit { finish() }

    public func resolve(_ host: String) throws -> [ProbeAddress] {
        try ProbeSockets.resolve(host)
    }

    public func prepare(method: PingConfiguration.Method, address: ProbeAddress) throws {
        finish()
        self.method = method
        self.address = address
        guard method == .icmpEcho else { return }
        let socketFD = address.family == .ipv4
            ? socket(AF_INET, ProbeSockets.dgram, ProbeSockets.icmpProtocol)
            : socket(AF_INET6, ProbeSockets.dgram, ProbeSockets.icmp6Protocol)
        guard socketFD >= 0 else { throw PingStartFailure.icmpUnavailable(ProbeSockets.errorText(errno)) }
        fd = socketFD
    }

    public func probe(sequence: UInt16, timeout: TimeInterval) -> PingProbeOutcome {
        guard let address = address else { return .error("not prepared") }
        if case .tcpConnect(let port) = method {
            switch ProbeSockets.tcpConnect(address, port: UInt16(port), timeout: timeout) {
            case .connected(let ms): return .reply(milliseconds: ms)
            case .refused(let ms): return .refused(milliseconds: ms)
            case .timedOut: return .timeout
            case .failed(let reason): return .error(reason)
            }
        }
        guard fd >= 0 else { return .error("ICMP socket is closed") }
        let packet = ICMPEcho.request(family: address.family, identifier: identifier, sequence: sequence, token: token)
        let start = DispatchTime.now()
        let sent = packet.withUnsafeBytes { body in
            address.sockaddrBytes.withUnsafeBytes { target in
                sendto(fd, body.baseAddress, body.count, 0, target.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(target.count))
            }
        }
        guard sent == packet.count else { return .error(ProbeSockets.errorText(errno)) }
        let deadline = start.uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return .timeout }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(max(1, (deadline - now) / 1_000_000)))
            if ready == 0 { return .timeout }
            if ready < 0 {
                if errno == EINTR { continue }
                return .error(ProbeSockets.errorText(errno))
            }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else {
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                return .error(ProbeSockets.errorText(errno))
            }
            // Replies to other probes (late, or another session) are skipped until this one's deadline.
            if ICMPEcho.matchReply(Array(buffer[0..<count]), family: address.family, token: token) == sequence {
                return .reply(milliseconds: ProbeSockets.elapsedMilliseconds(since: start))
            }
        }
    }

    public func finish() {
        if fd >= 0 { _ = close(fd) }
        fd = -1
    }
}

/// One user-started run: resolve, then send `count` probes `interval` seconds apart, one at a time. Cancellable at any
/// point; events are delivered on `callbackQueue`.
public final class PingSession {
    public enum Event: Equatable {
        case resolved([ProbeAddress], using: ProbeAddress)
        case probe(PingProbeResult)
        case failed(PingStartFailure)
        /// The run ended: all probes sent, or cancelled.
        case finished(cancelled: Bool)
    }

    public let host: String
    public let configuration: PingConfiguration
    private let prober: PingProber
    private let callbackQueue: DispatchQueue
    private let workQueue = DispatchQueue(label: "sentinel.ping")
    private let lock = NSLock()
    private var cancelled = false
    private let wake = DispatchSemaphore(value: 0)
    private let now: () -> Date

    public init(host: String, configuration: PingConfiguration, prober: PingProber = SocketPingProber(),
                callbackQueue: DispatchQueue = .main, now: @escaping () -> Date = Date.init) {
        self.host = host
        self.configuration = configuration
        self.prober = prober
        self.callbackQueue = callbackQueue
        self.now = now
    }

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func cancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        lock.unlock()
        if first { wake.signal() }
    }

    public func start(_ handler: @escaping (Event) -> Void) {
        workQueue.async { [self] in
            func emit(_ event: Event) { callbackQueue.async { handler(event) } }
            defer { prober.finish() }
            let addresses: [ProbeAddress]
            do {
                addresses = try prober.resolve(host)
            } catch let failure as ResolveFailure {
                emit(.failed(.resolve(failure)))
                emit(.finished(cancelled: isCancelled))
                return
            } catch {
                emit(.failed(.resolve(.failed("\(error)"))))
                emit(.finished(cancelled: isCancelled))
                return
            }
            let target = addresses[0]
            emit(.resolved(addresses, using: target))
            do {
                try prober.prepare(method: configuration.method, address: target)
            } catch let failure as PingStartFailure {
                emit(.failed(failure))
                emit(.finished(cancelled: isCancelled))
                return
            } catch {
                emit(.failed(.icmpUnavailable("\(error)")))
                emit(.finished(cancelled: isCancelled))
                return
            }
            for index in 0..<configuration.count {
                if isCancelled { break }
                let started = DispatchTime.now()
                let outcome = prober.probe(sequence: UInt16(truncatingIfNeeded: index + 1), timeout: configuration.timeout)
                if isCancelled { break }
                emit(.probe(PingProbeResult(sequence: index + 1, outcome: outcome, at: now())))
                if index == configuration.count - 1 { break }
                // Wait out the rest of the interval, waking early if cancelled.
                let spent = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
                let rest = configuration.interval - spent
                if rest > 0, wake.wait(timeout: .now() + rest) == .success { break }
            }
            emit(.finished(cancelled: isCancelled))
        }
    }
}
