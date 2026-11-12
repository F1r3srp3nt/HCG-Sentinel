import Foundation

public struct HelperOperationFailure: Error, Equatable {
    public let code: String
    public let message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// What a real helper would implement. Each operation receives parameters that
/// have already been authenticated and validated.
public protocol HelperOperationHandler: AnyObject {
    func handle(_ operation: HelperOperation, body: Data) -> Result<Data, HelperOperationFailure>
}

/// Reference implementation of the helper side of the protocol: handshake,
/// authorisation, replay protection and validation, with the privileged work
/// delegated to a `HelperOperationHandler`.
///
/// This is transport- and platform-independent. It is exercised by the test
/// harness only; no deployed helper exists, so it has never run privileged.
public final class HelperServerSession {
    private enum Phase { case awaitingHello, awaitingAuthentication, authenticated, closed }

    private let pairingKey: [UInt8]
    private let granted: Set<HelperOperation>
    private let handler: HelperOperationHandler
    private let nonceSource: (Int) -> [UInt8]
    private var phase = Phase.awaitingHello
    private var clientNonce: [UInt8] = []
    private var serverNonce: [UInt8] = []
    private var sessionKey: [UInt8] = []
    private var lastSequence = 0

    public init(pairingKey: [UInt8], grantedOperations: Set<HelperOperation>, handler: HelperOperationHandler,
                nonceSource: @escaping (Int) -> [UInt8] = SecureRandom.bytes) {
        self.pairingKey = pairingKey
        self.granted = grantedOperations
        self.handler = handler
        self.nonceSource = nonceSource
    }

    public var isClosed: Bool { phase == .closed }
    public var isAuthenticated: Bool { phase == .authenticated }

    /// Processes one inbound frame and returns the frames to send back.
    public func receive(_ frame: HelperFrame) -> [HelperFrame] {
        switch (phase, frame.kind) {
        case (.awaitingHello, .hello?):
            guard pairingKey.count >= HelperProtocol.minimumKeyBytes else { return close("not_paired", "Helper has no pairing key.") }
            guard let versions = frame.protocolVersions, versions.contains(HelperProtocol.version) else {
                return close("unsupported_version", "No common protocol version.")
            }
            guard let nonce = HelperAuth.decodeBase64(frame.clientNonce, exactCount: HelperProtocol.nonceBytes) else {
                return close("bad_hello", "Invalid client nonce.")
            }
            clientNonce = nonce
            serverNonce = nonceSource(HelperProtocol.nonceBytes)
            var challenge = HelperFrame(.challenge)
            challenge.protocolVersion = HelperProtocol.version
            challenge.serverNonce = HelperAuth.base64(serverNonce)
            challenge.proof = HelperAuth.base64(HelperAuth.helperProof(key: pairingKey, clientNonce: clientNonce, serverNonce: serverNonce))
            phase = .awaitingAuthentication
            return [challenge]

        case (.awaitingAuthentication, .authenticate?):
            let expected = HelperAuth.clientProof(key: pairingKey, clientNonce: clientNonce, serverNonce: serverNonce)
            guard let proof = HelperAuth.decodeBase64(frame.proof), HMACSHA256.constantTimeEquals(expected, proof) else {
                return close("authentication_failed", "Client proof rejected.")
            }
            sessionKey = HelperAuth.sessionKey(key: pairingKey, clientNonce: clientNonce, serverNonce: serverNonce)
            var session = HelperFrame(.session)
            session.sessionID = Hex.string(nonceSource(8))
            session.grantedOperations = granted.map { $0.rawValue }.sorted()
            phase = .authenticated
            return [session]

        case (.authenticated, .request?):
            if let response = respond(to: frame) { return [response] }
            return [errorFrame("protocol_error", "Request rejected.")]

        default:
            return close("protocol_error", "Unexpected frame.")
        }
    }

    private func respond(to frame: HelperFrame) -> HelperFrame? {
        guard let sequence = frame.sequence, let requestID = frame.requestID, let operationName = frame.operation,
              HelperRequestValidator.isValidIdentifier(requestID),
              let body = Data(base64Encoded: frame.body ?? ""), let mac = HelperAuth.decodeBase64(frame.mac) else {
            phase = .closed
            return nil
        }
        let expected = HelperAuth.messageMAC(sessionKey: sessionKey, isRequest: true, sequence: sequence, requestID: requestID,
                                             operation: operationName, ok: nil, body: body)
        // Integrity and replay failures end the session: they indicate tampering or a broken client.
        guard HMACSHA256.constantTimeEquals(expected, mac), sequence > lastSequence else {
            phase = .closed
            return nil
        }
        lastSequence = sequence

        let result: Result<Data, HelperOperationFailure>
        do {
            let operation = try HelperRequestValidator.validate(operation: operationName, body: body)
            if granted.contains(operation) {
                result = handler.handle(operation, body: body)
            } else {
                result = .failure(HelperOperationFailure(code: "not_authorized", message: "Operation not granted to this client."))
            }
        } catch {
            result = .failure(HelperOperationFailure(code: "invalid_request", message: "Parameters failed validation."))
        }

        var response = HelperFrame(.response)
        response.sequence = sequence
        response.requestID = requestID
        response.operation = operationName
        let payload: Data
        switch result {
        case .success(let data):
            response.ok = true
            payload = data
        case .failure(let failure):
            response.ok = false
            payload = (try? JSONEncoder().encode(["code": failure.code, "message": failure.message])) ?? Data()
        }
        response.body = payload.base64EncodedString()
        response.mac = HelperAuth.base64(HelperAuth.messageMAC(sessionKey: sessionKey, isRequest: false, sequence: sequence,
                                                               requestID: requestID, operation: operationName,
                                                               ok: response.ok, body: payload))
        return response
    }

    private func errorFrame(_ code: String, _ message: String) -> HelperFrame {
        var frame = HelperFrame(.error)
        frame.errorCode = code
        frame.errorMessage = message
        return frame
    }

    private func close(_ code: String, _ message: String) -> [HelperFrame] {
        phase = .closed
        return [errorFrame(code, message)]
    }
}
