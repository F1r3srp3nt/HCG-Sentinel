import Foundation

public enum HelperTransportEvent: Equatable {
    case opened
    case data(Data)
    case closed
    case failed(String)
}

/// Byte-stream channel to the helper (loopback TCP in the app; in-memory in tests).
public protocol HelperTransport: AnyObject {
    /// Events must be delivered on the main queue.
    var onEvent: ((HelperTransportEvent) -> Void)? { get set }
    func connect()
    func send(_ data: Data)
    func close()
}

public enum HelperClientState: Equatable {
    case disconnected
    case connecting
    case awaitingChallenge
    case awaitingSession
    case ready
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .disconnected, .failed: return false
        default: return true
        }
    }
}

public enum HelperClientError: Error, Equatable {
    case notReady
    case invalidPairingKey
    case operationNotGranted
    case invalidRequest(HelperValidationError)
    case helperError(code: String, message: String)
    case connectionLost(String)
    case malformedResponse

    public var userMessage: String {
        switch self {
        case .notReady: return "No authenticated helper session."
        case .invalidPairingKey: return "The pairing key must be at least \(HelperProtocol.minimumKeyBytes) bytes."
        case .operationNotGranted: return "The helper did not grant this operation to Sentinel."
        case .invalidRequest: return "The request parameters are outside the allowed ranges."
        case .helperError(let code, let message): return "Helper error \(code): \(message)"
        case .connectionLost(let reason): return reason
        case .malformedResponse: return "The helper returned a response that could not be read."
        }
    }
}

/// Client side of the Sentinel Helper Interface. A session becomes `ready`
/// only after both sides prove knowledge of the pairing key. Confine to the main queue.
public final class HelperClient {
    public typealias Completion = (Result<Data, HelperClientError>) -> Void

    public private(set) var state: HelperClientState = .disconnected
    public private(set) var grantedOperations: Set<HelperOperation> = []
    public private(set) var capabilityReport: HelperCapabilityReport?

    public var onChange: (() -> Void)?
    public var onLog: ((String, ActivitySeverity) -> Void)?
    /// An authenticated session answered a capability report.
    public var onVerified: ((HelperCapabilityReport) -> Void)?

    private let transport: HelperTransport
    private let nonceSource: (Int) -> [UInt8]
    private var decoder = HelperFrameDecoder()
    private var pairingKey: [UInt8] = []
    private var clientNonce: [UInt8] = []
    private var sessionKey: [UInt8] = []
    private var sequence = 0
    private var pending: [String: (sequence: Int, operation: HelperOperation, completion: Completion)] = [:]

    public init(transport: HelperTransport, nonceSource: @escaping (Int) -> [UInt8] = SecureRandom.bytes) {
        self.transport = transport
        self.nonceSource = nonceSource
        transport.onEvent = { [weak self] in self?.handle($0) }
    }

    public func connect(pairingKey: [UInt8]) throws {
        guard !state.isActive else { return }
        guard pairingKey.count >= HelperProtocol.minimumKeyBytes else { throw HelperClientError.invalidPairingKey }
        reset()
        self.pairingKey = pairingKey
        transition(.connecting)
        transport.connect()
    }

    public func disconnect() {
        guard state.isActive else {
            if case .failed = state { transition(.disconnected) }
            return
        }
        transport.close()
        failPending(.connectionLost("Disconnected."))
        reset()
        onLog?("Helper session closed", .info)
        transition(.disconnected)
    }

    public func request(_ operation: HelperOperation, body: Data = Data(), completion: @escaping Completion) {
        guard state == .ready else { return completion(.failure(.notReady)) }
        guard grantedOperations.contains(operation) else { return completion(.failure(.operationNotGranted)) }
        do {
            try HelperRequestValidator.validate(operation: operation.rawValue, body: body)
        } catch let error as HelperValidationError {
            return completion(.failure(.invalidRequest(error)))
        } catch {
            return completion(.failure(.invalidRequest(.malformedParameters)))
        }
        sequence += 1
        let requestID = "r\(sequence)"
        var frame = HelperFrame(.request)
        frame.sequence = sequence
        frame.requestID = requestID
        frame.operation = operation.rawValue
        frame.body = body.base64EncodedString()
        frame.mac = HelperAuth.base64(HelperAuth.messageMAC(sessionKey: sessionKey, isRequest: true, sequence: sequence,
                                                            requestID: requestID, operation: operation.rawValue,
                                                            ok: nil, body: body))
        pending[requestID] = (sequence, operation, completion)
        send(frame)
    }

    public func reportCapabilities(completion: @escaping (Result<HelperCapabilityReport, HelperClientError>) -> Void) {
        request(.reportCapabilities) { [weak self] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                guard let report = try? JSONDecoder().decode(HelperCapabilityReport.self, from: data) else {
                    return completion(.failure(.malformedResponse))
                }
                self?.capabilityReport = report
                self?.onLog?("Helper capability report received (version \(report.helperVersion), \(report.packaging))", .info)
                self?.onVerified?(report)
                self?.onChange?()
                completion(.success(report))
            }
        }
    }

    // MARK: Event handling

    private func handle(_ event: HelperTransportEvent) {
        switch event {
        case .opened:
            guard state == .connecting else { return }
            clientNonce = nonceSource(HelperProtocol.nonceBytes)
            var hello = HelperFrame(.hello)
            hello.protocolVersions = HelperProtocol.supportedVersions
            hello.clientNonce = HelperAuth.base64(clientNonce)
            transition(.awaitingChallenge) // State first: a transport may answer synchronously.
            send(hello)
        case .data(let data):
            guard state.isActive else { return }
            do {
                for frame in try decoder.append(data) {
                    handle(frame)
                    if !state.isActive { break }
                }
            } catch {
                fail("The helper sent data that is not a valid protocol frame.")
            }
        case .closed:
            guard state.isActive else { return }
            fail("The helper closed the connection.", closeTransport: false)
        case .failed(let reason):
            guard state.isActive else { return }
            fail(reason, closeTransport: false)
        }
    }

    private func handle(_ frame: HelperFrame) {
        if frame.kind == .error {
            fail("The helper refused the session: \(frame.errorMessage ?? frame.errorCode ?? "no reason given")")
            return
        }
        switch state {
        case .awaitingChallenge:
            guard frame.kind == .challenge, let version = frame.protocolVersion,
                  HelperProtocol.supportedVersions.contains(version),
                  let serverNonce = HelperAuth.decodeBase64(frame.serverNonce, exactCount: HelperProtocol.nonceBytes),
                  let proof = HelperAuth.decodeBase64(frame.proof) else {
                return fail("The helper sent an invalid challenge.")
            }
            let expected = HelperAuth.helperProof(key: pairingKey, clientNonce: clientNonce, serverNonce: serverNonce)
            guard HMACSHA256.constantTimeEquals(expected, proof) else {
                return fail("The helper could not prove it holds the pairing key. The session was not trusted.")
            }
            sessionKey = HelperAuth.sessionKey(key: pairingKey, clientNonce: clientNonce, serverNonce: serverNonce)
            var reply = HelperFrame(.authenticate)
            reply.proof = HelperAuth.base64(HelperAuth.clientProof(key: pairingKey, clientNonce: clientNonce, serverNonce: serverNonce))
            pairingKey = []
            transition(.awaitingSession)
            send(reply)
        case .awaitingSession:
            guard frame.kind == .session, frame.sessionID != nil else { return fail("The helper sent an invalid session reply.") }
            grantedOperations = Set((frame.grantedOperations ?? []).compactMap(HelperOperation.init(rawValue:)))
            onLog?("Helper session authenticated; \(grantedOperations.count) operation(s) granted", .info)
            transition(.ready)
        case .ready:
            guard frame.kind == .response, let requestID = frame.requestID, let entry = pending[requestID],
                  frame.sequence == entry.sequence, frame.operation == entry.operation.rawValue, let ok = frame.ok,
                  let body = Data(base64Encoded: frame.body ?? ""), let mac = HelperAuth.decodeBase64(frame.mac) else {
                return fail("The helper sent an unexpected or malformed response.")
            }
            let expected = HelperAuth.messageMAC(sessionKey: sessionKey, isRequest: false, sequence: entry.sequence,
                                                 requestID: requestID, operation: entry.operation.rawValue, ok: ok, body: body)
            guard HMACSHA256.constantTimeEquals(expected, mac) else {
                return fail("A helper response failed its integrity check.")
            }
            pending[requestID] = nil
            if ok {
                entry.completion(.success(body))
            } else {
                let detail = try? JSONDecoder().decode([String: String].self, from: body)
                entry.completion(.failure(.helperError(code: detail?["code"] ?? "unknown", message: detail?["message"] ?? "")))
            }
        default:
            fail("The helper sent a frame at an unexpected time.")
        }
    }

    private func send(_ frame: HelperFrame) {
        guard let data = try? HelperFraming.encode(frame) else { return fail("A request was too large to send.") }
        transport.send(data)
    }

    private func fail(_ reason: String, closeTransport: Bool = true) {
        if closeTransport { transport.close() }
        failPending(.connectionLost(reason))
        reset()
        onLog?("Helper connection failed: \(reason)", .warning)
        transition(.failed(reason))
    }

    private func failPending(_ error: HelperClientError) {
        let waiting = pending.values.map { $0.completion }
        pending.removeAll()
        waiting.forEach { $0(.failure(error)) }
    }

    private func reset() {
        decoder = HelperFrameDecoder()
        pairingKey = []
        clientNonce = []
        sessionKey = []
        sequence = 0
        grantedOperations = []
        capabilityReport = nil
    }

    private func transition(_ new: HelperClientState) {
        state = new
        onChange?()
    }
}
