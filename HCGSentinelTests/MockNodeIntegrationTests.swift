import SentinelCore
import XCTest
@testable import HCGSentinel

/// Runs the app's real WebSocket transport and Radio Lab model against Tools/mock_radio_node.py.
///
/// Only runs when the mock node is up and its address and pairing key are provided, which CI does with
/// TEST_RUNNER_SENTINEL_NODE_URL / TEST_RUNNER_SENTINEL_NODE_KEY (xcodebuild strips the prefix):
///
///   python3 Tools/mock_radio_node.py --port 8765 --key <hex>
final class MockNodeIntegrationTests: XCTestCase {
    private var url = ""
    private var keyHex = ""

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["SENTINEL_NODE_URL"], let key = environment["SENTINEL_NODE_KEY"], !url.isEmpty, !key.isEmpty else {
            throw XCTSkip("Set SENTINEL_NODE_URL and SENTINEL_NODE_KEY and start Tools/mock_radio_node.py to run these tests.")
        }
        self.url = url
        self.keyHex = key
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 15, until condition: @escaping () -> Bool) {
        let done = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        done.expectationDescription = description
        wait(for: [done], timeout: timeout)
    }

    // MARK: Session with the app's WebSocket transport

    func testAuthenticatedHandshakeSpectrumAndWifiScanOverWebSocket() throws {
        let key = try XCTUnwrap(NodeAuth.pairingKey(fromHex: keyHex))
        let transport = WebSocketNodeTransport()
        let session = RadioNodeSession(transport: transport)
        var linkVerified = 0, hardwareVerified = 0, scansVerified = 0
        session.onLinkVerified = { _, _ in linkVerified += 1 }
        session.onHardwareSpectrumVerified = { hardwareVerified += 1 }
        session.onWifiScanVerified = { _ in scansVerified += 1 }

        try session.connect(to: url, pairingKey: key)
        waitUntil("authenticated or failed") { session.state == .connected || !session.state.isActive }
        XCTAssertEqual(session.state, .connected, "state: \(session.state)")
        XCTAssertEqual(linkVerified, 1)
        XCTAssertEqual(session.node?.nodeName, "mock-node")
        XCTAssertEqual(session.node?.simulated, true)
        XCTAssertEqual(session.capabilities?.recognizedFeatures, [NodeProtocol.spectrumFeature, NodeProtocol.wifiScanFeature])
        waitUntil("status") { session.status != nil }
        XCTAssertEqual(session.status?.hardwarePresent, true)

        let hardware = try XCTUnwrap(session.capabilities?.hardware.first)
        try session.startSpectrum(SpectrumRequest(hardwareID: hardware.id, centerFrequencyHz: 100_000_000, spanHz: 2_000_000,
                                                  bins: 64, maxFramesPerSecond: 10))
        waitUntil("two spectrum frames") { session.framesReceived >= 2 }
        XCTAssertEqual(session.latestFrame?.powers.count, 64)
        XCTAssertEqual(session.latestFrame?.unit, "dBFS")
        session.stopSpectrum()
        XCTAssertEqual(session.state, .connected)

        try session.requestWifiScan()
        waitUntil("Wi-Fi scan") { session.latestWifiScan != nil }
        let scan = try XCTUnwrap(session.latestWifiScan)
        XCTAssertEqual(scan.networks.count, 3)
        XCTAssertTrue(scan.networks.compactMap { $0.ssid }.allSatisfy { $0.hasPrefix("SIMULATED") })

        XCTAssertEqual(hardwareVerified, 0, "a simulated node never verifies radio hardware")
        XCTAssertEqual(scansVerified, 0, "a simulated node never verifies Wi-Fi discovery")

        session.disconnect()
        XCTAssertEqual(session.state, .disconnected)
    }

    func testWrongPairingKeyIsRejectedOverWebSocket() throws {
        let transport = WebSocketNodeTransport()
        let session = RadioNodeSession(transport: transport)
        var linkVerified = 0
        session.onLinkVerified = { _, _ in linkVerified += 1 }
        try session.connect(to: url, pairingKey: [UInt8](repeating: 0x13, count: 32))
        waitUntil("failure") { if case .failed = session.state { return true }; return false }
        guard case .failed(let reason) = session.state else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("could not prove"), reason)
        XCTAssertEqual(linkVerified, 0)
        XCTAssertNil(session.capabilities, "nothing from an unauthenticated node is kept")
    }

    func testUnreachableNodeFailsClearly() throws {
        let key = try XCTUnwrap(NodeAuth.pairingKey(fromHex: keyHex))
        let session = RadioNodeSession(transport: WebSocketNodeTransport())
        try session.connect(to: "ws://127.0.0.1:9/", pairingKey: key)
        waitUntil("failure", timeout: 20) { if case .failed = session.state { return true }; return false }
        XCTAssertFalse(session.state.isAuthenticated)
    }

    // MARK: The app's Radio Lab model (Keychain, settings, capability registry)

    func testRadioLabModelConnectsAndRecordsCapabilities() throws {
        let app = AppModel(store: InMemorySettingsStore())
        defer { app.radio.removePairingKey() }
        guard app.radio.setPairingKey(keyHex) else {
            throw XCTSkip("The simulator's Keychain refused the key for this unsigned test build; the session-level tests above still cover the protocol.")
        }
        app.settings.radioNodeAddress = url
        app.radio.connect()
        XCTAssertEqual(app.radio.state, .disconnected, "nothing connects while Remote connections is off")

        app.settings.remoteConnectionsEnabled = true
        app.settings.scanningEnabled = true
        XCTAssertTrue(app.radio.canConnect)
        app.radio.connect()
        waitUntil("authenticated") { app.radio.state == .connected }
        XCTAssertEqual(app.capabilityState(.radioNodeLink)?.readiness, .verified)
        XCTAssertTrue(app.radio.offersWifiScan)

        app.radio.requestWifiScan()
        waitUntil("Wi-Fi scan") { app.radio.wifiScan != nil }
        XCTAssertEqual(app.radio.wifiScan?.networks.count, 3)
        XCTAssertNotEqual(app.capabilityState(.nearbyWifiDiscovery)?.readiness, .verified, "simulated scan results verify nothing")
        XCTAssertNotEqual(app.capabilityState(.radioSpectrum)?.readiness, .verified)

        app.settings.remoteConnectionsEnabled = false
        XCTAssertEqual(app.radio.state, .disconnected, "turning Remote connections off closes the session")
        XCTAssertNotEqual(app.capabilityState(.radioNodeLink)?.readiness, .verified, "a closed session is no longer evidence")
    }
}
