import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A deliberately small HTTP/1.1 server for the bundled lab. It listens on 127.0.0.1 only, on a port chosen by the
/// system, handles one short request per connection, and caps request sizes. It is not a general web server.
public final class LoopbackHTTPServer {
    public enum Failure: Error, Equatable {
        case socket(String)
    }

    public static let maxRequestBytes = 16 * 1024

    private let handler: (LabHTTPRequest) -> LabHTTPResponse
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var running = false
    private var thread: Thread?
    public private(set) var port: Int = 0

    public init(handler: @escaping (LabHTTPRequest) -> LabHTTPResponse) {
        self.handler = handler
    }

    deinit { stop() }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public var baseURL: URL? { port > 0 ? URL(string: "http://127.0.0.1:\(port)") : nil }

    /// Binds to 127.0.0.1 on a free port and starts accepting connections.
    public func start() throws -> URL {
        if let url = baseURL, isRunning { return url }
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw Failure.socket("socket() failed (\(errno))") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno
            _ = close(fd)
            throw Failure.socket("bind/listen on 127.0.0.1 failed (\(code))")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = Int(UInt16(bigEndian: actual.sin_port))
        listener = fd
        lock.lock(); running = true; lock.unlock()
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "sentinel.authlab.server"
        self.thread = thread
        thread.start()
        guard let url = baseURL else { throw Failure.socket("no port") }
        return url
    }

    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        guard wasRunning else { return }
        // The accept loop polls with a short timeout, sees `running == false` and closes the socket itself.
        thread = nil
    }

    private func acceptLoop(_ fd: Int32) {
        defer { _ = close(fd) }
        while isRunning {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 200)
            guard ready > 0, isRunning else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            serve(client)
            _ = close(client)
        }
    }

    private func serve(_ client: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        var request: LabHTTPRequest?
        var tooLarge = false
        while request == nil {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
            if data.count > LoopbackHTTPServer.maxRequestBytes { tooLarge = true; break }
            request = LoopbackHTTPServer.parse(data)
        }
        let response: LabHTTPResponse
        if tooLarge {
            response = .json(413, ["error": "Request too large"])
        } else if let request = request {
            response = handler(request)
        } else {
            response = .json(400, ["error": "Malformed request"])
        }
        let bytes = LoopbackHTTPServer.serialize(response)
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                #if canImport(Glibc)
                let sent = Glibc.send(client, raw.baseAddress! + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                #else
                let sent = Darwin.send(client, raw.baseAddress! + offset, raw.count - offset, 0)
                #endif
                guard sent > 0 else { break }
                offset += sent
            }
        }
    }

    /// Parses a complete request, or returns nil if more bytes are needed.
    static func parse(_ data: [UInt8]) -> LabHTTPRequest? {
        let separator: [UInt8] = [13, 10, 13, 10]
        guard data.count >= 4, let headerEnd = (0...(data.count - 4)).first(where: { Array(data[$0..<($0 + 4)]) == separator }) else { return nil }
        let head = String(decoding: data[0..<headerEnd], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return LabHTTPRequest(method: "INVALID", path: "/") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = min(Int(headers["content-length"] ?? "0") ?? 0, maxRequestBytes)
        let bodyStart = headerEnd + 4
        guard data.count >= bodyStart + length else { return nil }
        return LabHTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers,
                              body: Array(data[bodyStart..<(bodyStart + length)]))
    }

    static func serialize(_ response: LabHTTPResponse) -> [UInt8] {
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                       413: "Payload Too Large", 423: "Locked", 429: "Too Many Requests", 500: "Internal Server Error"]
        var head = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Status")\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        return Array(head.utf8) + response.body
    }
}

/// The bundled lab: the service plus its loopback server.
public final class AuthLabServer {
    public let service: AuthLabService
    private let server: LoopbackHTTPServer

    public init(configuration: AuthLabConfiguration = AuthLabConfiguration()) {
        let service = AuthLabService(configuration: configuration)
        self.service = service
        self.server = LoopbackHTTPServer(handler: service.handle)
    }

    public var isRunning: Bool { server.isRunning }

    /// Starts the lab on 127.0.0.1 and returns the target an assessment may use.
    public func start() throws -> AuthLabTarget {
        let url = try server.start()
        return AuthLabTarget(baseURL: url, instanceID: service.instanceID, adminToken: service.adminToken)
    }

    public func stop() { server.stop() }
}

/// The only kind of target the Authentication Defense Lab assessment accepts. It can be created only by starting the
/// bundled lab, so a real service cannot be targeted from this module.
public struct AuthLabTarget: Equatable {
    public let baseURL: URL
    public let instanceID: String
    let adminToken: String

    init(baseURL: URL, instanceID: String, adminToken: String) {
        self.baseURL = baseURL
        self.instanceID = instanceID
        self.adminToken = adminToken
    }
}
