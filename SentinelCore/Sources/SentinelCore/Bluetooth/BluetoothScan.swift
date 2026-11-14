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
    /// Raw manufacturer-specific data (company ID first), capped at 64 bytes.
    public var manufacturerData: [UInt8]?
    /// Service data keyed by service UUID, each capped at 32 bytes.
    public var serviceData: [String: [UInt8]]
    /// Services in the "overflow" area (iOS background advertisers) and services the device asks for.
    public var overflowServiceUUIDs: [String]
    public var solicitedServiceUUIDs: [String]

    public init(identifier: UUID, name: String? = nil, localName: String? = nil, serviceUUIDs: [String] = [],
                manufacturerID: UInt16? = nil, manufacturerDataLength: Int? = nil, isConnectable: Bool? = nil,
                txPower: Int? = nil, rssi: Int, manufacturerData: [UInt8]? = nil, serviceData: [String: [UInt8]] = [:],
                overflowServiceUUIDs: [String] = [], solicitedServiceUUIDs: [String] = []) {
        self.identifier = identifier
        self.name = name
        self.localName = localName
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerID = manufacturerID
        self.manufacturerDataLength = manufacturerDataLength
        self.isConnectable = isConnectable
        self.txPower = txPower
        self.rssi = rssi
        self.manufacturerData = manufacturerData.map { Array($0.prefix(64)) }
        self.serviceData = serviceData.mapValues { Array($0.prefix(32)) }
        self.overflowServiceUUIDs = overflowServiceUUIDs
        self.solicitedServiceUUIDs = solicitedServiceUUIDs
    }

    /// A non-empty, trimmed text value, or nil. Empty names in advertisements must not erase known ones.
    static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(64))
    }
}

/// Where the name shown for a device comes from.
public enum BluetoothNameSource: Equatable {
    /// A label the user assigned on this phone.
    case userLabel(String)
    /// The local name in the device's own advertisement.
    case advertised(String)
    /// A name iOS remembers for this identifier (for example from an earlier connection by another app).
    case system(String)
    /// The device broadcast no name.
    case notBroadcast

    public var text: String {
        switch self {
        case .userLabel(let name), .advertised(let name), .system(let name): return name
        case .notBroadcast: return "Name not broadcast"
        }
    }

    public var explanation: String {
        switch self {
        case .userLabel: return "Your label on this phone. The device did not choose it."
        case .advertised: return "Name in the device's advertisement. Any device can broadcast any name."
        case .system: return "Name iOS reports for this identifier. It may come from an earlier connection, not from the current advertisement."
        case .notBroadcast: return "Many devices do not broadcast a name. That alone says nothing about what the device is or whether it is a concern."
        }
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
    /// When the current `rssi` was received.
    public var rssiAt: Date?
    /// The most recent valid readings, newest last (at most 12).
    public var recentRSSI: [Int] = []
    public var manufacturerData: [UInt8]?
    public var serviceData: [String: [UInt8]] = [:]
    public var overflowServiceUUIDs: [String] = []
    public var solicitedServiceUUIDs: [String] = []
    /// Scan session in which the device was last heard (see `BluetoothScanController.scanNumber`).
    public var lastScan: Int = 0
    public var sightingsInLastScan: Int = 0

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

    /// Name and where it comes from: user label, then advertised name, then the name iOS knows, else "not broadcast".
    public func nameSource(label: String?) -> BluetoothNameSource {
        if let label = BluetoothAdvertisement.clean(label) { return .userLabel(label) }
        if let local = BluetoothAdvertisement.clean(localName) { return .advertised(local) }
        if let system = BluetoothAdvertisement.clean(name) { return .system(system) }
        return .notBroadcast
    }

    public var displayName: String { nameSource(label: nil).text }

    public var hasBroadcastName: Bool { BluetoothAdvertisement.clean(localName) != nil || BluetoothAdvertisement.clean(name) != nil }

    /// Every advertised service, including overflow-area services, without duplicates.
    public var allServiceUUIDs: [String] {
        var all = serviceUUIDs
        for uuid in overflowServiceUUIDs + Array(serviceData.keys).sorted() where !all.contains(uuid) { all.append(uuid) }
        return all
    }

    public var rssiRange: ClosedRange<Int>? {
        guard let low = recentRSSI.min(), let high = recentRSSI.max() else { return nil }
        return low...high
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
    /// Increments each time a scan actually starts. 0 means no scan has run yet.
    public private(set) var scanNumber = 0
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
        var device: DiscoveredPeripheral
        if let existing = peripherals[advertisement.identifier] {
            device = existing
        } else {
            if peripherals.count >= BluetoothScanController.maxPeripherals,
               let oldest = peripherals.values.min(by: { $0.lastSeen < $1.lastSeen }) {
                peripherals.removeValue(forKey: oldest.id)
            }
            device = DiscoveredPeripheral(id: advertisement.identifier, rssi: nil, firstSeen: time, lastSeen: time, sightings: 0)
        }
        BluetoothScanController.merge(advertisement, reading: reading, at: time, scan: scanNumber, into: &device)
        peripherals[advertisement.identifier] = device
        if !discoveredDuringScan {
            discoveredDuringScan = true
            onFirstDiscovery?()
        }
        onChange?()
    }

    /// Folds one advertisement into what is known about a device. Fields an advertisement leaves out (names,
    /// services, manufacturer data, TX power, connectable flag) keep their earlier values: advertisements and scan
    /// responses often carry different parts, and omission is not evidence that something went away.
    static func merge(_ ad: BluetoothAdvertisement, reading: Int?, at time: Date, scan: Int, into device: inout DiscoveredPeripheral) {
        if let name = BluetoothAdvertisement.clean(ad.name) { device.name = name }
        if let local = BluetoothAdvertisement.clean(ad.localName) { device.localName = local }
        for uuid in ad.serviceUUIDs where !device.serviceUUIDs.contains(uuid) && device.serviceUUIDs.count < 32 { device.serviceUUIDs.append(uuid) }
        for uuid in ad.overflowServiceUUIDs where !device.overflowServiceUUIDs.contains(uuid) && device.overflowServiceUUIDs.count < 32 {
            device.overflowServiceUUIDs.append(uuid)
        }
        for uuid in ad.solicitedServiceUUIDs where !device.solicitedServiceUUIDs.contains(uuid) && device.solicitedServiceUUIDs.count < 32 {
            device.solicitedServiceUUIDs.append(uuid)
        }
        for (uuid, data) in ad.serviceData where device.serviceData[uuid] != nil || device.serviceData.count < 16 { device.serviceData[uuid] = data }
        if let id = ad.manufacturerID { device.manufacturerID = id }
        if let length = ad.manufacturerDataLength { device.manufacturerDataLength = length }
        if let data = ad.manufacturerData { device.manufacturerData = data }
        if let connectable = ad.isConnectable { device.isConnectable = connectable }
        if let power = ad.txPower { device.txPower = power }
        if let reading = reading {
            device.rssi = reading
            device.rssiAt = time
            device.recentRSSI.append(reading)
            if device.recentRSSI.count > 12 { device.recentRSSI.removeFirst(device.recentRSSI.count - 12) }
        }
        if device.lastScan != scan {
            device.lastScan = scan
            device.sightingsInLastScan = 0
        }
        device.sightingsInLastScan += 1
        device.lastSeen = time
        device.sightings += 1
    }

    // MARK: Internals

    private func evaluateRadio(_ radio: BluetoothRadioState, requested: Bool) {
        switch radio {
        case .poweredOn:
            if case .scanning = state { return }
            discoveredDuringScan = false
            scanNumber += 1
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
