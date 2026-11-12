import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

    public init(statusCode: Int, headers: [PreparedRequest.Header], body: Data, bodyTruncated: Bool,
                totalBodyBytes: Int, startedAt: Date, duration: TimeInterval) {
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
        let task = session.dataTask(with: urlRequest) { data, response, error in
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
                                                     duration: Date().timeIntervalSince(started)))
            } else {
                result = .failure(.notHTTP)
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        return TaskHandle(task)
    }

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
        guard !isSending else { return .busy }
        let prepared: PreparedRequest
        do {
            prepared = try RequestBuilder.prepare(draft, endpoint: endpoint)
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
        state = .sending(startedAt: Date())
        inFlight = transport.send(prepared, timeout: timeout) { [weak self] result in
            guard let self = self, self.generation == current, self.isSending else { return }
            self.inFlight = nil
            switch result {
            case .success(let response):
                self.log?.record(.request, "Response \(response.statusCode) from \(target) in \(Int((response.duration * 1000).rounded())) ms, \(response.totalBodyBytes) bytes")
                self.state = .completed(response)
                self.onResponse?(response)
            case .failure(let error):
                self.log?.record(.request, "Request to \(target) failed: \(error.userMessage)", severity: .warning)
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
