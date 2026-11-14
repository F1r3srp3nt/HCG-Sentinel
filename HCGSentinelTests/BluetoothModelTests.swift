import SentinelCore
import XCTest
@testable import HCGSentinel

private final class FakeCentral: BluetoothCentral {
    weak var delegate: BluetoothCentralDelegate?
    var authorization: BluetoothAuthorization = .allowed
    var radioState: BluetoothRadioState = .poweredOn
    var scanning = false
    func activate() {}
    func startScan(allowDuplicates: Bool) { scanning = true }
    func stopScan() { scanning = false }
    func advertise(_ ad: BluetoothAdvertisement) { delegate?.centralDidDiscover(ad) }
    func update(_ radio: BluetoothRadioState, _ auth: BluetoothAuthorization? = nil) {
        radioState = radio
        if let auth = auth { authorization = auth }
        delegate?.centralDidUpdate(radioState: radio, authorization: authorization)
    }
}

/// Bluetooth Explorer's model with a fake radio. These are fixture tests: no real Bluetooth is involved.
final class BluetoothModelTests: XCTestCase {
    private var central: FakeCentral!
    private var model: BluetoothModel!
    private var registry: CapabilityRegistry!
    private var defaults: UserDefaults!
    private let suite = "sentinel.tests.bluetooth.\(UUID().uuidString)"

    override func setUp() {
        central = FakeCentral()
        registry = CapabilityRegistry()
        registry.setUserEnabled(.bluetoothDiscovery, true)
        defaults = UserDefaults(suiteName: suite)
        model = BluetoothModel(central: central, log: ActivityLog(), registry: registry, labelStore: BluetoothLabelStore(defaults: defaults))
        var settings = SentinelSettings()
        settings.scanningEnabled = true
        model.apply(settings)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func waitForPublish() {
        let published = expectation(description: "list published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { published.fulfill() }
        wait(for: [published], timeout: 2)
    }

    func testScanStopRestartAndLabels() {
        model.start()
        XCTAssertTrue(central.scanning)
        let named = UUID(), unnamed = UUID()
        central.advertise(BluetoothAdvertisement(identifier: named, localName: "Thermometer", serviceUUIDs: ["181A"], rssi: -58))
        central.advertise(BluetoothAdvertisement(identifier: unnamed, manufacturerID: 0x004C, manufacturerDataLength: 6, rssi: -83,
                                                 manufacturerData: [0x4C, 0x00, 0x10, 0x05, 0x01, 0x18]))
        waitForPublish()
        XCTAssertEqual(model.peripherals.count, 2)
        XCTAssertEqual(model.scanNumber, 1)
        XCTAssertEqual(registry.state(.bluetoothDiscovery)?.readiness, .verified, "verified only by a received advertisement")
        let silent = model.peripherals.first { $0.id == unnamed }!
        XCTAssertEqual(model.nameSource(silent), .notBroadcast)
        XCTAssertEqual(model.nameSource(silent).text, "Name not broadcast")

        model.setLabel("Hallway tag", for: unnamed)
        XCTAssertEqual(model.nameSource(silent), .userLabel("Hallway tag"))
        model.filter.labelledOnly = true
        XCTAssertEqual(model.visiblePeripherals.map { $0.id }, [unnamed])
        model.filter = BluetoothDeviceFilter()

        model.stop()
        XCTAssertFalse(central.scanning)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.peripherals.count, 2, "results stay listed after stopping")

        model.start()
        central.advertise(BluetoothAdvertisement(identifier: named, rssi: -60))
        waitForPublish()
        XCTAssertEqual(model.scanNumber, 2)
        model.filter.currentScanOnly = true
        XCTAssertEqual(model.visiblePeripherals.map { $0.id }, [named], "only devices heard again in the new scan")
        XCTAssertEqual(model.peripherals.first { $0.id == named }?.localName, "Thermometer", "name kept although the new advertisement omitted it")

        let reloaded = BluetoothModel(central: FakeCentral(), log: ActivityLog(), registry: CapabilityRegistry(),
                                      labelStore: BluetoothLabelStore(defaults: defaults))
        XCTAssertEqual(reloaded.labels[unnamed], "Hallway tag", "labels persist on this phone")
    }

    func testPermissionAndUnavailableStatesNeverShowResults() {
        central.authorization = .denied
        model.start()
        waitForPublish()
        XCTAssertEqual(model.state, .blocked(.permissionDenied))
        XCTAssertFalse(central.scanning)

        central.authorization = .allowed
        central.radioState = .poweredOff
        model.stop()
        model.start()
        waitForPublish()
        XCTAssertEqual(model.state, .blocked(.poweredOff))
        central.advertise(BluetoothAdvertisement(identifier: UUID(), localName: "Should not appear", rssi: -40))
        waitForPublish()
        XCTAssertTrue(model.peripherals.isEmpty)
        XCTAssertNotEqual(registry.state(.bluetoothDiscovery)?.readiness, .verified)

        var off = SentinelSettings()
        off.scanningEnabled = false
        model.apply(off)
        model.stop()
        model.start()
        waitForPublish()
        XCTAssertEqual(model.state, .blocked(.disabledInSettings))
    }

    func testScanningStopsWhenTheSwitchIsTurnedOff() {
        model.start()
        XCTAssertTrue(central.scanning)
        var off = SentinelSettings()
        off.scanningEnabled = false
        model.apply(off)
        XCTAssertFalse(central.scanning)
        waitForPublish()
        XCTAssertFalse(model.state.isActive)
    }
}
