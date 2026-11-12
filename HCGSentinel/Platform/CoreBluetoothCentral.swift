import CoreBluetooth
import Foundation
import SentinelCore

/// Core Bluetooth implementation of `BluetoothCentral`.
///
/// The `CBCentralManager` is created lazily in `activate()`, which only runs
/// after the user starts a scan, so the system permission prompt never appears
/// at launch. Only advertisement discovery is used: Sentinel does not connect
/// to peripherals.
final class CoreBluetoothCentral: NSObject, BluetoothCentral, CBCentralManagerDelegate {
    weak var delegate: BluetoothCentralDelegate?
    private var manager: CBCentralManager?

    var authorization: BluetoothAuthorization {
        switch CBCentralManager.authorization {
        case .allowedAlways: return .allowed
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    var radioState: BluetoothRadioState {
        guard let manager = manager else { return .unknown }
        return CoreBluetoothCentral.map(manager.state)
    }

    func activate() {
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func startScan(allowDuplicates: Bool) {
        manager?.scanForPeripherals(withServices: nil,
                                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates])
    }

    func stopScan() {
        guard let manager = manager, manager.state == .poweredOn else { return }
        manager.stopScan()
    }

    private static func map(_ state: CBManagerState) -> BluetoothRadioState {
        switch state {
        case .poweredOn: return .poweredOn
        case .poweredOff: return .poweredOff
        case .resetting: return .resetting
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        delegate?.centralDidUpdate(radioState: CoreBluetoothCentral.map(central.state), authorization: authorization)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        var advertisement = BluetoothAdvertisement(identifier: peripheral.identifier, name: peripheral.name, rssi: RSSI.intValue)
        advertisement.localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            advertisement.serviceUUIDs = services.map { $0.uuidString }
        }
        if let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            advertisement.manufacturerDataLength = manufacturer.count
            if manufacturer.count >= 2 {
                let bytes = [UInt8](manufacturer.prefix(2))
                advertisement.manufacturerID = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
            }
        }
        if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber {
            advertisement.isConnectable = connectable.boolValue
        }
        if let power = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber {
            advertisement.txPower = power.intValue
        }
        delegate?.centralDidDiscover(advertisement)
    }
}
