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
        XCTAssertEqual(unnamed?.displayName, "Name not broadcast")
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

final class BluetoothDiscoveryQualityTests: XCTestCase {
    private var central: MockCentral!
    private var controller: BluetoothScanController!
    private var clock = Date(timeIntervalSince1970: 9_000)

    override func setUp() {
        central = MockCentral()
        central.radioState = .poweredOn
        controller = BluetoothScanController(central: central, now: { [unowned self] in self.clock })
        controller.isEnabledInSettings = true
    }

    func testLaterAdvertisementsNeverEraseKnownInformation() {
        controller.start()
        let id = UUID()
        central.advertise(BluetoothAdvertisement(identifier: id, name: "HR Strap", localName: "Polar H10", serviceUUIDs: ["180D"],
                                                 manufacturerID: 0x006B, manufacturerDataLength: 4, isConnectable: true, txPower: -4,
                                                 rssi: -61, manufacturerData: [0x6B, 0x00, 0x01, 0x02],
                                                 serviceData: ["180D": [0x10]], overflowServiceUUIDs: ["180F"]))
        clock = clock.addingTimeInterval(1)
        // A scan response or later advertisement that carries less: empty and missing fields.
        central.advertise(BluetoothAdvertisement(identifier: id, name: "", localName: "   ", rssi: 127))
        clock = clock.addingTimeInterval(1)
        central.advertise(BluetoothAdvertisement(identifier: id, serviceUUIDs: ["180A"], rssi: -70))
        let device = controller.peripherals[id]!
        XCTAssertEqual(device.localName, "Polar H10", "an empty or blank name must not erase a known one")
        XCTAssertEqual(device.name, "HR Strap")
        XCTAssertEqual(device.serviceUUIDs, ["180D", "180A"])
        XCTAssertEqual(device.allServiceUUIDs, ["180D", "180A", "180F"])
        XCTAssertEqual(device.manufacturerData, [0x6B, 0x00, 0x01, 0x02])
        XCTAssertEqual(device.serviceData["180D"], [0x10])
        XCTAssertEqual(device.isConnectable, true)
        XCTAssertEqual(device.txPower, -4)
        XCTAssertEqual(device.rssi, -70)
        XCTAssertEqual(device.recentRSSI, [-61, -70], "unavailable readings are not recorded")
        XCTAssertEqual(device.rssiRange, -70 ... -61)
        XCTAssertEqual(device.rssiAt, clock)
        XCTAssertEqual(device.sightings, 3)
        XCTAssertEqual(controller.peripherals.count, 1, "observations are deduplicated by the identifier iOS provides")
    }

    func testNameSources() {
        let base = DiscoveredPeripheral(id: UUID(), rssi: nil, firstSeen: clock, lastSeen: clock, sightings: 1)
        XCTAssertEqual(base.nameSource(label: nil), .notBroadcast)
        XCTAssertEqual(base.nameSource(label: nil).text, "Name not broadcast")
        XCTAssertTrue(base.nameSource(label: nil).explanation.contains("says nothing about"))
        var named = base
        named.name = "Cached"
        XCTAssertEqual(named.nameSource(label: nil), .system("Cached"))
        named.localName = "Advertised"
        XCTAssertEqual(named.nameSource(label: nil), .advertised("Advertised"))
        XCTAssertEqual(named.nameSource(label: "  Kitchen sensor "), .userLabel("Kitchen sensor"))
        XCTAssertEqual(named.nameSource(label: "   "), .advertised("Advertised"))
        XCTAssertFalse(base.hasBroadcastName)
        XCTAssertTrue(named.hasBroadcastName)
    }

    func testScanSessionsAcrossStopAndRestart() {
        controller.start()
        XCTAssertEqual(controller.scanNumber, 1)
        let a = UUID(), b = UUID()
        central.advertise(BluetoothAdvertisement(identifier: a, rssi: -50))
        central.advertise(BluetoothAdvertisement(identifier: a, rssi: -52))
        central.advertise(BluetoothAdvertisement(identifier: b, rssi: -80))
        controller.stop()
        XCTAssertEqual(central.stopCount, 1)
        central.advertise(BluetoothAdvertisement(identifier: b, rssi: -60))
        XCTAssertEqual(controller.peripherals[b]?.rssi, -80, "nothing is recorded while stopped")

        controller.start()
        XCTAssertEqual(controller.scanNumber, 2)
        XCTAssertEqual(central.startCount, 2)
        central.advertise(BluetoothAdvertisement(identifier: b, rssi: -65))
        XCTAssertEqual(controller.peripherals[a]?.lastScan, 1, "kept from the earlier scan")
        XCTAssertEqual(controller.peripherals[a]?.sightingsInLastScan, 2)
        XCTAssertEqual(controller.peripherals[b]?.lastScan, 2)
        XCTAssertEqual(controller.peripherals[b]?.sightingsInLastScan, 1)
        XCTAssertEqual(controller.peripherals[b]?.sightings, 2)

        var filter = BluetoothDeviceFilter()
        filter.currentScanOnly = true
        XCTAssertEqual(filter.apply(controller.sortedPeripherals, labels: [:], currentScan: controller.scanNumber).map { $0.id }, [b])
    }

    func testRestartAfterBluetoothBecomesAvailableAgain() {
        controller.start()
        central.update(.poweredOff)
        XCTAssertEqual(controller.state, .blocked(.poweredOff))
        central.update(.poweredOn)
        XCTAssertEqual(controller.state, .blocked(.poweredOff), "no automatic restart")
        controller.stop()
        controller.start()
        if case .scanning = controller.state {} else { XCTFail("a new user start scans again: \(controller.state)") }
        XCTAssertEqual(controller.scanNumber, 2)
    }

    func testUnavailableBluetoothNeverYieldsResults() {
        central.radioState = .unsupported
        controller.start()
        XCTAssertEqual(controller.state, .blocked(.unsupported))
        central.advertise(BluetoothAdvertisement(identifier: UUID(), localName: "Ghost", rssi: -40))
        XCTAssertTrue(controller.peripherals.isEmpty)
        XCTAssertEqual(controller.scanNumber, 0)
        XCTAssertEqual(central.startCount, 0)
    }

    func testFiltersAndSorting() {
        let now = clock
        func device(_ rssi: Int?, local: String? = nil, services: [String] = [], connectable: Bool? = nil, ago: TimeInterval) -> DiscoveredPeripheral {
            var d = DiscoveredPeripheral(id: UUID(), localName: local, serviceUUIDs: services, isConnectable: connectable, rssi: rssi,
                                         firstSeen: now, lastSeen: now.addingTimeInterval(-ago), sightings: 1)
            d.lastScan = 1
            return d
        }
        let heart = device(-55, local: "Watch", services: ["180D"], connectable: true, ago: 5)
        let quiet = device(-90, ago: 1)
        let silent = device(nil, local: "beacon", ago: 30)
        let all = [heart, quiet, silent]
        var filter = BluetoothDeviceFilter()
        XCTAssertFalse(filter.isActive)
        XCTAssertEqual(filter.apply(all, labels: [:], currentScan: 1).map { $0.id }, [quiet.id, heart.id, silent.id])
        filter.sort = .signal
        XCTAssertFalse(filter.isActive, "sorting alone is not filtering")
        XCTAssertEqual(filter.apply(all, labels: [:], currentScan: 1).map { $0.id }, [heart.id, quiet.id, silent.id])
        filter.sort = .name
        XCTAssertEqual(filter.apply(all, labels: [quiet.id: "Desk"], currentScan: 1).map { $0.id }, [silent.id, quiet.id, heart.id],
                       "named devices first, alphabetically; unnamed last")
        filter = BluetoothDeviceFilter()
        filter.namedOnly = true
        XCTAssertEqual(Set(filter.apply(all, labels: [:], currentScan: 1).map { $0.id }), [heart.id, silent.id])
        filter = BluetoothDeviceFilter()
        filter.minimumRSSI = -70
        XCTAssertEqual(filter.apply(all, labels: [:], currentScan: 1).map { $0.id }, [heart.id])
        filter = BluetoothDeviceFilter()
        filter.text = "heart rate"
        XCTAssertEqual(filter.apply(all, labels: [:], currentScan: 1).map { $0.id }, [heart.id], "service names are searchable")
        filter.text = "desk"
        XCTAssertEqual(filter.apply(all, labels: [quiet.id: "Desk"], currentScan: 1).map { $0.id }, [quiet.id])
        filter = BluetoothDeviceFilter()
        filter.connectableOnly = true
        filter.withServicesOnly = true
        XCTAssertEqual(filter.apply(all, labels: [:], currentScan: 1).map { $0.id }, [heart.id])
        filter = BluetoothDeviceFilter()
        filter.labelledOnly = true
        XCTAssertEqual(filter.apply(all, labels: [silent.id: "Mine"], currentScan: 1).map { $0.id }, [silent.id])
    }

    func testAssignedNumbersDescribeFieldsNotDevices() {
        XCTAssertEqual(BluetoothAssignedNumbers.companyLabel(0x004C), "Apple (0x004C)")
        XCTAssertEqual(BluetoothAssignedNumbers.companyLabel(0x1234), "0x1234 (not in Sentinel's short list)")
        XCTAssertEqual(BluetoothAssignedNumbers.serviceLabel("180f"), "Battery (180f)")
        XCTAssertEqual(BluetoothAssignedNumbers.serviceLabel("6E400001-B5A3-F393-E0A9-E50E24DCCA9E"), "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        XCTAssertEqual(BluetoothAssignedNumbers.hex([0x4C, 0x00, 0x12]), "4C 00 12")
        XCTAssertTrue(BluetoothAssignedNumbers.hex(Array(repeating: 1, count: 40)).hasSuffix("…"))
    }

    func testLabelsPersistPerIdentifier() {
        let suite = "sentinel.tests.labels.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let store = BluetoothLabelStore(defaults: defaults)
        XCTAssertTrue(store.set("  Office speaker  ", for: id))
        XCTAssertEqual(BluetoothLabelStore(defaults: defaults).labels[id], "Office speaker", "labels survive a relaunch")
        store.set("", for: id)
        XCTAssertNil(BluetoothLabelStore(defaults: defaults).labels[id], "a blank label removes it")
        for _ in 0..<BluetoothLabelStore.maxLabels { store.set("x", for: UUID()) }
        XCTAssertFalse(store.set("one too many", for: UUID()))
        store.removeAll()
        XCTAssertTrue(BluetoothLabelStore(defaults: defaults).labels.isEmpty)
    }

    func testAdvertisementDataIsCapped() {
        let ad = BluetoothAdvertisement(identifier: UUID(), rssi: -50, manufacturerData: Array(repeating: 7, count: 300),
                                        serviceData: ["FEAA": Array(repeating: 1, count: 100)])
        XCTAssertEqual(ad.manufacturerData?.count, 64)
        XCTAssertEqual(ad.serviceData["FEAA"]?.count, 32)
        XCTAssertEqual(BluetoothAdvertisement.clean(String(repeating: "n", count: 200))?.count, 64)
    }
}
