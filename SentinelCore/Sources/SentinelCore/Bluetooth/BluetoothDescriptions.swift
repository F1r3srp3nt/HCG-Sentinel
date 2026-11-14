import Foundation

/// Names from the Bluetooth SIG assigned-numbers registry for a small set of common values. They describe what a
/// field *says*, not who the device is: any device can put any company identifier or service UUID in its advertisement.
public enum BluetoothAssignedNumbers {
    /// Company identifiers (manufacturer-specific data).
    public static let companies: [UInt16: String] = [
        0x0002: "Intel",
        0x0006: "Microsoft",
        0x000D: "Texas Instruments",
        0x000F: "Broadcom",
        0x001D: "Qualcomm",
        0x004C: "Apple",
        0x0059: "Nordic Semiconductor",
        0x0075: "Samsung Electronics",
        0x0087: "Garmin International",
        0x009E: "Bose",
        0x00C4: "LG Electronics",
        0x00E0: "Google",
        0x012D: "Sony",
        0x0171: "Amazon.com Services",
        0x02E5: "Espressif",
        0x038F: "Xiaomi",
        0xFFFF: "Reserved for testing (no company)"
    ]

    /// 16-bit service UUIDs, as Core Bluetooth prints them.
    public static let services: [String: String] = [
        "1800": "Generic Access",
        "1801": "Generic Attribute",
        "180A": "Device Information",
        "180D": "Heart Rate",
        "180F": "Battery",
        "1810": "Blood Pressure",
        "1812": "Human Interface Device",
        "1816": "Cycling Speed and Cadence",
        "1818": "Cycling Power",
        "181A": "Environmental Sensing",
        "1826": "Fitness Machine",
        "FD6F": "Exposure Notification",
        "FEAA": "Eddystone"
    ]

    public static func companyName(_ id: UInt16) -> String? { companies[id] }

    public static func companyLabel(_ id: UInt16) -> String {
        let hex = String(format: "0x%04X", id)
        return companies[id].map { "\($0) (\(hex))" } ?? "\(hex) (not in Sentinel's short list)"
    }

    public static func serviceLabel(_ uuid: String) -> String {
        services[uuid.uppercased()].map { "\($0) (\(uuid))" } ?? uuid
    }

    public static func hex(_ bytes: [UInt8], limit: Int = 32) -> String {
        let shown = bytes.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return bytes.count > limit ? shown + " …" : shown
    }
}

public enum BluetoothSortOrder: String, CaseIterable, Codable {
    case lastSeen, signal, name

    public var title: String {
        switch self {
        case .lastSeen: return "Last seen"
        case .signal: return "Signal"
        case .name: return "Name"
        }
    }
}

/// Filters for the discovered-device list. Defaults show everything.
public struct BluetoothDeviceFilter: Equatable, Codable {
    public var text = ""
    public var namedOnly = false
    public var labelledOnly = false
    public var currentScanOnly = false
    public var connectableOnly = false
    public var withServicesOnly = false
    /// Hide readings weaker than this (dBm). Nil shows all, including devices with no reading.
    public var minimumRSSI: Int?
    public var sort: BluetoothSortOrder = .lastSeen

    public init() {}

    public var isActive: Bool {
        var plain = self
        plain.sort = .lastSeen
        return plain != BluetoothDeviceFilter()
    }

    public func apply(_ devices: [DiscoveredPeripheral], labels: [UUID: String], currentScan: Int) -> [DiscoveredPeripheral] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        let kept = devices.filter { device in
            if namedOnly && !device.hasBroadcastName { return false }
            if labelledOnly && labels[device.id] == nil { return false }
            if currentScanOnly && (currentScan == 0 || device.lastScan != currentScan) { return false }
            if connectableOnly && device.isConnectable != true { return false }
            if withServicesOnly && device.allServiceUUIDs.isEmpty { return false }
            if let floor = minimumRSSI {
                guard let rssi = device.rssi, rssi >= floor else { return false }
            }
            if needle.isEmpty { return true }
            var haystack = [device.id.uuidString, device.localName ?? "", device.name ?? "", labels[device.id] ?? ""]
            haystack += device.allServiceUUIDs.map(BluetoothAssignedNumbers.serviceLabel)
            if let company = device.manufacturerID { haystack.append(BluetoothAssignedNumbers.companyLabel(company)) }
            return haystack.contains { $0.lowercased().contains(needle) }
        }
        switch sort {
        case .lastSeen:
            return kept.sorted { $0.lastSeen != $1.lastSeen ? $0.lastSeen > $1.lastSeen : $0.id.uuidString < $1.id.uuidString }
        case .signal:
            return kept.sorted { ($0.rssi ?? -999, $1.id.uuidString) > ($1.rssi ?? -999, $0.id.uuidString) }
        case .name:
            return kept.sorted {
                let a = $0.nameSource(label: labels[$0.id]), b = $1.nameSource(label: labels[$1.id])
                let aNamed = a != .notBroadcast, bNamed = b != .notBroadcast
                if aNamed != bNamed { return aNamed }
                let order = a.text.localizedCaseInsensitiveCompare(b.text)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
        }
    }
}

/// User-assigned names, keyed by the identifier iOS gives this app for a device. A label follows the identifier,
/// not the physical device: if the device changes its address and iOS assigns a new identifier, the label does not
/// carry over.
public final class BluetoothLabelStore {
    public static let maxLabels = 200
    private let defaults: UserDefaults
    private let key: String
    public private(set) var labels: [UUID: String]

    public init(defaults: UserDefaults = .standard, key: String = "Sentinel.Bluetooth.Labels") {
        self.defaults = defaults
        self.key = key
        let stored = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        var parsed: [UUID: String] = [:]
        for (id, label) in stored { if let uuid = UUID(uuidString: id), let clean = BluetoothAdvertisement.clean(label) { parsed[uuid] = clean } }
        labels = parsed
    }

    /// Sets or (with nil or blank text) removes a label. Returns false when the store is full.
    @discardableResult
    public func set(_ label: String?, for id: UUID) -> Bool {
        if let clean = BluetoothAdvertisement.clean(label) {
            guard labels[id] != nil || labels.count < BluetoothLabelStore.maxLabels else { return false }
            labels[id] = clean
        } else {
            labels[id] = nil
        }
        defaults.set(Dictionary(uniqueKeysWithValues: labels.map { ($0.key.uuidString, $0.value) }), forKey: key)
        return true
    }

    public func removeAll() {
        labels = [:]
        defaults.removeObject(forKey: key)
    }
}
