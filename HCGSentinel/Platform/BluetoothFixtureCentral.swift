#if DEBUG
import Foundation
import SentinelCore

/// DEBUG ONLY. A fake Bluetooth radio for screenshot checks in CI, where the Simulator has no Bluetooth. Selected with
/// the launch argument `-SentinelBluetoothFixture <denied|off|quiet|results>`; release builds do not contain it. The
/// devices it reports are synthetic and named as such.
final class BluetoothFixtureCentral: BluetoothCentral {
    enum Mode: String {
        case denied, off, quiet, results
    }

    weak var delegate: BluetoothCentralDelegate?
    private let mode: Mode
    private var timer: Timer?
    private var tick = 0

    static func fromLaunchArguments() -> BluetoothFixtureCentral? {
        guard let raw = UserDefaults.standard.string(forKey: "SentinelBluetoothFixture"), let mode = Mode(rawValue: raw) else { return nil }
        return BluetoothFixtureCentral(mode: mode)
    }

    init(mode: Mode) { self.mode = mode }

    var authorization: BluetoothAuthorization { mode == .denied ? .denied : .allowed }
    var radioState: BluetoothRadioState { mode == .off ? .poweredOff : .poweredOn }

    func activate() {}

    func startScan(allowDuplicates: Bool) {
        guard mode == .results else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.emit() }
        emit()
    }

    func stopScan() {
        timer?.invalidate()
        timer = nil
    }

    private static let ids = (1...4).map { UUID(uuidString: String(format: "F1C70000-0000-4000-8000-%012d", $0))! }

    private func emit() {
        tick += 1
        let wobble = [0, -3, 2, -5, 1, -2, 4, -1][tick % 8]
        delegate?.centralDidDiscover(BluetoothAdvertisement(identifier: Self.ids[0], localName: "Fixture Heart Rate", serviceUUIDs: ["180D", "180F"],
                                                            isConnectable: true, txPower: -4, rssi: -58 + wobble))
        delegate?.centralDidDiscover(BluetoothAdvertisement(identifier: Self.ids[1], manufacturerID: 0x004C, manufacturerDataLength: 6,
                                                            rssi: -77 - wobble, manufacturerData: [0x4C, 0x00, 0x10, 0x05, 0x01, 0x18]))
        if tick % 2 == 0 {
            delegate?.centralDidDiscover(BluetoothAdvertisement(identifier: Self.ids[2], localName: "Fixture Thermometer", serviceUUIDs: ["181A"],
                                                                rssi: -69 + wobble, serviceData: ["181A": [0x01, 0x9C, 0x08]]))
        }
        if tick % 3 == 0 {
            delegate?.centralDidDiscover(BluetoothAdvertisement(identifier: Self.ids[3], rssi: -91 + wobble))
        }
    }
}
#endif
