import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One resolved address of a host, ready to probe.
public struct ProbeAddress: Equatable, Hashable {
    public enum Family: String, Equatable { case ipv4 = "IPv4", ipv6 = "IPv6" }

    public var family: Family
    /// Numeric text form, for example "192.168.1.1" or "fe80::1".
    public var text: String
    /// The raw sockaddr bytes (sockaddr_in or sockaddr_in6), port 0.
    let sockaddrBytes: [UInt8]

    public init?(numeric text: String) {
        guard let resolved = try? ProbeSockets.resolve(text, numericOnly: true).first else { return nil }
        self = resolved
    }

    init(family: Family, text: String, sockaddrBytes: [UInt8]) {
        self.family = family
        self.text = text
        self.sockaddrBytes = sockaddrBytes
    }

    /// The same address with a TCP port set.
    func withPort(_ port: UInt16) -> [UInt8] {
        var bytes = sockaddrBytes
        // sin_port and sin6_port are both at offset 2, in network byte order.
        bytes[2] = UInt8(port >> 8)
        bytes[3] = UInt8(port & 0xff)
        return bytes
    }
}

public enum ResolveFailure: Error, Equatable {
    /// The name does not exist (NXDOMAIN or equivalent).
    case notFound(String)
    /// The resolver itself failed (no DNS server reachable, timeout, ...).
    case failed(String)
    case invalidInput(String)

    public var message: String {
        switch self {
        case .notFound(let host): return "DNS: \"\(host)\" was not found. Check the spelling, or that the name exists on this network."
        case .failed(let reason): return "DNS resolution failed: \(reason)"
        case .invalidInput(let reason): return reason
        }
    }
}

/// Outcome of one TCP connect attempt. A refusal (RST) proves that something at the address answered.
public enum TCPConnectOutcome: Equatable {
    case connected(milliseconds: Double)
    case refused(milliseconds: Double)
    case timedOut
    case failed(String)

    /// Whether the address answered at all (accepted or actively refused).
    public var hostResponded: Bool {
        switch self {
        case .connected, .refused: return true
        case .timedOut, .failed: return false
        }
    }
}

/// Small, blocking socket helpers shared by Ping and Local Network discovery. Every call has a hard timeout; nothing
/// here sends more than the one packet or connection it is asked for.
public enum ProbeSockets {
    #if canImport(Glibc)
    static let dgram = Int32(SOCK_DGRAM.rawValue)
    static let stream = Int32(SOCK_STREAM.rawValue)
    static let icmpProtocol = Int32(IPPROTO_ICMP)
    static let icmp6Protocol = Int32(IPPROTO_ICMPV6)
    #else
    static let dgram = SOCK_DGRAM
    static let stream = SOCK_STREAM
    static let icmpProtocol = IPPROTO_ICMP
    static let icmp6Protocol = IPPROTO_ICMPV6
    #endif

    /// Resolves a host name or numeric address with the system resolver (getaddrinfo), IPv4 first.
    public static func resolve(_ host: String, numericOnly: Bool = false) throws -> [ProbeAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = stream
        if numericOnly { hints.ai_flags = AI_NUMERICHOST }
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0 else {
            if numericOnly { throw ResolveFailure.invalidInput("\"\(host)\" is not a numeric IP address.") }
            if status == EAI_NONAME { throw ResolveFailure.notFound(host) }
            throw ResolveFailure.failed(String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(result) }
        var addresses: [ProbeAddress] = []
        var cursor = result
        while let info = cursor {
            defer { cursor = info.pointee.ai_next }
            guard let sa = info.pointee.ai_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let length = Int(info.pointee.ai_addrlen)
            let bytes = [UInt8](UnsafeRawBufferPointer(start: UnsafeRawPointer(sa), count: length))
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(length), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = ProbeAddress(family: family == AF_INET ? .ipv4 : .ipv6, text: String(cString: host), sockaddrBytes: bytes)
            if !addresses.contains(address) { addresses.append(address) }
        }
        guard !addresses.isEmpty else { throw ResolveFailure.failed("the resolver returned no IPv4 or IPv6 address") }
        return addresses.sorted { $0.family == .ipv4 && $1.family == .ipv6 }
    }

    /// Reverse DNS (PTR) for an address, if the network's resolver has one. Never guesses.
    public static func reverseName(_ address: ProbeAddress) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = address.sockaddrBytes.withUnsafeBytes { raw -> Int32 in
            let sa = raw.baseAddress!.assumingMemoryBound(to: sockaddr.self)
            return getnameinfo(sa, socklen_t(raw.count), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
        }
        guard status == 0 else { return nil }
        let name = String(cString: host)
        return name.isEmpty || name == address.text ? nil : name
    }

    /// One TCP connection attempt with a hard timeout. The connection is closed immediately; nothing is sent.
    public static func tcpConnect(_ address: ProbeAddress, port: UInt16, timeout: TimeInterval) -> TCPConnectOutcome {
        let fd = socket(address.family == .ipv4 ? AF_INET : AF_INET6, stream, 0)
        guard fd >= 0 else { return .failed("socket() failed: \(errorText(errno))") }
        defer { _ = close(fd) }
        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let target = address.withPort(port)
        let start = DispatchTime.now()
        let result = target.withUnsafeBytes { raw -> Int32 in
            connect(fd, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(raw.count))
        }
        if result == 0 { return .connected(milliseconds: elapsedMilliseconds(since: start)) }
        let code = errno
        if code == ECONNREFUSED { return .refused(milliseconds: elapsedMilliseconds(since: start)) }
        guard code == EINPROGRESS else { return .failed(errorText(code)) }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&descriptor, 1, Int32(max(1, timeout * 1000)))
        if ready == 0 { return .timedOut }
        guard ready > 0 else { return .failed(errorText(errno)) }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
        let elapsed = elapsedMilliseconds(since: start)
        switch socketError {
        case 0: return .connected(milliseconds: elapsed)
        case ECONNREFUSED: return .refused(milliseconds: elapsed)
        case ETIMEDOUT: return .timedOut
        default: return .failed(errorText(socketError))
        }
    }

    static func elapsedMilliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    static func errorText(_ code: Int32) -> String {
        switch code {
        case EHOSTUNREACH: return "No route to host (EHOSTUNREACH)"
        case ENETUNREACH: return "Network is unreachable (ENETUNREACH)"
        case EACCES, EPERM: return "Not permitted by the system (\(code == EACCES ? "EACCES" : "EPERM"))"
        case EADDRNOTAVAIL: return "Address not available (EADDRNOTAVAIL)"
        default: return "\(String(cString: strerror(code))) (errno \(code))"
        }
    }
}
