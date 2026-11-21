import XCTest
@testable import SentinelCore

/// 0.1.0~beta2: a scan that iOS never answers ends with the real state instead of "Starting…" forever; what happened is
/// recorded; a scan stops when Sentinel leaves the foreground; continuous updates are on by default.
final class BluetoothBeta2Tests: XCTestCase {
    private var central: MockCentral!
    private var controller: BluetoothScanController!
    private var clock = Date(timeIntervalSince1970: 9_000)

    override func setUp() {
        central = MockCentral()
        controller = BluetoothScanController(central: central, now: { [unowned self] in self.clock })
        controller.isEnabledInSettings = true
    }

    func testWaitingForRadioEndsWithTheLastReportedStateAfterTheLimit() {
        central.authorization = .notDetermined
        controller.start()
        XCTAssertEqual(controller.state, .waitingForRadio)
        clock = clock.addingTimeInterval(BluetoothScanController.radioWaitLimit - 1)
        controller.tick()
        XCTAssertEqual(controller.state, .waitingForRadio, "the permission prompt may still be on screen")
        clock = clock.addingTimeInterval(2)
        controller.tick()
        XCTAssertEqual(controller.state, .blocked(.noResponse(lastState: .unknown, authorization: .notDetermined)))
        let status = BluetoothScreenStatus.derive(state: controller.state, scanningEnabled: true, heardThisScan: 0, listed: 0, now: clock)
        XCTAssertEqual(status.kind, .noResponse)
        XCTAssertTrue(status.isProblem)
        XCTAssertEqual(status.primaryAction, .start)
        XCTAssertTrue(status.detail.contains("unknown") && status.detail.contains("notDetermined"), status.detail)
        XCTAssertEqual(central.startCount, 0, "no scan was ever started on the platform")
    }

    func testPoweredOnBeforeTheLimitStartsTheScanAndClearsTheWatchdog() {
        controller.start()
        clock = clock.addingTimeInterval(5)
        central.update(.poweredOn, .allowed)
        guard case .scanning = controller.state else { return XCTFail("expected scanning, got \(controller.state)") }
        clock = clock.addingTimeInterval(BluetoothScanController.radioWaitLimit * 2)
        controller.autoStopInterval = 0
        controller.tick()
        guard case .scanning = controller.state else { return XCTFail("the watchdog must not end a running scan") }
    }

    func testAStartAfterNoResponseWaitsAFreshInterval() {
        controller.start()
        clock = clock.addingTimeInterval(BluetoothScanController.radioWaitLimit + 1)
        controller.tick()
        guard case .blocked(.noResponse) = controller.state else { return XCTFail("\(controller.state)") }
        controller.start()
        XCTAssertEqual(controller.state, .waitingForRadio)
        clock = clock.addingTimeInterval(1)
        controller.tick()
        XCTAssertEqual(controller.state, .waitingForRadio, "the new attempt gets its own full interval")
    }

    func testDiagnosticsRecordWhatHappenedWithoutDeviceData() {
        controller.allowDuplicates = true
        controller.start()
        central.update(.poweredOn, .allowed)
        let id = UUID()
        central.advertise(BluetoothAdvertisement(identifier: id, localName: "Kitchen Sensor", rssi: -60))
        central.advertise(BluetoothAdvertisement(identifier: id, rssi: -61))
        let d = controller.diagnostics
        XCTAssertNotNil(d.managerRequestedAt)
        XCTAssertEqual(d.stateUpdates, 1)
        XCTAssertEqual(d.lastRadioState, .poweredOn)
        XCTAssertEqual(d.lastAuthorization, .allowed)
        XCTAssertEqual(d.advertisementsThisScan, 2)
        XCTAssertEqual(d.advertisementsTotal, 2)
        XCTAssertTrue(d.allowDuplicates)
        let report = d.report(now: clock)
        XCTAssertTrue(report.contains("poweredOn"))
        XCTAssertFalse(report.contains("Kitchen"), "no advertisement contents in the report")
        XCTAssertFalse(report.contains(id.uuidString), "no device identifiers in the report")
    }

    func testDiagnosticsRecordARefusalAndTheEventListIsBounded() {
        controller.isEnabledInSettings = false
        for _ in 0..<(BluetoothDiagnostics.maxEvents + 10) { controller.start(); controller.stop() }
        XCTAssertEqual(controller.diagnostics.events.count, BluetoothDiagnostics.maxEvents)
        XCTAssertEqual(controller.diagnostics.lastProblem?.hasPrefix("Scanning is off"), true)
    }

    func testBackgroundStopsAnActiveScanOnly() {
        controller.appDidEnterBackground()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(central.stopCount, 0)
        central.radioState = .poweredOn
        controller.start()
        controller.appDidEnterBackground()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(central.stopCount, 1)
        XCTAssertTrue(controller.diagnostics.events.last?.text.contains("background") ?? false)
    }

    func testContinuousUpdatesDefaultAndBeta1Migration() throws {
        XCTAssertTrue(SentinelSettings().bluetoothContinuousUpdates)
        XCTAssertFalse(SentinelSettings().scanningEnabled, "scanning itself stays off until the user turns it on")
        // beta1 stored every field, with continuous updates off, and no schema version.
        let beta1 = #"{"scanningEnabled":true,"bluetoothContinuousUpdates":false,"bluetoothAutoStopSeconds":120}"#
        let migrated = try JSONDecoder().decode(SentinelSettings.self, from: Data(beta1.utf8))
        XCTAssertTrue(migrated.bluetoothContinuousUpdates)
        XCTAssertTrue(migrated.scanningEnabled, "other choices are kept")
        XCTAssertEqual(migrated.bluetoothAutoStopSeconds, 120)
        XCTAssertEqual(migrated.schemaVersion, SentinelSettings.currentSchemaVersion)
        // A choice made in beta2 or later is kept.
        var chosen = SentinelSettings()
        chosen.bluetoothContinuousUpdates = false
        let roundTrip = try JSONDecoder().decode(SentinelSettings.self, from: JSONEncoder().encode(chosen))
        XCTAssertFalse(roundTrip.bluetoothContinuousUpdates)
    }
}
