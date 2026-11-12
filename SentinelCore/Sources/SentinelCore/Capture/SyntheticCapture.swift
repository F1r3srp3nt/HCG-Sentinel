import Foundation

/// Builds synthetic packets and capture files. Used by the automated tests and
/// by the clearly labelled Preview mode; nothing here represents real traffic.
public enum SyntheticCapture {
    public struct Record {
        public var timestamp: Date
        public var bytes: [UInt8]
        public init(timestamp: Date, bytes: [UInt8]) {
            self.timestamp = timestamp
            self.bytes = bytes
        }
    }

    public static let macA: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x01]
    public static let macB: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x02]

    // MARK: Frames
    // `cat` keeps every operand explicitly typed, which avoids slow type-checking of long `+` chains.

    static func cat(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }

    public static func ethernet(source: [UInt8] = macA, destination: [UInt8] = macB,
                                etherType: UInt16, payload: [UInt8], vlan: UInt16? = nil) -> [UInt8] {
        let tag: [UInt8] = vlan.map { cat(be16(0x8100), be16($0)) } ?? []
        return cat(destination, source, tag, be16(etherType), payload)
    }

    public static func ipv4(source: [UInt8], destination: [UInt8], proto: UInt8, payload: [UInt8],
                            ttl: UInt8 = 64, fragmentOffsetUnits: UInt16 = 0) -> [UInt8] {
        var header = cat([0x45, 0x00], be16(UInt16(20 + payload.count)), be16(0x1234),
                         be16(fragmentOffsetUnits & 0x1fff), [ttl, proto, 0, 0], source, destination)
        let sum = checksum(header)
        header[10] = UInt8(sum >> 8)
        header[11] = UInt8(sum & 0xff)
        return cat(header, payload)
    }

    public static func ipv6(source: [UInt8], destination: [UInt8], nextHeader: UInt8, payload: [UInt8]) -> [UInt8] {
        cat([0x60, 0, 0, 0], be16(UInt16(payload.count)), [nextHeader, 64], source, destination, payload)
    }

    public static func tcp(sourcePort: UInt16, destinationPort: UInt16, sequence: UInt32 = 1,
                           acknowledgement: UInt32 = 0, flags: UInt8 = 0x02, payload: [UInt8] = []) -> [UInt8] {
        cat(be16(sourcePort), be16(destinationPort), be32(sequence), be32(acknowledgement),
            [0x50, flags], be16(65535), [0, 0, 0, 0], payload)
    }

    public static func udp(sourcePort: UInt16, destinationPort: UInt16, payload: [UInt8] = []) -> [UInt8] {
        cat(be16(sourcePort), be16(destinationPort), be16(UInt16(8 + payload.count)), [0, 0], payload)
    }

    public static func icmpEcho(request: Bool = true) -> [UInt8] {
        [request ? 8 : 0, 0, 0, 0, 0, 1, 0, 1]
    }

    public static func arpRequest(senderMAC: [UInt8] = macA, senderIP: [UInt8], targetIP: [UInt8]) -> [UInt8] {
        cat(be16(1), be16(0x0800), [6, 4], be16(1), senderMAC, senderIP, [0, 0, 0, 0, 0, 0], targetIP)
    }

    // MARK: Files

    public static func pcap(_ records: [Record], linkType: UInt32 = 1, bigEndian: Bool = false,
                            nanoseconds: Bool = false) -> Data {
        let w32: (UInt32) -> [UInt8] = { bigEndian ? be32($0) : le32($0) }
        let w16: (UInt16) -> [UInt8] = { bigEndian ? be16($0) : le16($0) }
        let magic: UInt32 = nanoseconds ? 0xa1b23c4d : 0xa1b2c3d4
        var out = cat(w32(magic), w16(2), w16(4), w32(0), w32(0), w32(262_144), w32(linkType))
        for record in records {
            let (seconds, fraction) = split(record.timestamp, unitsPerSecond: nanoseconds ? 1_000_000_000 : 1_000_000)
            let length = UInt32(record.bytes.count)
            out += cat(w32(seconds), w32(fraction), w32(length), w32(length), record.bytes)
        }
        return Data(out)
    }

    public static func pcapng(_ records: [Record], linkType: UInt16 = 1, bigEndian: Bool = false) -> Data {
        let w32: (UInt32) -> [UInt8] = { bigEndian ? be32($0) : le32($0) }
        let w16: (UInt16) -> [UInt8] = { bigEndian ? be16($0) : le16($0) }
        func block(_ type: UInt32, _ body: [UInt8]) -> [UInt8] {
            let padding = [UInt8](repeating: 0, count: (4 - body.count % 4) % 4)
            let length = UInt32(12 + body.count + padding.count)
            return cat(w32(type), w32(length), body, padding, w32(length))
        }
        // The section header's block type is a palindrome, so it is identical in both byte orders.
        let sectionLength = [UInt8](repeating: 0xff, count: 8)
        var out = block(0x0a0d0d0a, cat(w32(0x1a2b3c4d), w16(1), w16(0), sectionLength))
        out += block(1, cat(w16(linkType), w16(0), w32(262_144)))
        for record in records {
            let micros = UInt64(max(0, record.timestamp.timeIntervalSince1970) * 1_000_000)
            let length = UInt32(record.bytes.count)
            let high = UInt32(micros >> 32), low = UInt32(micros & 0xffff_ffff)
            out += block(6, cat(w32(0), w32(high), w32(low), w32(length), w32(length), record.bytes))
        }
        return Data(out)
    }

    /// A small fabricated conversation on documentation-only address ranges
    /// (RFC 5737 / RFC 3849) for Preview mode and tests.
    public static func demoRecords(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> [Record] {
        let client: [UInt8] = [192, 0, 2, 10], server: [UInt8] = [198, 51, 100, 20], resolver: [UInt8] = [192, 0, 2, 53]
        var v6a = [UInt8](repeating: 0, count: 16), v6b = [UInt8](repeating: 0, count: 16)
        v6a[0] = 0x20; v6a[1] = 0x01; v6a[2] = 0x0d; v6a[3] = 0xb8; v6a[15] = 0x01
        v6b[0] = 0x20; v6b[1] = 0x01; v6b[2] = 0x0d; v6b[3] = 0xb8; v6b[15] = 0x02
        let frames: [[UInt8]] = [
            ethernet(etherType: 0x0806, payload: arpRequest(senderIP: client, targetIP: [192, 0, 2, 1])),
            ethernet(etherType: 0x0800, payload: ipv4(source: client, destination: resolver, proto: 17,
                                                      payload: udp(sourcePort: 53124, destinationPort: 53, payload: [UInt8](repeating: 0, count: 29)))),
            ethernet(etherType: 0x0800, payload: ipv4(source: client, destination: server, proto: 6,
                                                      payload: tcp(sourcePort: 50000, destinationPort: 443, sequence: 1000, flags: 0x02))),
            ethernet(source: macB, destination: macA, etherType: 0x0800,
                     payload: ipv4(source: server, destination: client, proto: 6,
                                   payload: tcp(sourcePort: 443, destinationPort: 50000, sequence: 5000, acknowledgement: 1001, flags: 0x12))),
            ethernet(etherType: 0x0800, payload: ipv4(source: client, destination: server, proto: 6,
                                                      payload: tcp(sourcePort: 50000, destinationPort: 443, sequence: 1001, acknowledgement: 5001, flags: 0x10))),
            ethernet(etherType: 0x0800, payload: ipv4(source: client, destination: server, proto: 1, payload: icmpEcho())),
            ethernet(etherType: 0x86dd, payload: ipv6(source: v6a, destination: v6b, nextHeader: 17,
                                                      payload: udp(sourcePort: 5353, destinationPort: 5353, payload: [1, 2, 3, 4])))
        ]
        return frames.enumerated().map { Record(timestamp: start.addingTimeInterval(Double($0.offset) * 0.125), bytes: $0.element) }
    }

    public static func demoCapture() -> Data { pcap(demoRecords()) }

    // MARK: Helpers

    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    static func le32(_ v: UInt32) -> [UInt8] { Array(be32(v).reversed()) }

    private static func split(_ date: Date, unitsPerSecond: Double) -> (UInt32, UInt32) {
        let interval = max(0, date.timeIntervalSince1970)
        let seconds = interval.rounded(.down)
        let fraction = ((interval - seconds) * unitsPerSecond).rounded()
        return (UInt32(min(seconds, 4_294_967_295)), UInt32(min(fraction, unitsPerSecond - 1)))
    }

    private static func checksum(_ header: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < header.count {
            sum += UInt32(header[index]) << 8 | UInt32(header[index + 1])
            index += 2
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum & 0xffff)
    }
}
