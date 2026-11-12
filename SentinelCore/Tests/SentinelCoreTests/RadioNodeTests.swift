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

    func deliver(_ json: String) { onEvent?(.text(json)) }
    var sentTypes: [String] {
        sent.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["type"] as? String }
    }
}

enum NodeFixtures {
    static func helloAck(simulated: Bool = false, version: Int = 1) -> String {
        #"{"v":1,"type":"hello_ack","payload":{"protocolVersion":\#(version),"nodeName":"bench","nodeSoftware":"sentinel-node 0.1","simulated":\#(simulated)}}"#
    }
    static func capabilities(features: String = #"["spectrum"]"#, hardware: Bool = true) -> String {
        let radios = hardware ? #"[{"id":"sdr0","driver":"rtlsdr","description":"Test SDR","minFrequencyHz":24000000,"maxFrequencyHz":1766000000,"maxSpanHz":2400000}]"# : "[]"
        return #"{"v":1,"type":"capabilities","payload":{"features":\#(features),"hardware":\#(radios),"maxBins":2048}}"#
    }
    static func status(hardwarePresent: Bool = true) -> String {
        #"{"v":1,"type":"status","payload":{"state":"idle","hardwarePresent":\#(hardwarePresent)}}"#
    }
    static func frame(sequence: Int = 1, bins: Int = 64, unit: String = "dBFS", power: String = "-80.5") -> String {
        let powers = Array(repeating: power, count: bins).joined(separator: ",")
        return #"{"v":1,"type":"spectrum_frame","payload":{"sequence":\#(sequence),"timestamp":1700000000.5,"centerFrequencyHz":100000000,"spanHz":2000000,"unit":"\#(unit)","powers":[\#(powers)]}}"#
    }
}

final class NodeCodecTests: XCTestCase {
    func testEncodesVersionedEnvelopes() throws {
        let hello = ClientHello(protocolVersions: [1], client: "HCG Sentinel", clientVersion: "1.0", authToken: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(NodeCodec.encode(.hello(hello), id: "c1").utf8)) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["type"] as? String, "hello")
        XCTAssertEqual(object["id"] as? String, "c1")
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["protocolVersions"] as? [Int], [1])
        XCTAssertNil(payload["authToken"])
        XCTAssertEqual(NodeCodec.encode(.ping), #"{"type":"ping","v":1}"#)
        XCTAssertTrue(NodeCodec.encode(.subscribeSpectrum(SpectrumRequest(hardwareID: "sdr0", centerFrequencyHz: 1e8, spanHz: 2e6))).contains("subscribe_spectrum"))
    }

    func testDecodesEveryNodeMessage() throws {
        guard case .helloAck(let ack) = try NodeCodec.decode(NodeFixtures.helloAck(simulated: true)) else { return XCTFail() }
        XCTAssertTrue(ack.simulated)
        guard case .capabilities(let capabilities) = try NodeCodec.decode(NodeFixtures.capabilities()) else { return XCTFail() }
        XCTAssertEqual(capabilities.hardware.first?.id, "sdr0")
        guard case .status(let status) = try NodeCodec.decode(NodeFixtures.status(hardwarePresent: false)) else { return XCTFail() }
        XCTAssertFalse(status.hardwarePresent)
        guard case .spectrumFrame(let frame) = try NodeCodec.decode(NodeFixtures.frame(bins: 32)) else { return XCTFail() }
        XCTAssertEqual(frame.powers.count, 32)
        XCTAssertEqual(try NodeCodec.decode(#"{"v":1,"type":"pong"}"#), .pong)
        XCTAssertEqual(try NodeCodec.decode(#"{"v":1,"type":"error","payload":{"code":"busy","message":"in use"}}"#),
                       .error(NodeErrorPayload(code: "busy", message: "in use")))
    }

    func testRejectsMalformedMessages() {
        func error(_ text: String) -> NodeProtocolError? {
            do { _ = try NodeCodec.decode(text); return nil } catch { return error as? NodeProtocolError }
        }
        XCTAssertEqual(error("not json"), .notJSON)
        XCTAssertEqual(error("[1,2,3]"), .notJSON)
        XCTAssertEqual(error(#"{"type":"pong"}"#), .notJSON)
        XCTAssertEqual(error(#"{"v":2,"type":"pong"}"#), .unsupportedVersion(2))
        XCTAssertEqual(error(#"{"v":1,"type":"transmit","payload":{}}"#), .unknownType("transmit"))
        XCTAssertEqual(error(#"{"v":1,"type":"status"}"#), .missingPayload("status"))
        XCTAssertEqual(error(NodeFixtures.helloAck(version: 3)), .unsupportedVersion(3))
        guard case .invalidPayload? = error(#"{"v":1,"type":"status","payload":{"state":5}}"#) else { return XCTFail() }
        guard case .invalidPayload? = error(NodeFixtures.frame(bins: 4)) else { return XCTFail("too few bins") }
        guard case .invalidPayload? = error(NodeFixtures.frame(bins: NodeProtocol.maxBins + 1)) else { return XCTFail("too many bins") }
        guard case .invalidPayload? = error(NodeFixtures.frame(unit: "volts")) else { return XCTFail("unit") }
        guard case .invalidPayload? = error(NodeFixtures.frame(power: "1e9")) else { return XCTFail("range") }
        let oversized = #"{"v":1,"type":"pong","pad":""# + String(repeating: "x", count: NodeProtocol.maxMessageBytes) + #""}"#
        guard case .messageTooLarge? = error(oversized) else { return XCTFail("size") }
    }
}

final class RadioNodeSessionTests: XCTestCase {
    private var transport: MockNodeTransport!
    private var session: RadioNodeSession!
    private var clock = Date(timeIntervalSince1970: 9_000)
    private var linkVerified = 0
    private var hardwareVerified = 0

    override func setUp() {
        transport = MockNodeTransport()
        session = RadioNodeSession(transport: transport, now: { [unowned self] in self.clock })
        session.onLinkVerified = { [unowned self] _ in self.linkVerified += 1 }
        session.onHardwareSpectrumVerified = { [unowned self] in self.hardwareVerified += 1 }
    }

    private func connect(simulated: Bool = false, hardware: Bool = true) throws {
        try session.connect(to: "ws://192.168.1.50:8765/snp", authToken: "pairing-token")
        transport.onEvent?(.opened)
        transport.deliver(NodeFixtures.helloAck(simulated: simulated))
        transport.deliver(NodeFixtures.capabilities(hardware: hardware))
        transport.deliver(NodeFixtures.status(hardwarePresent: hardware))
    }

    private var request: SpectrumRequest {
        SpectrumRequest(hardwareID: "sdr0", centerFrequencyHz: 100_000_000, spanHz: 2_000_000, bins: 64)
    }

    func testStartsDisconnectedAndValidatesAddress() {
        XCTAssertEqual(session.state, .disconnected)
        XCTAssertNil(session.latestFrame)
        for bad in ["", "http://node.local", "node.local:8765", "ws://", "ws://user:pw@node.local"] {
            XCTAssertThrowsError(try session.connect(to: bad, authToken: nil), bad) {
                XCTAssertEqual($0 as? RadioNodeError, .invalidURL)
            }
        }
        XCTAssertNil(transport.connectedURL)
        XCTAssertThrowsError(try session.startSpectrum(request)) { XCTAssertEqual($0 as? RadioNodeError, .notConnected) }
    }

    func testHandshakeSendsHelloThenQueriesNode() throws {
        try connect()
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(transport.connectedURL?.absoluteString, "ws://192.168.1.50:8765/snp")
        XCTAssertEqual(transport.sentTypes, ["hello", "get_capabilities", "get_status"])
        XCTAssertTrue(transport.sent[0].contains("pairing-token"))
        XCTAssertEqual(session.node?.nodeName, "bench")
        XCTAssertEqual(session.capabilities?.maxBins, 2048)
        XCTAssertEqual(linkVerified, 1)
        XCTAssertEqual(hardwareVerified, 0, "a handshake alone proves nothing about radio hardware")
    }

    func testDataBeforeHandshakeFailsTheSession() throws {
        try session.connect(to: "wss://node.example/snp", authToken: nil)
        transport.onEvent?(.opened)
        transport.deliver(NodeFixtures.frame())
        guard case .failed = session.state else { return XCTFail("expected failure") }
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertEqual(linkVerified, 0)
        XCTAssertNil(session.latestFrame)
    }

    func testUnsupportedProtocolVersionIsRejected() throws {
        try session.connect(to: "ws://node.local:1", authToken: nil)
        transport.onEvent?(.opened)
        transport.deliver(NodeFixtures.helloAck(version: 2))
        guard case .failed(let reason) = session.state else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("version 2"))
    }

    func testNodeRejectionAndHandshakeTimeout() throws {
        try session.connect(to: "ws://node.local:1", authToken: nil)
        transport.onEvent?(.opened)
        transport.deliver(#"{"v":1,"type":"error","payload":{"code":"unauthorized","message":"bad token"}}"#)
        guard case .failed(let reason) = session.state else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("bad token"))

        session.disconnect()
        XCTAssertEqual(session.state, .disconnected)
        try session.connect(to: "ws://node.local:1", authToken: nil)
        clock = clock.addingTimeInterval(NodeProtocol.handshakeTimeout - 1)
        session.tick()
        XCTAssertEqual(session.state, .connecting)
        clock = clock.addingTimeInterval(2)
        session.tick()
        guard case .failed = session.state else { return XCTFail("expected timeout") }
    }

    func testSpectrumRequiresFeatureHardwareAndValidRange() throws {
        try connect(hardware: false)
        XCTAssertThrowsError(try session.startSpectrum(request)) { XCTAssertEqual($0 as? RadioNodeError, .noHardware) }
        session.disconnect()

        try connect()
        var bad = request
        bad.hardwareID = "other"
        XCTAssertThrowsError(try session.startSpectrum(bad)) { XCTAssertEqual($0 as? RadioNodeError, .unknownHardware) }
        bad = request
        bad.bins = 4096
        XCTAssertThrowsError(try session.startSpectrum(bad))
        bad = request
        bad.spanHz = 10_000_000
        XCTAssertThrowsError(try session.startSpectrum(bad))
        bad = request
        bad.centerFrequencyHz = 10_000_000
        XCTAssertThrowsError(try session.startSpectrum(bad))
        XCTAssertEqual(session.state, .connected)
        XCTAssertFalse(transport.sentTypes.contains("subscribe_spectrum"))

        transport.deliver(NodeFixtures.capabilities(features: "[]"))
        XCTAssertThrowsError(try session.startSpectrum(request)) { XCTAssertEqual($0 as? RadioNodeError, .spectrumUnsupported) }
    }

    func testFramesFromRealHardwareVerifySpectrum() throws {
        try connect()
        transport.deliver(NodeFixtures.frame())
        XCTAssertNil(session.latestFrame, "frames are ignored unless a stream was requested")
        try session.startSpectrum(request)
        XCTAssertEqual(session.state, .streaming)
        transport.deliver(NodeFixtures.frame(sequence: 1))
        transport.deliver(NodeFixtures.frame(sequence: 2))
        XCTAssertEqual(session.framesReceived, 2)
        XCTAssertEqual(session.latestFrame?.sequence, 2)
        XCTAssertEqual(hardwareVerified, 1)
        session.stopSpectrum()
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(transport.sentTypes.last, "unsubscribe_spectrum")
        transport.deliver(NodeFixtures.frame(sequence: 3))
        XCTAssertEqual(session.framesReceived, 2)
    }

    func testSimulatedNodeNeverVerifiesHardware() throws {
        try connect(simulated: true)
        try session.startSpectrum(request)
        transport.deliver(NodeFixtures.frame())
        XCTAssertEqual(session.framesReceived, 1)
        XCTAssertTrue(session.isSimulatedNode)
        XCTAssertEqual(hardwareVerified, 0)
    }

    func testInvalidFrameDuringStreamFailsSession() throws {
        try connect()
        try session.startSpectrum(request)
        transport.deliver(NodeFixtures.frame(power: "500"))
        guard case .failed = session.state else { return XCTFail("expected failure") }
        XCTAssertNil(session.latestFrame)
        XCTAssertNil(session.node)
    }

    func testDisconnectAndTransportLoss() throws {
        try connect()
        session.disconnect()
        XCTAssertEqual(session.state, .disconnected)
        XCTAssertEqual(transport.sentTypes.last, "bye")
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertNil(session.capabilities)

        try connect()
        transport.onEvent?(.closed("going away"))
        guard case .failed(let reason) = session.state else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("going away"))
        transport.deliver(NodeFixtures.frame())
        XCTAssertNil(session.latestFrame)
    }

    func testSynchronousNodeResponses() throws {
        transport.responder = { text in
            if text.contains(#""type":"hello""#) { return [NodeFixtures.helloAck()] }
            if text.contains("get_capabilities") { return [NodeFixtures.capabilities()] }
            if text.contains("get_status") { return [NodeFixtures.status()] }
            if text.contains("subscribe_spectrum") && !text.contains("unsubscribe") { return [NodeFixtures.frame()] }
            return []
        }
        try session.connect(to: "ws://127.0.0.1:8765", authToken: nil)
        transport.onEvent?(.opened)
        XCTAssertEqual(session.state, .connected)
        try session.startSpectrum(request)
        XCTAssertEqual(session.framesReceived, 1)
    }
}
