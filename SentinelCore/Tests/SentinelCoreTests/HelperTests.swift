import XCTest
@testable import SentinelCore
#if canImport(CryptoKit)
import CryptoKit
#endif

final class CryptoTests: XCTestCase {
    func testSHA256KnownAnswers() {
        XCTAssertEqual(Hex.string(SHA256Portable.hash([])), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Hex.string(SHA256Portable.hash(Array("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Hex.string(SHA256Portable.hash([UInt8](repeating: 0x61, count: 56))),
                       "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
    }

    func testHMACKnownAnswersRFC4231() {
        let cases: [([UInt8], [UInt8], String)] = [
            ([UInt8](repeating: 0x0b, count: 20), Array("Hi There".utf8), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"),
            (Array("Jefe".utf8), Array("what do ya want for nothing?".utf8), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"),
            ([UInt8](repeating: 0xaa, count: 131), Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8),
             "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
        ]
        for (key, message, expected) in cases {
            XCTAssertEqual(Hex.string(SHA256Portable.hmac(key: key, message: message)), expected)
            XCTAssertEqual(Hex.string(HMACSHA256.authenticationCode(key: key, message: message)), expected)
        }
    }

    #if canImport(CryptoKit)
    func testPortableImplementationMatchesCryptoKit() {
        var generator = SeededGenerator(state: 7)
        for length in [0, 1, 55, 56, 63, 64, 65, 119, 120, 500] {
            let message = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            XCTAssertEqual(SHA256Portable.hash(message), Array(SHA256.hash(data: Data(message))))
        }
    }
    #endif

    func testConstantTimeEquals() {
        XCTAssertTrue(HMACSHA256.constantTimeEquals([1, 2, 3], [1, 2, 3]))
        XCTAssertFalse(HMACSHA256.constantTimeEquals([1, 2, 3], [1, 2, 4]))
        XCTAssertFalse(HMACSHA256.constantTimeEquals([1, 2, 3], [1, 2]))
        XCTAssertEqual(SecureRandom.bytes(32).count, 32)
        XCTAssertNotEqual(SecureRandom.bytes(32), SecureRandom.bytes(32))
    }
}

/// Stand-in for privileged work. It performs nothing privileged and says so.
final class HarnessHandler: HelperOperationHandler {
    var handled: [HelperOperation] = []

    func handle(_ operation: HelperOperation, body: Data) -> Result<Data, HelperOperationFailure> {
        handled.append(operation)
        switch operation {
        case .reportCapabilities:
            let report = HelperCapabilityReport(helperVersion: "0.0-harness", packaging: "test-harness",
                                                supportedOperations: ["reportCapabilities", "getStatus"],
                                                notes: "In-memory test harness. No privileged backend.")
            return .success((try? JSONEncoder().encode(report)) ?? Data())
        case .getStatus:
            return .success((try? JSONEncoder().encode(HelperStatus(activeCaptureID: nil, filterRuleCount: 0))) ?? Data())
        default:
            return .failure(HelperOperationFailure(code: "not_implemented", message: "The harness has no capture or filter backend."))
        }
    }
}

/// In-memory transport joining a `HelperClient` to a `HelperServerSession`.
final class LoopbackHelperTransport: HelperTransport {
    var onEvent: ((HelperTransportEvent) -> Void)?
    let server: HelperServerSession
    var closeCount = 0
    var clientFrames: [HelperFrame] = []
    /// Lets a test alter frames travelling from helper to client.
    var tamperResponse: ((HelperFrame) -> HelperFrame)?
    private var decoder = HelperFrameDecoder()

    init(server: HelperServerSession) { self.server = server }

    func connect() { onEvent?(.opened) }
    func close() { closeCount += 1 }

    func send(_ data: Data) {
        guard let frames = try? decoder.append(data) else { return }
        for frame in frames {
            clientFrames.append(frame)
            for var reply in server.receive(frame) {
                if let tamper = tamperResponse { reply = tamper(reply) }
                if let encoded = try? HelperFraming.encode(reply) { onEvent?(.data(encoded)) }
            }
        }
    }
}

final class HelperProtocolTests: XCTestCase {
    private let key = [UInt8](repeating: 0x42, count: 32)
    private var handler: HarnessHandler!

    override func setUp() { handler = HarnessHandler() }

    private func makePair(serverKey: [UInt8]? = nil, granted: Set<HelperOperation> = Set(HelperOperation.allCases))
        -> (HelperClient, LoopbackHelperTransport) {
        let server = HelperServerSession(pairingKey: serverKey ?? key, grantedOperations: granted, handler: handler)
        let transport = LoopbackHelperTransport(server: server)
        return (HelperClient(transport: transport), transport)
    }

    func testMutualAuthenticationAndCapabilityReport() throws {
        let (client, transport) = makePair()
        var verified: HelperCapabilityReport?
        client.onVerified = { verified = $0 }
        XCTAssertEqual(client.state, .disconnected)
        try client.connect(pairingKey: key)
        XCTAssertEqual(client.state, .ready)
        XCTAssertTrue(transport.server.isAuthenticated)
        XCTAssertNil(verified, "an authenticated session alone is not a verified capability")
        XCTAssertEqual(transport.clientFrames.map { $0.type }, ["hello", "authenticate"])
        XCTAssertNil(transport.clientFrames[1].clientNonce)

        var result: Result<HelperCapabilityReport, HelperClientError>?
        client.reportCapabilities { result = $0 }
        let report = try XCTUnwrap(try result?.get())
        XCTAssertEqual(report.packaging, "test-harness")
        XCTAssertEqual(verified, report)
        XCTAssertEqual(client.capabilityReport, report)
    }

    func testUnknownOperationsInAReportNeverEnableControls() throws {
        let report = HelperCapabilityReport(helperVersion: "x", packaging: "rootless",
                                            supportedOperations: ["reportCapabilities", "monitorMode", "packetInjection",
                                                                  "radioControl", "setFilterRules", "exec"])
        XCTAssertEqual(report.recognizedOperations, [.reportCapabilities, .setFilterRules])
        let markersOnly = PrivilegeAssessment(hints: [.packageManagerPresent, .filesystemMarker], helperSessionAuthenticated: false,
                                              helperReportedCapabilities: false)
        XCTAssertFalse(markersOnly.isPrivilegedAccessVerified, "jailbreak markers never stand in for a helper's report")
    }

    func testWrongPairingKeyIsRejectedByClient() throws {
        let (client, transport) = makePair(serverKey: [UInt8](repeating: 0x13, count: 32))
        try client.connect(pairingKey: key)
        guard case .failed(let reason) = client.state else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("pairing key"))
        XCTAssertFalse(transport.server.isAuthenticated)
        XCTAssertEqual(transport.clientFrames.map { $0.type }, ["hello"], "the client must not answer an unauthenticated helper")
        var result: Result<Data, HelperClientError>?
        client.request(.getStatus) { result = $0 }
        XCTAssertEqual(result, .failure(.notReady))
    }

    func testShortPairingKeyIsRefused() {
        let (client, _) = makePair()
        XCTAssertThrowsError(try client.connect(pairingKey: [1, 2, 3])) {
            XCTAssertEqual($0 as? HelperClientError, .invalidPairingKey)
        }
        XCTAssertEqual(client.state, .disconnected)
    }

    func testServerRejectsBadClientProofAndUnexpectedFrames() throws {
        let server = HelperServerSession(pairingKey: key, grantedOperations: [.getStatus], handler: handler)
        XCTAssertEqual(server.receive(HelperFrame(.request)).first?.errorCode, "protocol_error")
        XCTAssertTrue(server.isClosed)

        let second = HelperServerSession(pairingKey: key, grantedOperations: [.getStatus], handler: handler)
        var hello = HelperFrame(.hello)
        hello.protocolVersions = [1]
        hello.clientNonce = HelperAuth.base64([UInt8](repeating: 1, count: 32))
        XCTAssertEqual(second.receive(hello).first?.kind, .challenge)
        var authenticate = HelperFrame(.authenticate)
        authenticate.proof = HelperAuth.base64([UInt8](repeating: 0, count: 32))
        XCTAssertEqual(second.receive(authenticate).first?.errorCode, "authentication_failed")
        XCTAssertTrue(second.isClosed)
        XCTAssertFalse(second.isAuthenticated)
        XCTAssertTrue(handler.handled.isEmpty)

        let third = HelperServerSession(pairingKey: key, grantedOperations: [], handler: handler)
        hello.protocolVersions = [2, 3]
        XCTAssertEqual(third.receive(hello).first?.errorCode, "unsupported_version")
        hello.protocolVersions = [1]
        hello.clientNonce = "short"
        let fourth = HelperServerSession(pairingKey: key, grantedOperations: [], handler: handler)
        XCTAssertEqual(fourth.receive(hello).first?.errorCode, "bad_hello")
        let unpaired = HelperServerSession(pairingKey: [], grantedOperations: [], handler: handler)
        XCTAssertEqual(unpaired.receive(hello).first?.errorCode, "not_paired")
    }

    func testOperationsAreAuthorizedAndValidated() throws {
        let (client, _) = makePair(granted: [.reportCapabilities, .getStatus, .startCapture])
        try client.connect(pairingKey: key)
        XCTAssertEqual(client.grantedOperations, [.reportCapabilities, .getStatus, .startCapture])

        var result: Result<Data, HelperClientError>?
        client.request(.clearFilterRules) { result = $0 }
        XCTAssertEqual(result, .failure(.operationNotGranted))

        let invalid = try JSONEncoder().encode(CaptureStartParameters(interface: "en0; rm -rf /", snapLength: 256, maxDurationSeconds: 10, maxBytes: 1000))
        client.request(.startCapture, body: invalid) { result = $0 }
        XCTAssertEqual(result, .failure(.invalidRequest(.outOfRange("interface"))))
        XCTAssertTrue(handler.handled.isEmpty, "rejected requests never reach the handler")

        let valid = try JSONEncoder().encode(CaptureStartParameters(interface: "en0", snapLength: 256, maxDurationSeconds: 10, maxBytes: 1000))
        client.request(.startCapture, body: valid) { result = $0 }
        XCTAssertEqual(result, .failure(.helperError(code: "not_implemented", message: "The harness has no capture or filter backend.")))
        XCTAssertEqual(handler.handled, [.startCapture])
        XCTAssertEqual(client.state, .ready)
    }

    func testTamperedResponseEndsSession() throws {
        let (client, transport) = makePair()
        try client.connect(pairingKey: key)
        transport.tamperResponse = { frame in
            var copy = frame
            if copy.kind == .response { copy.body = Data(#"{"activeCaptureID":"forged","filterRuleCount":9}"#.utf8).base64EncodedString() }
            return copy
        }
        var result: Result<Data, HelperClientError>?
        client.request(.getStatus) { result = $0 }
        guard case .failure(.connectionLost)? = result else { return XCTFail("expected connection loss") }
        guard case .failed(let reason) = client.state else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("integrity"))
        XCTAssertEqual(transport.closeCount, 1)
    }

    func testServerRejectsReplayedAndForgedRequests() throws {
        let (client, transport) = makePair()
        try client.connect(pairingKey: key)
        client.request(.getStatus) { _ in }
        let original = try XCTUnwrap(transport.clientFrames.last)
        XCTAssertEqual(original.kind, .request)
        XCTAssertEqual(handler.handled, [.getStatus])

        // Replay of a genuine, correctly authenticated frame.
        XCTAssertEqual(transport.server.receive(original).first?.kind, .error)
        XCTAssertTrue(transport.server.isClosed)
        XCTAssertEqual(handler.handled, [.getStatus])

        // Forged operation name with the old MAC on a fresh session.
        let (client2, transport2) = makePair()
        try client2.connect(pairingKey: key)
        var forged = original
        forged.sequence = 5
        forged.operation = "clearFilterRules"
        XCTAssertEqual(transport2.server.receive(forged).first?.kind, .error)
        XCTAssertEqual(handler.handled, [.getStatus])
    }

    func testValidatorAllowlistAndRanges() throws {
        func check(_ operation: String, _ json: String) -> HelperValidationError? {
            do { try HelperRequestValidator.validate(operation: operation, body: Data(json.utf8)); return nil }
            catch { return error as? HelperValidationError }
        }
        XCTAssertNil(check("reportCapabilities", ""))
        XCTAssertEqual(check("reportCapabilities", "{}"), .unexpectedParameters)
        for forbidden in ["exec", "shell", "runCommand", "readFile", "", "ReportCapabilities"] {
            XCTAssertEqual(check(forbidden, ""), .unknownOperation(forbidden))
        }
        XCTAssertEqual(check("startCapture", "{}"), .malformedParameters)
        XCTAssertNil(check("startCapture", #"{"interface":"pdp_ip0","snapLength":65535,"maxDurationSeconds":3600,"maxBytes":1048576}"#))
        XCTAssertEqual(check("startCapture", #"{"interface":"../etc","snapLength":256,"maxDurationSeconds":10,"maxBytes":10}"#), .outOfRange("interface"))
        XCTAssertEqual(check("startCapture", #"{"interface":"en0","snapLength":10,"maxDurationSeconds":10,"maxBytes":10}"#), .outOfRange("snapLength"))
        XCTAssertEqual(check("startCapture", #"{"interface":"en0","snapLength":256,"maxDurationSeconds":86400,"maxBytes":10}"#), .outOfRange("maxDurationSeconds"))
        XCTAssertEqual(check("startCapture", #"{"interface":"en0","snapLength":256,"maxDurationSeconds":10,"maxBytes":999999999999}"#), .outOfRange("maxBytes"))
        XCTAssertEqual(check("stopCapture", #"{"captureID":"a b"}"#), .outOfRange("captureID"))
        XCTAssertNil(check("stopCapture", #"{"captureID":"3F2504E0-4F89-11D3-9A0C-0305E82C3301"}"#))
        XCTAssertNil(check("setFilterRules", #"{"rules":[{"id":"r1","action":"block","transport":"tcp","remoteAddress":"203.0.113.0/24","remotePort":443}]}"#))
        XCTAssertEqual(check("setFilterRules", #"{"rules":[]}"#), .outOfRange("rules"))
        XCTAssertEqual(check("setFilterRules", #"{"rules":[{"id":"r1","action":"redirect","transport":"tcp","remoteAddress":"203.0.113.1"}]}"#), .outOfRange("rule.action"))
        XCTAssertEqual(check("setFilterRules", #"{"rules":[{"id":"r1","action":"block","transport":"tcp","remoteAddress":"$(reboot)"}]}"#), .outOfRange("rule.remoteAddress"))
        XCTAssertEqual(check("setFilterRules", #"{"rules":[{"id":"r1","action":"block","transport":"tcp","remoteAddress":"2001:db8::1","remotePort":70000}]}"#), .outOfRange("rule.remotePort"))
    }

    func testFramingRoundTripAndLimits() throws {
        var frame = HelperFrame(.request)
        frame.sequence = 3
        frame.operation = "getStatus"
        let encoded = try HelperFraming.encode(frame)
        var decoder = HelperFrameDecoder()
        XCTAssertTrue(try decoder.append(encoded.prefix(3)).isEmpty)
        XCTAssertTrue(try decoder.append(encoded.dropFirst(3).prefix(10)).isEmpty)
        XCTAssertEqual(try decoder.append(encoded.dropFirst(13) + encoded), [frame, frame])

        var oversized = HelperFrame(.request)
        oversized.body = String(repeating: "A", count: HelperProtocol.maxFrameBytes)
        XCTAssertThrowsError(try HelperFraming.encode(oversized))
        var strict = HelperFrameDecoder()
        XCTAssertThrowsError(try strict.append(Data([0x7f, 0xff, 0xff, 0xff, 1, 2, 3]))) {
            guard case .frameTooLarge? = $0 as? HelperFramingError else { return XCTFail() }
        }
        XCTAssertThrowsError(try strict.append(Data([0, 0, 0, 2, 0x7b, 0x7d]))) { XCTAssertEqual($0 as? HelperFramingError, .invalidFrame) }
        XCTAssertThrowsError(try strict.append(Data([0, 0, 0, 0])))
    }

    func testGarbageFromHelperFailsClient() throws {
        let (client, transport) = makePair()
        try client.connect(pairingKey: key)
        transport.onEvent?(.data(Data([0xff, 0xff, 0xff, 0xff, 0x00])))
        guard case .failed = client.state else { return XCTFail("expected failure") }
        client.disconnect()
        XCTAssertEqual(client.state, .disconnected)
    }

    func testDisconnectFailsPendingRequests() throws {
        let server = HelperServerSession(pairingKey: key, grantedOperations: [.getStatus], handler: handler)
        let transport = LoopbackHelperTransport(server: server)
        let client = HelperClient(transport: transport)
        try client.connect(pairingKey: key)
        transport.tamperResponse = nil
        var result: Result<Data, HelperClientError>?
        client.request(.getStatus) { result = $0 }
        XCTAssertNotNil(try? result?.get())
        client.disconnect()
        XCTAssertEqual(client.state, .disconnected)
        XCTAssertTrue(client.grantedOperations.isEmpty)
        client.request(.getStatus) { result = $0 }
        XCTAssertEqual(result, .failure(.notReady))
    }
}

final class DebugProxyAdapterTests: XCTestCase {
    func testPlaceholderAdapterReportsNotImplemented() {
        let adapter = UnavailableDebugProxyAdapter()
        var described: Result<DebugProxyDescriptor, DebugProxyError>?
        adapter.describe { described = $0 }
        XCTAssertEqual(described, .failure(.notImplemented))
        var flows: Result<[ProxyFlowSummary], DebugProxyError>?
        adapter.listFlows(since: nil, limit: 10) { flows = $0 }
        XCTAssertEqual(flows, .failure(.notImplemented))
        adapter.disconnect()
    }
}
