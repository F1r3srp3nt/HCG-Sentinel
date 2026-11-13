import XCTest
@testable import SentinelCore

final class MockNodeTransport: NodeTransport {
    var onEvent: ((NodeTransportEvent) -> Void)?
    var connectedURL: URL?
    var sent: [String] = []
    var closeCount = 0
    /// Optional scripted node: returns the messages to deliver in response to a client message.
    var responder: ((String) -> [String])?

    func connect(to url: URL) { connectedURL = url }
    func send(text: String) {
        sent.append(text)
        for reply in responder?(text) ?? [] { onEvent?(.text(reply)) }
    }
    func close() { closeCount += 1 }

    func deliver(_ text: String) { onEvent?(.text(text)) }

    var sentEnvelopes: [NodeEnvelope] {
        sent.compactMap { try? JSONDecoder().decode(NodeEnvelope.self, from: Data($0.utf8)) }
    }
    var sentTypes: [String] { sentEnvelopes.map { $0.type } }
}

/// The node side of SNP v2, for tests. Performs the real handshake cryptography.
final class TestNode {
    let key: [UInt8]
    var info = NodeInfo(nodeName: "bench", nodeSoftware: "sentinel-node 0.2", simulated: false)
    var capabilities = NodeCapabilities(
        features: [NodeProtocol.spectrumFeature, NodeProtocol.wifiScanFeature],
        hardware: [NodeHardware(id: "sdr0", driver: "rtlsdr", description: "Test SDR",
                                minFrequencyHz: 24_000_000, maxFrequencyHz: 1_766_000_000, maxSpanHz: 2_400_000)],
        maxBins: 2048)
    let nodeNonce = NodeAuth.base64([UInt8](repeating: 0x5a, count: NodeProtocol.nonceBytes))
    private(set) var clientNonce = ""
    private(set) var sessionKey: [UInt8] = []
    private(set) var clientSeq = 0
    var seq = 0

    init(key: [UInt8]) { self.key = key }

    func challenge(forHello text: String, protocolVersion: Int = NodeProtocol.version) -> String {
        let hello = try! JSONDecoder().decode(NodeEnvelope.self, from: Data(text.utf8))
        let payload = try! JSONDecoder().decode(ClientHello.self, from: Data(hello.payload!.utf8))
        clientNonce = payload.clientNonce
        seq = 0
        clientSeq = 0
        sessionKey = NodeAuth.sessionKey(key: key, clientNonce: clientNonce, nodeNonce: nodeNonce)
        let body = NodeCodec.payloadText(NodeChallenge(protocolVersion: protocolVersion, nodeNonce: nodeNonce, node: info, capabilities: capabilities))
        let mac = NodeAuth.challengeMAC(key: key, clientNonce: clientNonce, payload: body)
        return NodeCodec.encode(NodeEnvelope(type: NodeMessageType.challenge, payload: body, mac: NodeAuth.base64(mac)))
    }

    func clientProofIsValid(_ text: String) -> Bool {
        guard let envelope = try? JSONDecoder().decode(NodeEnvelope.self, from: Data(text.utf8)),
              envelope.type == NodeMessageType.authenticate, let mac = NodeAuth.bytes(fromBase64: envelope.mac) else { return false }
        return mac == NodeAuth.authenticateMAC(key: key, clientNonce: clientNonce, nodeNonce: nodeNonce)
    }

    /// Verifies a client session message (MAC and next sequence number).
    func verifyClientMessage(_ text: String) -> NodeEnvelope? {
        guard let envelope = try? JSONDecoder().decode(NodeEnvelope.self, from: Data(text.utf8)),
              let seq = envelope.seq, let mac = NodeAuth.bytes(fromBase64: envelope.mac),
              mac == NodeAuth.messageMAC(sessionKey: sessionKey, sender: "client", seq: seq, type: envelope.type, payload: envelope.payload ?? ""),
              seq == clientSeq + 1 else { return nil }
        clientSeq = seq
        return envelope
    }

    func message(_ type: String, payloadText: String) -> String {
        seq += 1
        let mac = NodeAuth.messageMAC(sessionKey: sessionKey, sender: "node", seq: seq, type: type, payload: payloadText)
        return NodeCodec.encode(NodeEnvelope(type: type, seq: seq, payload: payloadText, mac: NodeAuth.base64(mac)))
    }

    func message<P: Encodable>(_ type: String, _ payload: P) -> String {
        message(type, payloadText: NodeCodec.payloadText(payload))
    }

    func ready() -> String { message(NodeMessageType.ready, EmptyPayload()) }

    static func frame(sequence: Int = 1, bins: Int = 64, power: Double = -80.5, unit: String = "dBFS") -> SpectrumFrame {
        SpectrumFrame(sequence: sequence, timestamp: 1_700_000_000.5, centerFrequencyHz: 100_000_000, spanHz: 2_000_000,
                      unit: unit, powers: Array(repeating: power, count: bins))
    }

    static func scan(_ networks: [WifiNetwork]? = nil) -> WifiScanResult {
        WifiScanResult(scannedAt: 1_700_000_100, interface: "wlan0", networks: networks ?? [
            WifiNetwork(ssid: "LabNet", bssid: "02:00:00:00:00:01", channel: 6, frequencyMHz: 2437, rssiDbm: -48, security: "wpa2"),
            WifiNetwork(ssid: nil, bssid: "02:00:00:00:00:02", channel: 36, frequencyMHz: 5180, rssiDbm: -71, security: "wpa3")
        ])
    }
}

final class NodeCodecTests: XCTestCase {
    private func error(_ text: String) -> NodeProtocolError? {
        do { _ = try NodeCodec.envelope(from: text); return nil } catch { return error as? NodeProtocolError }
    }

    func testEnvelopeRoundTripAndPayloadAsExactText() throws {
        let payload = NodeCodec.payloadText(NodeStatus(state: "idle", hardwarePresent: true))
        let text = NodeCodec.encode(NodeEnvelope(type: NodeMessageType.status, seq: 3, payload: payload, mac: "AA=="))
        let envelope = try NodeCodec.envelope(from: text)
        XCTAssertEqual(envelope.v, 2)
        XCTAssertEqual(envelope.seq, 3)
        XCTAssertEqual(envelope.payload, payload, "the payload is carried as the exact JSON text the MAC covers")
        XCTAssertEqual(try NodeCodec.decodePayload(NodeStatus.self, from: envelope).state, "idle")
    }

    func testMalformedEnvelopesAreRejected() {
        XCTAssertEqual(error("not json"), .notJSON)
        XCTAssertEqual(error("[1,2,3]"), .notJSON)
        XCTAssertEqual(error(#"{"type":"pong"}"#), .notJSON)
        XCTAssertEqual(error(#"{"v":"2","type":"pong"}"#), .notJSON)
        XCTAssertEqual(error(#"{"v":1,"type":"hello_ack","payload":"{}"}"#), .unsupportedVersion(1))
        XCTAssertEqual(error(#"{"v":3,"type":"pong"}"#), .unsupportedVersion(3))
        XCTAssertEqual(error(#"{"v":2,"type":"transmit"}"#), .unknownType("transmit"))
        XCTAssertEqual(error(#"{"v":2,"type":"set_monitor_mode"}"#), .unknownType("set_monitor_mode"))
        XCTAssertEqual(error(#"{"v":2,"type":"hello"}"#), .unknownType("hello"), "client message types are not accepted from a node")
        guard case .invalidPayload? = error(#"{"v":2,"type":"status","payload":{"state":"idle"}}"#) else {
            return XCTFail("a payload that is not JSON text is rejected")
        }
        let oversized = #"{"v":2,"type":"pong","payload":""# + String(repeating: "x", count: NodeProtocol.maxMessageBytes) + #""}"#
        guard case .messageTooLarge? = error(oversized) else { return XCTFail("size") }
    }

    func testPayloadDecodingErrors() throws {
        let missing = NodeEnvelope(type: NodeMessageType.status)
        XCTAssertThrowsError(try NodeCodec.decodePayload(NodeStatus.self, from: missing)) {
            XCTAssertEqual($0 as? NodeProtocolError, .missingPayload("status"))
        }
        for bad in ["not json", #"{"state":5}"#, "[]", #"{"state":"idle"}"#] {
            XCTAssertThrowsError(try NodeCodec.decodePayload(NodeStatus.self, from: NodeEnvelope(type: NodeMessageType.status, payload: bad)), bad) {
                guard case .invalidPayload? = $0 as? NodeProtocolError else { return XCTFail("\(bad): \($0)") }
            }
        }
    }

    func testFrameValidation() {
        XCTAssertNoThrow(try NodeCodec.validate(TestNode.frame()))
        for frame in [TestNode.frame(bins: 4), TestNode.frame(bins: NodeProtocol.maxBins + 1), TestNode.frame(power: 500),
                      TestNode.frame(power: .nan), TestNode.frame(unit: "volts")] {
            XCTAssertThrowsError(try NodeCodec.validate(frame))
        }
        var frame = TestNode.frame()
        frame.spanHz = 0
        XCTAssertThrowsError(try NodeCodec.validate(frame))
    }

    func testWifiScanValidation() {
        XCTAssertNoThrow(try NodeCodec.validate(TestNode.scan()))
        let good = WifiNetwork(ssid: "A", bssid: "02:00:00:00:00:01", channel: 6, frequencyMHz: 2437, rssiDbm: -50, security: "wpa2")
        var cases: [WifiNetwork] = []
        var n = good; n.bssid = "zz:00:00:00:00:01"; cases.append(n)
        n = good; n.bssid = "02:00:00:00:00"; cases.append(n)
        n = good; n.rssiDbm = 20; cases.append(n)
        n = good; n.channel = 0; cases.append(n)
        n = good; n.frequencyMHz = 900; cases.append(n)
        n = good; n.security = "monitor"; cases.append(n)
        n = good; n.ssid = String(repeating: "é", count: 17); cases.append(n)
        for network in cases {
            XCTAssertThrowsError(try NodeCodec.validate(TestNode.scan([network])), "\(network)")
        }
        let tooMany = (0...NodeProtocol.maxWifiNetworks).map { _ in good }
        XCTAssertThrowsError(try NodeCodec.validate(TestNode.scan(tooMany)))
        var scan = TestNode.scan()
        scan.interface = ""
        XCTAssertThrowsError(try NodeCodec.validate(scan))
    }

    func testCapabilityValidationAndUnknownFeatures() throws {
        var capabilities = NodeCapabilities(features: ["monitor_mode", "packet_injection", "spectrum", "baseband"], hardware: [], maxBins: 512)
        XCTAssertEqual(capabilities.recognizedFeatures, ["spectrum"], "unknown feature strings never enable anything")
        XCTAssertNoThrow(try NodeCodec.validate(capabilities))
        capabilities.hardware = [NodeHardware(id: "x", driver: "d", description: "bad", minFrequencyHz: 10, maxFrequencyHz: 5, maxSpanHz: 1)]
        XCTAssertThrowsError(try NodeCodec.validate(capabilities))
    }

    func testPairingKeyParsing() {
        XCTAssertNil(NodeAuth.pairingKey(fromHex: "abcd"))
        XCTAssertNil(NodeAuth.pairingKey(fromHex: String(repeating: "zz", count: 32)))
        XCTAssertNil(NodeAuth.pairingKey(fromHex: String(repeating: "a", count: 63)))
        XCTAssertEqual(NodeAuth.pairingKey(fromHex: String(repeating: "0f", count: 32))?.count, 32)
        XCTAssertEqual(NodeAuth.pairingKey(fromHex: "0f0f 0f0f\n" + String(repeating: "0f", count: 28))?.count, 32, "whitespace is ignored")
    }
}

final class RadioNodeSessionTests: XCTestCase {
    private let key = [UInt8](repeating: 0x42, count: 32)
    private var transport: MockNodeTransport!
    private var session: RadioNodeSession!
    private var node: TestNode!
    private var clock = Date(timeIntervalSince1970: 9_000)
    private var linkVerified = 0
    private var hardwareVerified = 0
    private var scansVerified = 0
    private var states: [RadioNodeState] = []

    override func setUp() {
        transport = MockNodeTransport()
        node = TestNode(key: key)
        session = RadioNodeSession(transport: transport, now: { [unowned self] in self.clock },
                                   nonceSource: { [UInt8](repeating: 0x11, count: $0) })
        session.onLinkVerified = { [unowned self] _, _ in self.linkVerified += 1 }
        session.onHardwareSpectrumVerified = { [unowned self] in self.hardwareVerified += 1 }
        session.onWifiScanVerified = { [unowned self] _ in self.scansVerified += 1 }
        session.onChange = { [unowned self] in
            if self.states.last != self.session.state { self.states.append(self.session.state) }
        }
    }

    private func connect(hardware: Bool = true) throws {
        try session.connect(to: "ws://192.168.1.50:8765/snp", pairingKey: key)
        transport.onEvent?(.opened)
        transport.deliver(node.challenge(forHello: transport.sent.last!))
        transport.deliver(node.ready())
        transport.deliver(node.message(NodeMessageType.status, NodeStatus(state: "idle", hardwarePresent: hardware)))
    }

    private var request: SpectrumRequest {
        SpectrumRequest(hardwareID: "sdr0", centerFrequencyHz: 100_000_000, spanHz: 2_000_000, bins: 64)
    }

    private func assertFailed(_ contains: String? = nil, file: StaticString = #file, line: UInt = #line) {
        guard case .failed(let reason) = session.state else { return XCTFail("expected failure, state \(session.state)", file: file, line: line) }
        if let contains = contains { XCTAssertTrue(reason.contains(contains), reason, file: file, line: line) }
        XCTAssertNil(session.capabilities, file: file, line: line)
        XCTAssertNil(session.node, file: file, line: line)
    }

    // MARK: Connection preconditions

    func testStartsDisconnectedAndRequiresAddressAndKey() {
        XCTAssertEqual(session.state, .disconnected)
        for bad in ["", "http://node.local", "node.local:8765", "ws://", "ws://user:pw@node.local"] {
            XCTAssertThrowsError(try session.connect(to: bad, pairingKey: key), bad) {
                XCTAssertEqual($0 as? RadioNodeError, .invalidURL)
            }
        }
        XCTAssertThrowsError(try session.connect(to: "ws://node.local", pairingKey: [1, 2, 3])) {
            XCTAssertEqual($0 as? RadioNodeError, .pairingKeyRequired)
        }
        XCTAssertNil(transport.connectedURL, "nothing is contacted without a pairing key")
        XCTAssertThrowsError(try session.startSpectrum(request)) { XCTAssertEqual($0 as? RadioNodeError, .notConnected) }
        XCTAssertThrowsError(try session.requestWifiScan()) { XCTAssertEqual($0 as? RadioNodeError, .notConnected) }
    }

    // MARK: Handshake

    func testAuthenticatedCapabilityHandshake() throws {
        try session.connect(to: "ws://192.168.1.50:8765/snp", pairingKey: key)
        transport.onEvent?(.opened)
        XCTAssertEqual(session.state, .authenticating)
        let hello = transport.sent[0]
        XCTAssertEqual(transport.sentTypes, ["hello"])
        XCTAssertFalse(hello.contains(NodeAuth.base64(key)), "the pairing key itself is never sent")

        transport.deliver(node.challenge(forHello: hello))
        XCTAssertEqual(session.state, .awaitingReady)
        XCTAssertEqual(linkVerified, 0, "not connected until the node's authenticated ready arrives")
        XCTAssertTrue(node.clientProofIsValid(transport.sent[1]))

        transport.deliver(node.ready())
        XCTAssertEqual(session.state, .connected)
        XCTAssertTrue(session.state.isAuthenticated)
        XCTAssertEqual(linkVerified, 1)
        XCTAssertEqual(session.node?.nodeName, "bench")
        XCTAssertTrue(session.supports(NodeProtocol.wifiScanFeature))
        XCTAssertEqual(states, [.connecting, .authenticating, .awaitingReady, .connected])

        // Client session messages carry valid MACs and consecutive sequence numbers.
        XCTAssertEqual(transport.sentTypes, ["hello", "authenticate", "get_status"])
        XCTAssertEqual(node.verifyClientMessage(transport.sent[2])?.type, "get_status")
        try session.requestWifiScan()
        XCTAssertEqual(node.verifyClientMessage(transport.sent[3])?.seq, 2)
    }

    func testNodeWithWrongKeyIsNeverTrusted() throws {
        node = TestNode(key: [UInt8](repeating: 0x13, count: 32))
        try session.connect(to: "ws://node.local:1", pairingKey: key)
        transport.onEvent?(.opened)
        transport.deliver(node.challenge(forHello: transport.sent[0]))
        assertFailed("could not prove")
        XCTAssertEqual(transport.sentTypes, ["hello"], "no proof is sent to a node that failed to authenticate")
        XCTAssertEqual(linkVerified, 0)
        XCTAssertEqual(transport.closeCount, 1)
    }

    func testTamperedCapabilityReportIsRejected() throws {
        try session.connect(to: "ws://node.local:1", pairingKey: key)
        transport.onEvent?(.opened)
        var envelope = try JSONDecoder().decode(NodeEnvelope.self, from: Data(node.challenge(forHello: transport.sent[0]).utf8))
        envelope.payload = envelope.payload!.replacingOccurrences(of: "wifi_scan", with: "wifi_scam")
        transport.deliver(NodeCodec.encode(envelope))
        assertFailed("could not prove")
    }

    func testChallengeWithBadNonceOrVersionIsRejected() throws {
        try session.connect(to: "ws://node.local:1", pairingKey: key)
        transport.onEvent?(.opened)
        transport.deliver(node.challenge(forHello: transport.sent[0], protocolVersion: 1))
        assertFailed("version 1")
    }

    func testMessagesBeforeAuthenticationAreRejected() throws {
        try session.connect(to: "wss://node.example/snp", pairingKey: key)
        transport.onEvent?(.opened)
        transport.deliver(NodeCodec.encode(NodeEnvelope(type: NodeMessageType.status, payload: #"{"state":"idle","hardwarePresent":true}"#)))
        assertFailed("before the node authenticated")
        XCTAssertNil(session.status)
    }

    func testVersion1NodeIsRejected() throws {
        try session.connect(to: "ws://node.local:1", pairingKey: key)
        transport.onEvent?(.opened)
        transport.deliver(#"{"v":1,"type":"hello_ack","payload":{"protocolVersion":1,"nodeName":"old","nodeSoftware":"x","simulated":false}}"#)
        assertFailed("version 1")
    }

    func testNodeRejectionAndHandshakeTimeout() throws {
        try session.connect(to: "ws://node.local:1", pairingKey: key)
        transport.onEvent?(.opened)
        transport.deliver(NodeCodec.encode(NodeEnvelope(type: NodeMessageType.error, payload: #"{"code":"unauthorized","message":"unknown client"}"#)))
        assertFailed("unknown client")

        session.disconnect()
        XCTAssertEqual(session.state, .disconnected)
        try session.connect(to: "ws://node.local:1", pairingKey: key)
        clock = clock.addingTimeInterval(NodeProtocol.handshakeTimeout - 1)
        session.tick()
        XCTAssertEqual(session.state, .connecting)
        clock = clock.addingTimeInterval(2)
        session.tick()
        assertFailed("handshake")
    }

    func testReadyMustBeAuthenticated() throws {
        try session.connect(to: "ws://node.local:1", pairingKey: key)
        transport.onEvent?(.opened)
        transport.deliver(node.challenge(forHello: transport.sent[0]))
        transport.deliver(NodeCodec.encode(NodeEnvelope(type: NodeMessageType.ready, seq: 1, payload: "{}", mac: NodeAuth.base64([UInt8](repeating: 0, count: 32)))))
        assertFailed("integrity")
        XCTAssertEqual(linkVerified, 0)
    }

    // MARK: Session integrity

    func testUnauthenticatedSessionMessageFails() throws {
        try connect()
        transport.deliver(NodeCodec.encode(NodeEnvelope(type: NodeMessageType.status, payload: #"{"state":"idle","hardwarePresent":false}"#)))
        assertFailed("unauthenticated")
    }

    func testForgedMacFails() throws {
        try connect()
        var envelope = try JSONDecoder().decode(NodeEnvelope.self, from: Data(node.message(NodeMessageType.status, NodeStatus(state: "error", hardwarePresent: false)).utf8))
        envelope.payload = #"{"state":"idle","hardwarePresent":true}"#
        transport.deliver(NodeCodec.encode(envelope))
        assertFailed("integrity")
    }

    func testReplayedOrSkippedMessagesFail() throws {
        try connect()
        let message = node.message(NodeMessageType.pong, EmptyPayload())
        transport.deliver(message)
        XCTAssertEqual(session.state, .connected)
        transport.deliver(message)
        assertFailed("after message")

        try connect()
        node.seq += 1 // skip one
        transport.deliver(node.message(NodeMessageType.pong, EmptyPayload()))
        assertFailed("after message")
    }

    func testUnexpectedSessionMessageFails() throws {
        try connect()
        transport.deliver(node.ready())
        assertFailed("unexpected")
    }

    func testInvalidPayloadInsideAuthenticatedMessageFails() throws {
        try connect()
        transport.deliver(node.message(NodeMessageType.status, payloadText: "not json"))
        assertFailed("invalid data")
    }

    // MARK: Spectrum

    func testSpectrumRequiresFeatureHardwareAndValidRange() throws {
        try connect(hardware: false)
        XCTAssertThrowsError(try session.startSpectrum(request)) { XCTAssertEqual($0 as? RadioNodeError, .noHardware) }
        session.disconnect()

        try connect()
        var bad = request
        bad.hardwareID = "other"
        XCTAssertThrowsError(try session.startSpectrum(bad)) { XCTAssertEqual($0 as? RadioNodeError, .unknownHardware) }
        bad = request; bad.bins = 4096
        XCTAssertThrowsError(try session.startSpectrum(bad))
        bad = request; bad.spanHz = 10_000_000
        XCTAssertThrowsError(try session.startSpectrum(bad))
        bad = request; bad.centerFrequencyHz = 10_000_000
        XCTAssertThrowsError(try session.startSpectrum(bad))
        XCTAssertEqual(session.state, .connected)
        XCTAssertFalse(transport.sentTypes.contains("subscribe_spectrum"))
    }

    func testFramesFromRealHardwareVerifySpectrum() throws {
        try connect()
        transport.deliver(node.message(NodeMessageType.spectrumFrame, TestNode.frame()))
        XCTAssertNil(session.latestFrame, "frames are ignored unless a stream was requested")
        try session.startSpectrum(request)
        XCTAssertEqual(session.state, .streaming)
        transport.deliver(node.message(NodeMessageType.spectrumFrame, TestNode.frame(sequence: 1)))
        transport.deliver(node.message(NodeMessageType.spectrumFrame, TestNode.frame(sequence: 2)))
        XCTAssertEqual(session.framesReceived, 2)
        XCTAssertEqual(hardwareVerified, 1)
        session.stopSpectrum()
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(transport.sentTypes.last, "unsubscribe_spectrum")
    }

    func testSimulatedNodeNeverVerifiesHardwareOrScans() throws {
        node.info.simulated = true
        try connect()
        try session.startSpectrum(request)
        transport.deliver(node.message(NodeMessageType.spectrumFrame, TestNode.frame()))
        XCTAssertEqual(session.framesReceived, 1)
        XCTAssertTrue(session.isSimulatedNode)
        XCTAssertEqual(hardwareVerified, 0)
        try session.requestWifiScan()
        transport.deliver(node.message(NodeMessageType.wifiScan, TestNode.scan()))
        XCTAssertEqual(session.latestWifiScan?.networks.count, 2)
        XCTAssertEqual(scansVerified, 0, "simulated scan results are shown as simulated, never as verified")
    }

    func testInvalidFrameDuringStreamFailsSession() throws {
        try connect()
        try session.startSpectrum(request)
        transport.deliver(node.message(NodeMessageType.spectrumFrame, TestNode.frame(power: 500)))
        assertFailed()
        XCTAssertNil(session.latestFrame)
    }

    // MARK: Wi-Fi scan

    func testWifiScanRequestAndVerifiedResult() throws {
        try connect()
        try session.requestWifiScan()
        XCTAssertTrue(session.isWifiScanPending)
        XCTAssertThrowsError(try session.requestWifiScan()) { XCTAssertEqual($0 as? RadioNodeError, .scanInProgress) }
        transport.deliver(node.message(NodeMessageType.wifiScan, TestNode.scan()))
        XCTAssertFalse(session.isWifiScanPending)
        XCTAssertEqual(session.latestWifiScan?.networks.map { $0.bssid }, ["02:00:00:00:00:01", "02:00:00:00:00:02"])
        XCTAssertEqual(scansVerified, 1)
    }

    func testWifiScanRequiresTheFeature() throws {
        node.capabilities.features = ["spectrum", "monitor_mode", "packet_injection"]
        try connect()
        XCTAssertFalse(session.supports(NodeProtocol.wifiScanFeature))
        XCTAssertThrowsError(try session.requestWifiScan()) { XCTAssertEqual($0 as? RadioNodeError, .wifiScanUnsupported) }
        XCTAssertFalse(transport.sentTypes.contains("get_wifi_scan"))
    }

    func testUnrequestedOrCancelledScanIsIgnored() throws {
        try connect()
        transport.deliver(node.message(NodeMessageType.wifiScan, TestNode.scan()))
        XCTAssertNil(session.latestWifiScan)
        try session.requestWifiScan()
        session.cancelWifiScan()
        transport.deliver(node.message(NodeMessageType.wifiScan, TestNode.scan()))
        XCTAssertNil(session.latestWifiScan, "a late result after cancelling is not shown")
        XCTAssertEqual(scansVerified, 0)
        XCTAssertEqual(session.state, .connected)
    }

    func testWifiScanTimeoutAndNodeError() throws {
        try connect()
        try session.requestWifiScan()
        clock = clock.addingTimeInterval(NodeProtocol.requestTimeout + 1)
        session.tick()
        XCTAssertFalse(session.isWifiScanPending)
        XCTAssertTrue(session.wifiScanError?.contains("did not return") ?? false)

        try session.requestWifiScan()
        transport.deliver(node.message(NodeMessageType.error, NodeErrorPayload(code: "no_adapter", message: "No Wi-Fi adapter")))
        XCTAssertEqual(session.wifiScanError, "The node could not scan: No Wi-Fi adapter")
        XCTAssertEqual(session.state, .connected)
    }

    func testInvalidScanFailsSession() throws {
        try connect()
        try session.requestWifiScan()
        let bad = WifiNetwork(ssid: "x", bssid: "nope", channel: 6, frequencyMHz: 2437, rssiDbm: -50, security: "wpa2")
        transport.deliver(node.message(NodeMessageType.wifiScan, TestNode.scan([bad])))
        assertFailed()
        XCTAssertEqual(scansVerified, 0)
    }

    // MARK: Lifecycle

    func testDisconnectAndTransportLoss() throws {
        try connect()
        session.disconnect()
        XCTAssertEqual(session.state, .disconnected)
        XCTAssertEqual(transport.sentTypes.last, "bye")
        XCTAssertNil(session.capabilities)

        try connect()
        transport.onEvent?(.closed("going away"))
        assertFailed("going away")
        transport.deliver(node.message(NodeMessageType.status, NodeStatus(state: "idle", hardwarePresent: true)))
        XCTAssertNil(session.status)
    }

    func testSynchronousNodeResponses() throws {
        transport.responder = { [unowned self] text in
            guard let envelope = try? JSONDecoder().decode(NodeEnvelope.self, from: Data(text.utf8)) else { return [] }
            switch envelope.type {
            case "hello": return [self.node.challenge(forHello: text)]
            case "authenticate": return [self.node.ready()]
            case "get_status": return [self.node.message(NodeMessageType.status, NodeStatus(state: "idle", hardwarePresent: true))]
            case "get_wifi_scan": return [self.node.message(NodeMessageType.wifiScan, TestNode.scan())]
            default: return []
            }
        }
        try session.connect(to: "ws://127.0.0.1:8765", pairingKey: key)
        transport.onEvent?(.opened)
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.status?.hardwarePresent, true)
        try session.requestWifiScan()
        XCTAssertEqual(session.latestWifiScan?.networks.count, 2)
    }
}
