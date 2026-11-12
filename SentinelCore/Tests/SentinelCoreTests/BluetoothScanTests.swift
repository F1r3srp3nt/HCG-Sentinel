import XCTest
@testable import SentinelCore

final class MockCentral: BluetoothCentral {
    weak var delegate: BluetoothCentralDelegate?
    var authorization: BluetoothAuthorization = .allowed
    var radioState: BluetoothRadioState = .unknown
    var activateCount = 0
    var startCount = 0
    var stopCount = 0
    var lastAllowDuplicates: Bool?

    func activate() { activateCount += 1 }
    func startScan(allowDuplicates: Bool) { startCount += 1; lastAllowDuplicates = allowDuplicates }
    func stopScan() { stopCount += 1 }

    func update(_ radio: BluetoothRadioState, _ authorization: BluetoothAuthorization? = nil) {
        radioState = radio
        if let authorization = authorization { self.authorization = authorization }
        delegate?.centralDidUpdate(radioState: radioState, authorization: self.authorization)
    }

    func advertise(_ advertisement: BluetoothAdvertisement) {
        delegate?.centralDidDiscover(advertisement)
    }
}

final class BluetoothScanControllerTests: XCTestCase {
    private var central: MockCentral!
    private var controller: BluetoothScanController!
    private var clock = Date(timeIntervalSince1970: 5_000)
    private var events: [String] = []

    override func setUp() {
        central = MockCentral()
        controller = BluetoothScanController(central: central, now: { [unowned self] in self.clock })
        controller.isEnabledInSettings = true
        controller.onStateEvent = { [unowned self] message, _ in self.events.append(message) }
    }

    private var isScanning: Bool {
        if case .scanning = controller.state { return true }
        return false
    }

    func testIdleUntilStartedAndBlockedWhenDisabledInSettings() {
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(central.activateCount, 0, "the Bluetooth manager must not be created before the user starts a scan")
        controller.isEnabledInSettings = false
        controller.start()
        XCTAssertEqual(controller.state, .blocked(.disabledInSettings))
        XCTAssertEqual(central.activateCount, 0)
        XCTAssertEqual(central.startCount, 0)
    }

    func testPermissionDeniedAndRestrictedDoNotActivate() {
        central.authorization = .denied
        controller.start()
        XCTAssertEqual(controller.state, .blocked(.permissionDenied))
        central.authorization = .restricted
        controller.stop()
        controller.start()
        XCTAssertEqual(controller.state, .blocked(.restricted))
        XCTAssertEqual(central.activateCount, 0)
        XCTAssertFalse(BluetoothScanBlocker.permissionDenied.guidance.isEmpty)
    }

    func testPermissionPromptFlowWaitsThenScans() {
        central.authorization = .notDetermined
        controller.start()
        XCTAssertEqual(controller.state, .waitingForRadio)
        XCTAssertEqual(central.activateCount, 1)
        XCTAssertEqual(central.startCount, 0)
        central.update(.poweredOn, .allowed)
        XCTAssertTrue(isScanning)
        XCTAssertEqual(central.startCount, 1)
        XCTAssertEqual(central.lastAllowDuplicates, false)
    }

    func testPermissionRefusedAtPrompt() {
        central.authorization = .notDetermined
        controller.start()
        central.update(.unauthorized, .denied)
        XCTAssertEqual(controller.state, .blocked(.permissionDenied))
        XCTAssertEqual(central.startCount, 0)
    }

    func testRadioStatesThatBlockScanning() {
        let cases: [(BluetoothRadioState, BluetoothScanBlocker)] = [(.poweredOff, .poweredOff), (.unsupported, .unsupported)]
        for (radio, blocker) in cases {
            central.radioState = radio
            controller.start()
            XCTAssertEqual(controller.state, .blocked(blocker))
            controller.stop()
            XCTAssertEqual(controller.state, .idle)
        }
        XCTAssertEqual(central.startCount, 0)
    }

    func testBluetoothTurnedOffDuringScanStopsIt() {
        central.radioState = .poweredOn
        controller.start()
        XCTAssertTrue(isScanning)
        central.update(.poweredOff)
        XCTAssertEqual(controller.state, .blocked(.poweredOff))
        XCTAssertEqual(central.stopCount, 1)
        central.update(.poweredOn)
        XCTAssertEqual(controller.state, .blocked(.poweredOff), "scanning must not resume without a new user action")
        XCTAssertEqual(central.startCount, 1)
    }

    func testDiscoveryMergesSightingsAndTracksLastSeen() {
        central.radioState = .poweredOn
        var firstDiscoveries = 0
        controller.onFirstDiscovery = { firstDiscoveries += 1 }
        controller.start()
        let id = UUID()
        central.advertise(BluetoothAdvertisement(identifier: id, name: "Sensor", serviceUUIDs: ["180F"], rssi: -60))
        clock = clock.addingTimeInterval(3)
        central.advertise(BluetoothAdvertisement(identifier: id, localName: "Sensor A", serviceUUIDs: ["180F", "180A"],
                                                 manufacturerID: 0x004c, isConnectable: true, rssi: 127))
        central.advertise(BluetoothAdvertisement(identifier: UUID(), rssi: -90))
        XCTAssertEqual(controller.peripherals.count, 2)
        XCTAssertEqual(firstDiscoveries, 1)
        let merged = controller.peripherals[id]
        XCTAssertEqual(merged?.displayName, "Sensor A")
        XCTAssertEqual(merged?.name, "Sensor")
        XCTAssertEqual(merged?.serviceUUIDs, ["180F", "180A"])
        XCTAssertEqual(merged?.rssi, -60, "an unavailable reading (127) must not replace a real one")
        XCTAssertEqual(merged?.sightings, 2)
        XCTAssertEqual(merged?.lastSeen.timeIntervalSince(merged!.firstSeen), 3)
        XCTAssertEqual(merged?.manufacturerID, 0x004c)
        XCTAssertEqual(controller.sortedPeripherals.count, 2)
        let unnamed = controller.sortedPeripherals.first { $0.id != id }
        XCTAssertEqual(unnamed?.displayName, "Unnamed device")
        XCTAssertEqual(unnamed?.signalBars, 1)
    }

    func testAdvertisementsAreIgnoredUnlessScanning() {
        central.advertise(BluetoothAdvertisement(identifier: UUID(), rssi: -50))
        XCTAssertTrue(controller.peripherals.isEmpty)
        central.radioState = .poweredOn
        controller.start()
        controller.stop()
        central.advertise(BluetoothAdvertisement(identifier: UUID(), rssi: -50))
        XCTAssertTrue(controller.peripherals.isEmpty)
    }

    func testStopKeepsResultsUntilCleared() {
        central.radioState = .poweredOn
        controller.start()
        central.advertise(BluetoothAdvertisement(identifier: UUID(), rssi: -50))
        controller.stop()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(central.stopCount, 1)
        XCTAssertEqual(controller.peripherals.count, 1)
        controller.clearResults()
        XCTAssertTrue(controller.peripherals.isEmpty)
        controller.stop()
        XCTAssertEqual(central.stopCount, 1, "stopping twice must not call the platform again")
    }

    func testAutoStopAtTimeLimit() {
        central.radioState = .poweredOn
        controller.autoStopInterval = 30
        controller.start()
        clock = clock.addingTimeInterval(29)
        controller.tick()
        XCTAssertTrue(isScanning)
        clock = clock.addingTimeInterval(2)
        controller.tick()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(central.stopCount, 1)
        XCTAssertTrue(events.last?.contains("automatically") ?? false)
    }

    func testNoTimeLimitWhenIntervalIsZero() {
        central.radioState = .poweredOn
        controller.autoStopInterval = 0
        controller.allowDuplicates = true
        controller.start()
        XCTAssertNil(controller.autoStopDeadline)
        XCTAssertEqual(central.lastAllowDuplicates, true)
        clock = clock.addingTimeInterval(100_000)
        controller.tick()
        XCTAssertTrue(isScanning)
    }

    func testPeripheralListIsBounded() {
        central.radioState = .poweredOn
        controller.start()
        for _ in 0..<(BluetoothScanController.maxPeripherals + 25) {
            clock = clock.addingTimeInterval(0.01)
            central.advertise(BluetoothAdvertisement(identifier: UUID(), rssi: -70))
        }
        XCTAssertEqual(controller.peripherals.count, BluetoothScanController.maxPeripherals)
    }

    func testSignalDescriptionsNeverMentionDistance() {
        for rssi in [-40, -65, -80, -100] {
            let peripheral = DiscoveredPeripheral(id: UUID(), rssi: rssi, firstSeen: clock, lastSeen: clock, sightings: 1)
            XCTAssertTrue(peripheral.signalDescription.contains("signal"))
            XCTAssertFalse(peripheral.signalDescription.lowercased().contains("m away"))
        }
        XCTAssertEqual(DiscoveredPeripheral(id: UUID(), rssi: nil, firstSeen: clock, lastSeen: clock, sightings: 1).signalBars, 0)
    }
}
