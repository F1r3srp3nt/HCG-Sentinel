import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

public enum ResponseBodyFormat: String, CaseIterable, Equatable {
    case text = "Text"
    case json = "JSON"
    case hex = "Hex"
}

/// Renders a response body for inspection. Never executes or follows anything in it.
public enum ResponseFormatter {
    public static let displayLimit = 20_000

    public static func prettyJSON(_ data: Data) -> String? {
        guard !data.isEmpty, let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let text = String(data: pretty, encoding: .utf8) else { return nil }
        return text
    }

    /// The best initial format: JSON when the body parses as JSON, text when it is UTF-8, otherwise hex.
    public static func suggestedFormat(for data: Data) -> ResponseBodyFormat {
        if prettyJSON(data) != nil { return .json }
        return String(data: data, encoding: .utf8) != nil ? .text : .hex
    }

    public static func render(_ data: Data, as format: ResponseBodyFormat, limit: Int = displayLimit) -> String {
        if data.isEmpty { return "" }
        let text: String
        switch format {
        case .text:
            text = String(data: data, encoding: .utf8) ?? "The body is not valid UTF-8 text. Choose Hex to inspect it."
        case .json:
            text = prettyJSON(data) ?? "The body is not valid JSON."
        case .hex:
            return Hex.dump(Array(data), maxBytes: max(16, limit / 4))
        }
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n… \(text.count - limit) more characters not shown"
    }
}

/// What TLS the connection used, as the system reported it. Absent for plain HTTP or when iOS reported nothing.
public struct TLSDetails: Equatable {
    /// For example "TLS 1.3".
    public var protocolVersion: String?
    /// IANA name when known, otherwise the hexadecimal code.
    public var cipherSuite: String?
    /// Subject summaries of the presented chain, leaf first (at most 4).
    public var certificates: [String]
    /// The system's trust decision for the chain (it decides whether the request succeeds at all).
    public var trusted: Bool?

    public init(protocolVersion: String? = nil, cipherSuite: String? = nil, certificates: [String] = [], trusted: Bool? = nil) {
        self.protocolVersion = protocolVersion
        self.cipherSuite = cipherSuite
        self.certificates = certificates
        self.trusted = trusted
    }

    public static func protocolName(_ code: UInt16) -> String {
        switch code {
        case 0x0304: return "TLS 1.3"
        case 0x0303: return "TLS 1.2"
        case 0x0302: return "TLS 1.1 (deprecated)"
        case 0x0301: return "TLS 1.0 (deprecated)"
        default: return String(format: "TLS 0x%04X", code)
        }
    }

    public static func cipherName(_ code: UInt16) -> String {
        let known: [UInt16: String] = [
            0x1301: "TLS_AES_128_GCM_SHA256", 0x1302: "TLS_AES_256_GCM_SHA384", 0x1303: "TLS_CHACHA20_POLY1305_SHA256",
            0xC02B: "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256", 0xC02C: "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
            0xC02F: "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256", 0xC030: "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
            0xCCA8: "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256", 0xCCA9: "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
        ]
        return known[code] ?? String(format: "0x%04X", code)
    }
}

/// Where the time went, from the system's task metrics. Each value is nil when that phase did not happen
/// (for example a reused connection has no DNS, connect or TLS phase).
public struct RequestTiming: Equatable {
    public var dns: TimeInterval?
    public var connect: TimeInterval?
    public var tls: TimeInterval?
    /// From sending the request to the first response byte.
    public var firstByte: TimeInterval?
    public var reusedConnection: Bool

    public init(dns: TimeInterval? = nil, connect: TimeInterval? = nil, tls: TimeInterval? = nil, firstByte: TimeInterval? = nil, reusedConnection: Bool = false) {
        self.dns = dns
        self.connect = connect
        self.tls = tls
        self.firstByte = firstByte
        self.reusedConnection = reusedConnection
    }
}

/// One sent request in the session history: what was sent (redacted) and what came back. Kept in memory only.
public struct RequestHistoryEntry: Equatable, Identifiable {
    public let id: Int
    public let at: Date
    public let method: String
    /// User info and sensitive query values redacted.
    public let url: String
    /// Header names; sensitive values are never kept.
    public let headerNames: [String]
    public let bodyBytes: Int
    public let outcome: String
    public let statusCode: Int?
    public let duration: TimeInterval?
    public let tls: TLSDetails?
}

public struct HTTPResponseRecord: Equatable {
    public let statusCode: Int
    public let headers: [PreparedRequest.Header]
    public let body: Data
    /// True when the body was longer than the display limit and was cut.
    public let bodyTruncated: Bool
    public let totalBodyBytes: Int
    public let startedAt: Date
    /// Wall-clock time from Send until the complete response arrived.
    public let duration: TimeInterval
    public var tls: TLSDetails?
    public var timing: RequestTiming?

    public init(statusCode: Int, headers: [PreparedRequest.Header], body: Data, bodyTruncated: Bool,
                totalBodyBytes: Int, startedAt: Date, duration: TimeInterval, tls: TLSDetails? = nil, timing: RequestTiming? = nil) {
        self.tls = tls
        self.timing = timing
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.bodyTruncated = bodyTruncated
        self.totalBodyBytes = totalBodyBytes
        self.startedAt = startedAt
        self.duration = duration
    }

    public var bodyText: String {
        if body.isEmpty { return "" }
        return String(data: body, encoding: .utf8) ?? "<\(body.count) bytes of non-UTF-8 data>\n" + Hex.dump(Array(body), maxBytes: 512)
    }
}

public enum RequestExecutionError: Error, Equatable {
    case cancelled
    case timedOut
    case transport(String)
    case notHTTP

    public var userMessage: String {
        switch self {
        case .cancelled: return "The request was cancelled."
        case .timedOut: return "The endpoint did not answer before the timeout."
        case .transport(let detail): return "The request could not be completed: \(detail)"
        case .notHTTP: return "The endpoint did not return an HTTP response."
        }
    }
}

public protocol HTTPCancellable: AnyObject {
    func cancel()
}

public protocol HTTPTransport: AnyObject {
    /// Sends one request. The completion is delivered exactly once, on the main queue.
    func send(_ request: PreparedRequest, timeout: TimeInterval,
              completion: @escaping (Result<HTTPResponseRecord, RequestExecutionError>) -> Void) -> HTTPCancellable
}

/// URLSession-backed transport: ephemeral (no cookies, cache or stored
/// credentials) and never follows redirects, so a request cannot leave the
/// selected endpoint by being redirected.
public final class URLSessionHTTPTransport: NSObject, HTTPTransport, URLSessionTaskDelegate {
    public static let maxDisplayedBodyBytes = 1_048_576
    private var session: URLSession!
    /// Per-task TLS and timing, written and read on the session's serial delegate queue only.
    private var tlsByTask: [Int: TLSDetails] = [:]
    private var timingByTask: [Int: RequestTiming] = [:]

    public override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    private final class TaskHandle: HTTPCancellable {
        let task: URLSessionTask
        init(_ task: URLSessionTask) { self.task = task }
        func cancel() { task.cancel() }
    }

    public func send(_ request: PreparedRequest, timeout: TimeInterval,
                     completion: @escaping (Result<HTTPResponseRecord, RequestExecutionError>) -> Void) -> HTTPCancellable {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpShouldHandleCookies = false
        for header in request.headers {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.name)
        }
        urlRequest.httpBody = request.body
        let started = Date()
        var taskID = -1
        let task = session.dataTask(with: urlRequest) { [weak self] data, response, error in
            // Runs on the delegate queue after the metrics callback for this task.
            let tls = self?.tlsByTask.removeValue(forKey: taskID)
            let timing = self?.timingByTask.removeValue(forKey: taskID)
            let result: Result<HTTPResponseRecord, RequestExecutionError>
            if let error = error {
                let code = (error as NSError).code
                if code == NSURLErrorCancelled {
                    result = .failure(.cancelled)
                } else if code == NSURLErrorTimedOut {
                    result = .failure(.timedOut)
                } else {
                    result = .failure(.transport(error.localizedDescription))
                }
            } else if let http = response as? HTTPURLResponse {
                let body = data ?? Data()
                let limit = URLSessionHTTPTransport.maxDisplayedBodyBytes
                let headers = http.allHeaderFields
                    .map { PreparedRequest.Header(name: "\($0.key)", value: "\($0.value)") }
                    .sorted { $0.name.lowercased() < $1.name.lowercased() }
                result = .success(HTTPResponseRecord(statusCode: http.statusCode, headers: headers,
                                                     body: Data(body.prefix(limit)), bodyTruncated: body.count > limit,
                                                     totalBodyBytes: body.count, startedAt: started,
                                                     duration: Date().timeIntervalSince(started),
                                                     tls: request.url.scheme?.lowercased() == "https" ? tls : nil, timing: timing))
            } else {
                result = .failure(.notHTTP)
            }
            DispatchQueue.main.async { completion(result) }
        }
        taskID = task.taskIdentifier
        task.resume()
        return TaskHandle(task)
    }

    #if canImport(Darwin)
    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        func span(_ a: Date?, _ b: Date?) -> TimeInterval? {
            guard let a = a, let b = b else { return nil }
            return b.timeIntervalSince(a)
        }
        timingByTask[task.taskIdentifier] = RequestTiming(
            dns: span(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
            connect: span(transaction.connectStartDate, transaction.connectEndDate),
            tls: span(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
            firstByte: span(transaction.requestStartDate, transaction.responseStartDate),
            reusedConnection: transaction.isReusedConnection)
        if #available(iOS 13.0, macOS 10.15, *) {
            var details = tlsByTask[task.taskIdentifier] ?? TLSDetails()
            if let version = transaction.negotiatedTLSProtocolVersion { details.protocolVersion = TLSDetails.protocolName(version.rawValue) }
            if let suite = transaction.negotiatedTLSCipherSuite { details.cipherSuite = TLSDetails.cipherName(suite.rawValue) }
            tlsByTask[task.taskIdentifier] = details
        }
    }

    /// Records the presented chain and the system's own trust decision, then lets the system handle trust as usual.
    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            var details = tlsByTask[task.taskIdentifier] ?? TLSDetails()
            var chain: [SecCertificate] = []
            if #available(iOS 15.0, macOS 12.0, *) {
                chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
            } else {
                for index in 0..<SecTrustGetCertificateCount(trust) {
                    if let certificate = SecTrustGetCertificateAtIndex(trust, index) { chain.append(certificate) }
                }
            }
            details.certificates = chain.prefix(4).compactMap { SecCertificateCopySubjectSummary($0) as String? }
            details.trusted = SecTrustEvaluateWithError(trust, nil)
            tlsByTask[task.taskIdentifier] = details
        }
        completionHandler(.performDefaultHandling, nil)
    }
    #endif

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Surface the 3xx response itself instead of following it.
    }

    public func invalidate() {
        session.invalidateAndCancel()
    }
}

public enum RequestFailure: Equatable {
    case validation(RequestValidationError)
    case execution(RequestExecutionError)
    case busy

    public var userMessage: String {
        switch self {
        case .validation(let error): return error.userMessage
        case .execution(let error): return error.userMessage
        case .busy: return "A request is already in progress."
        }
    }
}

/// State machine for the controlled request-testing workflow. Nothing is sent
/// until `send` is called explicitly. Confine to the main queue.
public final class RequestComposer {
    public enum State: Equatable {
        case idle
        case sending(startedAt: Date)
        case completed(HTTPResponseRecord)
        case failed(RequestFailure)
    }

    public private(set) var state: State = .idle {
        didSet { onChange?() }
    }
    /// Requests sent in this session, newest first (at most `historyLimit`). Never stored on disk.
    public private(set) var history: [RequestHistoryEntry] = []
    public static let historyLimit = 25
    private var historyCounter = 0

    public func clearHistory() {
        history.removeAll()
        onChange?()
    }

    private func remember(_ prepared: PreparedRequest, at: Date, outcome: String, response: HTTPResponseRecord?) {
        historyCounter += 1
        let entry = RequestHistoryEntry(id: historyCounter, at: at, method: prepared.method.rawValue,
                                        url: redactor.url(prepared.url.absoluteString),
                                        headerNames: prepared.headers.map { $0.name }, bodyBytes: prepared.body?.count ?? 0,
                                        outcome: outcome, statusCode: response?.statusCode, duration: response?.duration, tls: response?.tls)
        history.insert(entry, at: 0)
        if history.count > RequestComposer.historyLimit { history.removeLast(history.count - RequestComposer.historyLimit) }
    }
    public var onChange: (() -> Void)?
    /// Called once per HTTP response received from the endpoint.
    public var onResponse: ((HTTPResponseRecord) -> Void)?

    private let transport: HTTPTransport
    private let log: ActivityLog?
    private let redactor: Redactor
    private var inFlight: HTTPCancellable?
    private var generation = 0

    public init(transport: HTTPTransport, log: ActivityLog? = nil, redactor: Redactor = .standard) {
        self.transport = transport
        self.log = log
        self.redactor = redactor
    }

    public var isSending: Bool {
        if case .sending = state { return true }
        return false
    }

    /// Validates and sends the draft. Returns the failure when nothing was sent.
    @discardableResult
    public func send(_ draft: RequestDraft, endpoint: TestEndpoint?, timeout: TimeInterval = 30) -> RequestFailure? {
        send(draft, endpoints: endpoint.map { [$0] } ?? [], timeout: timeout)
    }

    /// Validates and sends the draft to one of the allowed endpoints. Returns the failure when nothing was sent.
    @discardableResult
    public func send(_ draft: RequestDraft, endpoints: [TestEndpoint], timeout: TimeInterval = 30) -> RequestFailure? {
        guard !isSending else { return .busy }
        let prepared: PreparedRequest
        do {
            prepared = try RequestBuilder.prepare(draft, endpoints: endpoints)
        } catch let error as RequestValidationError {
            state = .failed(.validation(error))
            return .validation(error)
        } catch {
            state = .failed(.validation(.invalidPath))
            return .validation(.invalidPath)
        }
        generation += 1
        let current = generation
        let target = redactor.url(prepared.url.absoluteString)
        log?.record(.request, "Sent \(prepared.method.rawValue) \(target) with \(prepared.headers.count) header(s), \(prepared.body?.count ?? 0)-byte body")
        let sentAt = Date()
        state = .sending(startedAt: sentAt)
        inFlight = transport.send(prepared, timeout: timeout) { [weak self] result in
            guard let self = self, self.generation == current, self.isSending else { return }
            self.inFlight = nil
            switch result {
            case .success(let response):
                self.log?.record(.request, "Response \(response.statusCode) from \(target) in \(Int((response.duration * 1000).rounded())) ms, \(response.totalBodyBytes) bytes")
                self.remember(prepared, at: sentAt, outcome: "HTTP \(response.statusCode)", response: response)
                self.state = .completed(response)
                self.onResponse?(response)
            case .failure(let error):
                self.log?.record(.request, "Request to \(target) failed: \(error.userMessage)", severity: .warning)
                self.remember(prepared, at: sentAt, outcome: error.userMessage, response: nil)
                self.state = .failed(.execution(error))
            }
        }
        if !isSending { inFlight = nil } // A transport may complete synchronously.
        return nil
    }

    /// Cancels the in-flight request, if any. Returns true when something was cancelled.
    @discardableResult
    public func cancel() -> Bool {
        guard isSending else { return false }
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        log?.record(.request, "Request cancelled")
        state = .failed(.execution(.cancelled))
        return true
    }

    public func reset() {
        guard !isSending else { return }
        state = .idle
    }
}
