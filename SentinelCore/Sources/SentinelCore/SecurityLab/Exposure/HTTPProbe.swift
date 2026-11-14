import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One request Exposure Check sends. Always without credentials, cookies or a body.
public struct HTTPProbeRequest: Equatable {
    public var url: URL
    public var method: String
    public var timeout: TimeInterval
    public var maxBodyBytes: Int

    public init(url: URL, method: String = "GET", timeout: TimeInterval, maxBodyBytes: Int) {
        self.url = url
        self.method = method
        self.timeout = timeout
        self.maxBodyBytes = maxBodyBytes
    }
}

/// What the TLS layer showed. Fields are nil when the platform cannot tell.
public struct TLSObservation: Equatable {
    /// Whether the system trusted the certificate for this host. Normal validation is never relaxed.
    public var trustedForHost: Bool?
    /// Whether the chain was trusted when the host name is not considered (distinguishes name mismatches).
    public var trustedIgnoringHost: Bool?
    public var chainSubjects: [String]
    public var leaf: X509Summary?

    public init(trustedForHost: Bool? = nil, trustedIgnoringHost: Bool? = nil, chainSubjects: [String] = [], leaf: X509Summary? = nil) {
        self.trustedForHost = trustedForHost
        self.trustedIgnoringHost = trustedIgnoringHost
        self.chainSubjects = chainSubjects
        self.leaf = leaf
    }
}

public struct HTTPProbeResponse: Equatable {
    public var status: Int
    /// Header names in lower case.
    public var headers: [String: String]
    public var bodyPrefix: [UInt8]
    public var bodyTruncated: Bool
    /// The address the connection actually reached, when the platform reports it.
    public var remoteAddress: String?
    public var tls: TLSObservation?

    public init(status: Int, headers: [String: String], bodyPrefix: [UInt8] = [], bodyTruncated: Bool = false,
                remoteAddress: String? = nil, tls: TLSObservation? = nil) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.bodyPrefix = bodyPrefix
        self.bodyTruncated = bodyTruncated
        self.remoteAddress = remoteAddress
        self.tls = tls
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public struct HTTPProbeFailure: Equatable, Error {
    public enum Kind: String, Equatable {
        case dns, timeout, refused, tlsUntrusted, tlsOther, network, cancelled, other
    }

    public var kind: Kind
    public var code: Int
    public var message: String
    public var tls: TLSObservation?

    public init(kind: Kind, code: Int, message: String, tls: TLSObservation? = nil) {
        self.kind = kind
        self.code = code
        self.message = message
        self.tls = tls
    }

    public var isTLS: Bool { kind == .tlsUntrusted || kind == .tlsOther }

    /// Maps URLSession error codes. TLS failures are kept apart from connectivity failures.
    public static func classify(code: Int, message: String, tls: TLSObservation? = nil) -> HTTPProbeFailure {
        let lower = message.lowercased()
        let kind: Kind
        switch code {
        case -999: kind = .cancelled
        case -1001: kind = .timeout
        case -1003, -1006: kind = .dns
        case -1004: kind = lower.contains("certificate") || lower.contains("ssl") ? .tlsOther : .refused
        case -1202, -1201, -1203, -1204, -1205, -1206: kind = .tlsUntrusted
        case -1200: kind = (lower.contains("certificate") || lower.contains("verif") || lower.contains("trust")) ? .tlsUntrusted : .tlsOther
        case -1009, -1005, -1018, -1020: kind = .network
        default:
            if lower.contains("certificate") || lower.contains("ssl peer") || lower.contains("self signed") || lower.contains("self-signed") {
                kind = .tlsUntrusted
            } else if lower.contains("ssl") || lower.contains("tls") {
                kind = .tlsOther
            } else if lower.contains("refused") || lower.contains("couldn't connect") || lower.contains("could not connect") {
                kind = .refused
            } else if lower.contains("timed out") {
                kind = .timeout
            } else {
                kind = .other
            }
        }
        return HTTPProbeFailure(kind: kind, code: code, message: message, tls: tls)
    }
}

public enum HTTPProbeResult: Equatable {
    case response(HTTPProbeResponse)
    case failure(HTTPProbeFailure)
}

/// Everything Exposure Check needs from the network. Calls are blocking and must honour `control`.
public protocol ExposureTransport: AnyObject {
    /// Resolves a host name to numeric addresses.
    func resolve(host: String, timeout: TimeInterval, control: AssessmentControl) -> Result<[String], HTTPProbeFailure>
    /// Sends one request. Must not follow redirects, send cookies or credentials, or relax TLS validation.
    func send(_ request: HTTPProbeRequest, control: AssessmentControl) -> HTTPProbeResult
}

// MARK: System resolver

public enum SystemResolver {
    /// getaddrinfo on a worker thread, abandoned (not killed) if it exceeds the timeout or the run is cancelled.
    public static func resolve(host: String, timeout: TimeInterval, control: AssessmentControl) -> Result<[String], HTTPProbeFailure> {
        if AddressClassifier.classify(host) != nil { return .success([AddressClassifier.normalizedHost(host)]) }
        let lock = NSLock()
        var outcome: Result<[String], HTTPProbeFailure>?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = lookup(host)
            lock.lock(); outcome = result; lock.unlock()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(min(timeout, max(0, control.remaining)))
        while Date() < deadline {
            if control.isCancelled { return .failure(HTTPProbeFailure(kind: .cancelled, code: -999, message: "Cancelled")) }
            if done.wait(timeout: .now() + 0.05) == .success {
                lock.lock(); defer { lock.unlock() }
                return outcome ?? .failure(HTTPProbeFailure(kind: .dns, code: 0, message: "No result"))
            }
        }
        return .failure(HTTPProbeFailure(kind: .timeout, code: -1001, message: "Name resolution timed out"))
    }

    private static func lookup(_ host: String) -> Result<[String], HTTPProbeFailure> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &list)
        guard status == 0 else {
            let message = String(cString: gai_strerror(status))
            return .failure(HTTPProbeFailure(kind: .dns, code: Int(status), message: "Name resolution failed: \(message)"))
        }
        defer { freeaddrinfo(list) }
        var addresses: [String] = []
        var cursor = list
        while let info = cursor {
            if let address = info.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: 1025)
                if getnameinfo(address, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(cString: buffer)
                    if !addresses.contains(text) { addresses.append(text) }
                }
            }
            cursor = info.pointee.ai_next
        }
        return addresses.isEmpty ? .failure(HTTPProbeFailure(kind: .dns, code: 0, message: "No addresses")) : .success(addresses)
    }
}

// MARK: URLSession transport

/// The production transport. Ephemeral session, no cookies, no credential storage, no redirects followed,
/// response bodies capped, system TLS validation unchanged. On Apple platforms it records the certificate
/// chain and the address the connection reached.
public final class FoundationExposureTransport: NSObject, ExposureTransport, URLSessionDataDelegate {
    private final class TaskState {
        var response: HTTPURLResponse?
        var body: [UInt8] = []
        var truncated = false
        var remoteAddress: String?
        var tls: TLSObservation?
        var maxBody = 0
        var failure: HTTPProbeFailure?
        let done = DispatchSemaphore(value: 0)
    }

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var states: [Int: TaskState] = [:]
    private let lock = NSLock()
    private var session: URLSession!

    public override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    deinit { session.invalidateAndCancel() }

    public func resolve(host: String, timeout: TimeInterval, control: AssessmentControl) -> Result<[String], HTTPProbeFailure> {
        SystemResolver.resolve(host: host, timeout: timeout, control: control)
    }

    private func state(_ task: URLSessionTask) -> TaskState? {
        lock.lock(); defer { lock.unlock() }
        return states[task.taskIdentifier]
    }

    public func send(_ request: HTTPProbeRequest, control: AssessmentControl) -> HTTPProbeResult {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue("HCG-Sentinel-ExposureCheck/1.0", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: urlRequest)
        let state = TaskState()
        state.maxBody = request.maxBodyBytes
        lock.lock(); states[task.taskIdentifier] = state; lock.unlock()
        control.whenCancelled { [weak task] in task?.cancel() }
        task.resume()
        let finished = state.done.wait(timeout: .now() + request.timeout + 2) == .success
        if !finished { task.cancel(); _ = state.done.wait(timeout: .now() + 2) }
        lock.lock(); states[task.taskIdentifier] = nil; lock.unlock()
        if control.isCancelled { return .failure(HTTPProbeFailure(kind: .cancelled, code: -999, message: "Cancelled")) }
        if !finished { return .failure(HTTPProbeFailure(kind: .timeout, code: -1001, message: "The request timed out")) }
        if let response = state.response, state.failure == nil || state.truncated {
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                if let name = key as? String { headers[name.lowercased()] = "\(value)" }
            }
            return .response(HTTPProbeResponse(status: response.statusCode, headers: headers, bodyPrefix: state.body,
                                               bodyTruncated: state.truncated, remoteAddress: state.remoteAddress, tls: state.tls))
        }
        return .failure(state.failure ?? HTTPProbeFailure(kind: .other, code: 0, message: "No response"))
    }

    // Redirects are reported, never followed.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        state(dataTask)?.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = state(dataTask) else { return }
        let room = state.maxBody - state.body.count
        if data.count > room {
            state.body.append(contentsOf: data.prefix(max(0, room)))
            state.truncated = true
            dataTask.cancel()
        } else {
            state.body.append(contentsOf: data)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = state(task) else { return }
        if let error = error as NSError? {
            state.failure = HTTPProbeFailure.classify(code: error.code, message: error.localizedDescription, tls: state.tls)
        }
        state.done.signal()
    }

    #if canImport(Darwin)
    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let state = state(task) else { return }
        if #available(iOS 13.0, macOS 10.15, *) {
            state.remoteAddress = metrics.transactionMetrics.last(where: { $0.remoteAddress != nil })?.remoteAddress
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust, let state = state(task) {
            state.tls = TLSInspector.observe(trust: trust, host: challenge.protectionSpace.host)
        }
        // Normal system validation decides; nothing is ever accepted that the system would reject.
        completionHandler(.performDefaultHandling, nil)
    }
    #endif
}

#if canImport(Security)
import Security

enum TLSInspector {
    static func observe(trust: SecTrust, host: String) -> TLSObservation {
        var chain: [SecCertificate] = []
        if #available(iOS 15.0, macOS 12.0, *) {
            chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        } else {
            for index in 0..<SecTrustGetCertificateCount(trust) {
                if let certificate = SecTrustGetCertificateAtIndex(trust, index) { chain.append(certificate) }
            }
        }
        let subjects = chain.prefix(4).compactMap { SecCertificateCopySubjectSummary($0) as String? }
        let leaf = chain.first.map { [UInt8](SecCertificateCopyData($0) as Data) }.flatMap { X509Summary.parse(der: $0) }
        return TLSObservation(trustedForHost: evaluate(chain, policy: SecPolicyCreateSSL(true, host as CFString)),
                              trustedIgnoringHost: evaluate(chain, policy: SecPolicyCreateBasicX509()),
                              chainSubjects: subjects, leaf: leaf)
    }

    /// Evaluates a copy of the chain, so the trust object used for the real connection is not modified.
    private static func evaluate(_ chain: [SecCertificate], policy: SecPolicy) -> Bool? {
        guard !chain.isEmpty else { return nil }
        var copy: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, policy, &copy) == errSecSuccess, let trust = copy else { return nil }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
#endif
