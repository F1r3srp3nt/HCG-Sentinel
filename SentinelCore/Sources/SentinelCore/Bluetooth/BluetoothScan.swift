import Foundation

public enum BluetoothAuthorization: Equatable {
    case notDetermined, restricted, denied, allowed
}

public enum BluetoothRadioState: Equatable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn
}

/// One received advertisement, as exposed by the platform Bluetooth API.
public struct BluetoothAdvertisement: Equatable {
    /// Per-app identifier assigned by iOS. It is not the hardware address.
    public var identifier: UUID
    public var name: String?
    public var localName: String?
    public var serviceUUIDs: [String]
    /// Bluetooth SIG company identifier from manufacturer data, when present.
    public var manufacturerID: UInt16?
    public var manufacturerDataLength: Int?
    public var isConnectable: Bool?
    public var txPower: Int?
    /// dBm. 127 means the platform could not provide a reading.
    public var rssi: Int

    public init(identifier: UUID, name: String? = nil, localName: String? = nil, serviceUUIDs: [String] = [],
                manufacturerID: UInt16? = nil, manufacturerDataLength: Int? = nil, isConnectable: Bool? = nil,
                txPower: Int? = nil, rssi: Int) {
        self.identifier = identifier
        self.name = name
        self.localName = localName
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerID = manufacturerID
        self.manufacturerDataLength = manufacturerDataLength
        self.isConnectable = isConnectable
        self.txPower = txPower
        self.rssi = rssi
    }
}

public struct DiscoveredPeripheral: Identifiable, Equatable {
    public let id: UUID
    public var name: String?
    public var localName: String?
    public var serviceUUIDs: [String]
    public var manufacturerID: UInt16?
    public var manufacturerDataLength: Int?
    public var isConnectable: Bool?
    public var txPower: Int?
    /// Most recent valid reading in dBm, or nil when none was available.
    public var rssi: Int?
    public var firstSeen: Date
    public var lastSeen: Date
    public var sightings: Int

    public init(id: UUID, name: String? = nil, localName: String? = nil, serviceUUIDs: [String] = [],
                manufacturerID: UInt16? = nil, manufacturerDataLength: Int? = nil, isConnectable: Bool? = nil,
                txPower: Int? = nil, rssi: Int?, firstSeen: Date, lastSeen: Date, sightings: Int) {
        self.id = id
        self.name = name
        self.localName = localName
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerID = manufacturerID
        self.manufacturerDataLength = manufacturerDataLength
        self.isConnectable = isConnectable
        self.txPower = txPower
        self.rssi = rssi
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.sightings = sightings
    }

    public var displayName: String {
        if let localName = localName, !localName.isEmpty { return localName }
        if let name = name, !name.isEmpty { return name }
        return "Unnamed device"
    }

    /// Coarse description of received signal strength. Not a distance estimate.
    public var signalDescription: String {
        guard let rssi = rssi else { return "No reading" }
        switch rssi {
        case (-55)...: return "Strong signal"
        case (-70)...: return "Good signal"
        case (-85)...: return "Weak signal"
        default: return "Very weak signal"
        }
    }

    /// 0–4 bars of received signal strength.
    public var signalBars: Int {
        guard let rssi = rssi else { return 0 }
        switch rssi {
        case (-55)...: return 4
        case (-70)...: return 3
        case (-85)...: return 2
        default: return 1
        }
    }
}

public protocol BluetoothCentralDelegate: AnyObject {
    func centralDidUpdate(radioState: BluetoothRadioState, authorization: BluetoothAuthorization)
    func centralDidDiscover(_ advertisement: BluetoothAdvertisement)
}

/// Abstraction over the platform Bluetooth central so the scan state machine
/// can be tested without hardware.
public protocol BluetoothCentral: AnyObject {
    var delegate: BluetoothCentralDelegate? { get set }
    /// Current permission. Must not trigger the system permission prompt.
    var authorization: BluetoothAuthorization { get }
    var radioState: BluetoothRadioState { get }
    /// Creates the underlying manager if needed. May show the system permission prompt.
    func activate()
    func startScan(allowDuplicates: Bool)
    func stopScan()
}

public enum BluetoothScanBlocker: Equatable {
    case disabledInSettings
    case permissionDenied
    case restricted
    case poweredOff
    case unsupported
    case resetting

    public var title: String {
        switch self {
        case .disabledInSettings: return "Scanning is off"
        case .permissionDenied: return "Bluetooth permission denied"
        case .restricted: return "Bluetooth is restricted"
        case .poweredOff: return "Bluetooth is turned off"
        case .unsupported: return "Bluetooth LE is not available"
        case .resetting: return "Bluetooth is restarting"
        }
    }

    public var guidance: String {
        switch self {
        case .disabledInSettings:
            return "Turn on Scanning in Sentinel’s Settings, then start a scan."
        case .permissionDenied:
            return "Sentinel is not allowed to use Bluetooth. Allow it in the iOS Settings app under Sentinel › Bluetooth."
        case .restricted:
            return "Bluetooth use is restricted on this device, for example by Screen Time or a management profile. Sentinel cannot change that."
        case .poweredOff:
            return "Turn Bluetooth on in the iOS Settings app or Control Centre, then start the scan again. Sentinel does not switch it on for you."
        case .unsupported:
            return "This device or simulator has no Bluetooth LE radio available to apps."
        case .resetting:
            return "The system Bluetooth service is restarting. Try again in a moment."
        }
    }
}

public enum BluetoothScanState: Equatable {
    case idle
    case waitingForRadio
    case scanning(since: Date)
    case blocked(BluetoothScanBlocker)

    public var isActive: Bool {
        switch self {
        case .waitingForRadio, .scanning: return true
        case .idle, .blocked: return false
        }
    }
}

/// User-triggered Bluetooth LE discovery. Scanning never starts on its own.
/// Confine to the main queue.
public final class BluetoothScanController: BluetoothCentralDelegate {
    public static let maxPeripherals = 500

    public private(set) var state: BluetoothScanState = .idle
    public private(set) var peripherals: [UUID: DiscoveredPeripheral] = [:]
    public private(set) var autoStopDeadline: Date?
    public var isEnabledInSettings = false
    public var allowDuplicates = false
    /// Seconds after which a scan stops by itself; 0 disables the limit.
    public var autoStopInterval: TimeInterval = 60

    public var onChange: (() -> Void)?
    /// Called when the first advertisement of a scan arrives.
    public var onFirstDiscovery: (() -> Void)?
    public var onStateEvent: ((String, ActivitySeverity) -> Void)?

    private let central: BluetoothCentral
    private let now: () -> Date
    private var discoveredDuringScan = false

    public init(central: BluetoothCentral, now: @escaping () -> Date = Date.init) {
        self.central = central
        self.now = now
        central.delegate = self
    }

    public var sortedPeripherals: [DiscoveredPeripheral] {
        peripherals.values.sorted {
            if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func start() {
        guard !state.isActive else { return }
        guard isEnabledInSettings else {
            transition(.blocked(.disabledInSettings))
            return
        }
        switch central.authorization {
        case .denied:
            transition(.blocked(.permissionDenied))
            return
        case .restricted:
            transition(.blocked(.restricted))
            return
        case .notDetermined, .allowed:
            break
        }
        central.activate()
        evaluateRadio(central.radioState, requested: true)
    }

    public func stop(reason: String = "Scan stopped") {
        guard state.isActive else {
            if case .blocked = state { transition(.idle) }
            return
        }
        if case .scanning = state { central.stopScan() }
        autoStopDeadline = nil
        onStateEvent?("\(reason). \(peripherals.count) device(s) listed.", .info)
        transition(.idle)
    }

    public func clearResults() {
        peripherals.removeAll()
        onChange?()
    }

    /// Drives the auto-stop limit. Call periodically while a scan is active.
    public func tick() {
        if let deadline = autoStopDeadline, now() >= deadline, state.isActive {
            stop(reason: "Scan stopped automatically at the time limit")
        }
    }

    // MARK: BluetoothCentralDelegate

    public func centralDidUpdate(radioState: BluetoothRadioState, authorization: BluetoothAuthorization) {
        guard state.isActive else { return }
        if authorization == .denied {
            halt(.permissionDenied)
        } else if authorization == .restricted {
            halt(.restricted)
        } else {
            evaluateRadio(radioState, requested: false)
        }
    }

    public func centralDidDiscover(_ advertisement: BluetoothAdvertisement) {
        guard case .scanning = state else { return }
        let time = now()
        let reading = (advertisement.rssi == 127 || advertisement.rssi > 20 || advertisement.rssi < -127) ? nil : advertisement.rssi
        if var existing = peripherals[advertisement.identifier] {
            existing.name = advertisement.name ?? existing.name
            existing.localName = advertisement.localName ?? existing.localName
            for uuid in advertisement.serviceUUIDs where !existing.serviceUUIDs.contains(uuid) {
                existing.serviceUUIDs.append(uuid)
            }
            existing.manufacturerID = advertisement.manufacturerID ?? existing.manufacturerID
            existing.manufacturerDataLength = advertisement.manufacturerDataLength ?? existing.manufacturerDataLength
            existing.isConnectable = advertisement.isConnectable ?? existing.isConnectable
            existing.txPower = advertisement.txPower ?? existing.txPower
            existing.rssi = reading ?? existing.rssi
            existing.lastSeen = time
            existing.sightings += 1
            peripherals[advertisement.identifier] = existing
        } else {
            if peripherals.count >= BluetoothScanController.maxPeripherals,
               let oldest = peripherals.values.min(by: { $0.lastSeen < $1.lastSeen }) {
                peripherals.removeValue(forKey: oldest.id)
            }
            peripherals[advertisement.identifier] = DiscoveredPeripheral(
                id: advertisement.identifier, name: advertisement.name, localName: advertisement.localName,
                serviceUUIDs: advertisement.serviceUUIDs, manufacturerID: advertisement.manufacturerID,
                manufacturerDataLength: advertisement.manufacturerDataLength, isConnectable: advertisement.isConnectable,
                txPower: advertisement.txPower, rssi: reading, firstSeen: time, lastSeen: time, sightings: 1)
        }
        if !discoveredDuringScan {
            discoveredDuringScan = true
            onFirstDiscovery?()
        }
        onChange?()
    }

    // MARK: Internals

    private func evaluateRadio(_ radio: BluetoothRadioState, requested: Bool) {
        switch radio {
        case .poweredOn:
            if case .scanning = state { return }
            discoveredDuringScan = false
            central.startScan(allowDuplicates: allowDuplicates)
            let started = now()
            autoStopDeadline = autoStopInterval > 0 ? started.addingTimeInterval(autoStopInterval) : nil
            onStateEvent?("Bluetooth LE scan started", .info)
            transition(.scanning(since: started))
        case .unknown:
            transition(.waitingForRadio)
        case .resetting:
            if requested { transition(.waitingForRadio) } else { halt(.resetting) }
        case .poweredOff:
            halt(.poweredOff)
        case .unsupported:
            halt(.unsupported)
        case .unauthorized:
            halt(central.authorization == .restricted ? .restricted : .permissionDenied)
        }
    }

    private func halt(_ blocker: BluetoothScanBlocker) {
        if case .scanning = state { central.stopScan() }
        autoStopDeadline = nil
        onStateEvent?("Bluetooth scan could not run: \(blocker.title)", .warning)
        transition(.blocked(blocker))
    }

    private func transition(_ new: BluetoothScanState) {
        guard state != new else { return }
        state = new
        onChange?()
    }
}
