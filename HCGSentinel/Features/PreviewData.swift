import Foundation
import SentinelCore

/// Fabricated sample data shown only while Preview mode is on, always under a
/// "PREVIEW MODE — DEMONSTRATION DATA" banner. None of it is ever written to
/// the activity log, the capability registry or storage.
enum PreviewData {
    static func peripherals(now: Date = Date()) -> [DiscoveredPeripheral] {
        func id(_ suffix: String) -> UUID { UUID(uuidString: "00000000-0000-4000-8000-0000000000\(suffix)") ?? UUID() }
        let devices = [
            DiscoveredPeripheral(id: id("01"), localName: "Demo Heart Rate Strap", serviceUUIDs: ["180D", "180F"],
                                 isConnectable: true, rssi: -52, firstSeen: now.addingTimeInterval(-40), lastSeen: now.addingTimeInterval(-1), sightings: 38),
            DiscoveredPeripheral(id: id("02"), localName: "Demo Beacon", serviceUUIDs: ["FEAA"], manufacturerID: 0xFFFF,
                                 manufacturerDataLength: 25, isConnectable: false, txPower: -4, rssi: -71,
                                 firstSeen: now.addingTimeInterval(-33), lastSeen: now.addingTimeInterval(-3), sightings: 21),
            DiscoveredPeripheral(id: id("03"), serviceUUIDs: [], manufacturerID: 0xFFFF, manufacturerDataLength: 9,
                                 isConnectable: true, rssi: -88, firstSeen: now.addingTimeInterval(-12), lastSeen: now.addingTimeInterval(-6), sightings: 4)
        ]
        return devices.map { device in
            var copy = device
            copy.lastScan = 1
            copy.sightingsInLastScan = device.sightings
            return copy
        }
    }

    /// A static, obviously synthetic spectrum: flat noise floor with two smooth peaks.
    static func spectrum() -> SpectrumFrame {
        let bins = 256
        let powers: [Double] = (0..<bins).map { index in
            let x = Double(index) / Double(bins - 1)
            let ripple = 1.5 * sin(Double(index) * 0.9)
            let first = 42 * exp(-pow(x - 0.32, 2) / 0.0006)
            let second = 28 * exp(-pow(x - 0.68, 2) / 0.0016)
            return -96 + ripple + first + second
        }
        return SpectrumFrame(sequence: 0, timestamp: 0, centerFrequencyHz: 100_000_000, spanHz: 2_000_000, powers: powers)
    }
}
