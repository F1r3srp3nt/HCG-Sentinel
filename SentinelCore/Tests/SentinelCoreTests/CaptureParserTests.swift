import XCTest
@testable import SentinelCore

/// Deterministic generator so fuzz-style tests are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class CaptureParserTests: XCTestCase {
    private let records = SyntheticCapture.demoRecords()

    func testParsesLittleEndianPCAP() throws {
        let capture = try CaptureParser.parse(SyntheticCapture.pcap(records))
        XCTAssertEqual(capture.format, .pcap)
        XCTAssertEqual(capture.packets.count, records.count)
        XCTAssertEqual(capture.linkTypes, [1])
        XCTAssertTrue(capture.warnings.isEmpty)
        XCTAssertFalse(capture.stoppedEarly)
        XCTAssertEqual(capture.bytes(of: capture.packets[2]), records[2].bytes)
        let first = try XCTUnwrap(capture.packets.first?.timestamp)
        XCTAssertEqual(first.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
        let second = try XCTUnwrap(capture.packets[1].timestamp)
        XCTAssertEqual(second.timeIntervalSince1970, 1_700_000_000.125, accuracy: 0.001)
    }

    func testParsesBigEndianAndNanosecondPCAP() throws {
        for (bigEndian, nanoseconds) in [(true, false), (false, true), (true, true)] {
            let capture = try CaptureParser.parse(SyntheticCapture.pcap(records, bigEndian: bigEndian, nanoseconds: nanoseconds))
            XCTAssertEqual(capture.packets.count, records.count)
            XCTAssertEqual(capture.packets[3].summary.protocolName, "TCP")
            let stamp = try XCTUnwrap(capture.packets[4].timestamp)
            XCTAssertEqual(stamp.timeIntervalSince1970, 1_700_000_000.5, accuracy: 0.001)
        }
    }

    func testParsesPCAPNGInBothByteOrders() throws {
        for bigEndian in [false, true] {
            let capture = try CaptureParser.parse(SyntheticCapture.pcapng(records, bigEndian: bigEndian))
            XCTAssertEqual(capture.format, .pcapng)
            XCTAssertEqual(capture.packets.count, records.count)
            XCTAssertEqual(capture.linkTypes, [1])
            XCTAssertEqual(capture.bytes(of: capture.packets[1]), records[1].bytes)
            XCTAssertEqual(capture.packets[1].interfaceIndex, 0)
            let stamp = try XCTUnwrap(capture.packets[2].timestamp)
            XCTAssertEqual(stamp.timeIntervalSince1970, 1_700_000_000.25, accuracy: 0.001)
        }
    }

    func testSummariesExposeAddressesPortsAndProtocols() throws {
        let packets = try CaptureParser.parse(SyntheticCapture.demoCapture()).packets
        XCTAssertEqual(packets[0].summary.protocolName, "ARP")
        XCTAssertEqual(packets[0].summary.info, "Who has 192.0.2.1? Tell 192.0.2.10")
        XCTAssertEqual(packets[1].summary.protocolName, "UDP")
        XCTAssertEqual(packets[1].summary.destinationPort, 53)
        XCTAssertEqual(packets[1].summary.serviceHint, "DNS")
        XCTAssertEqual(packets[2].summary.source, "192.0.2.10")
        XCTAssertEqual(packets[2].summary.destination, "198.51.100.20")
        XCTAssertEqual(packets[2].summary.sourcePort, 50000)
        XCTAssertEqual(packets[2].summary.destinationPort, 443)
        XCTAssertEqual(packets[2].summary.destinationEndpoint, "198.51.100.20:443")
        XCTAssertTrue(packets[2].summary.info.hasPrefix("[SYN]"))
        XCTAssertTrue(packets[3].summary.info.hasPrefix("[SYN, ACK]"))
        XCTAssertEqual(packets[5].summary.protocolName, "ICMP")
        XCTAssertEqual(packets[6].summary.source, "2001:db8::1")
        XCTAssertEqual(packets[6].summary.sourceEndpoint, "[2001:db8::1]:5353")
        XCTAssertEqual(packets[6].summary.serviceHint, "mDNS")
    }

    // MARK: Malformed input

    func testRejectsEmptyUnknownAndTruncatedHeaders() {
        XCTAssertThrowsError(try CaptureParser.parse(Data())) { XCTAssertEqual($0 as? CaptureParseError, .empty) }
        XCTAssertThrowsError(try CaptureParser.parse(Data([1, 2]))) { XCTAssertEqual($0 as? CaptureParseError, .truncatedHeader) }
        XCTAssertThrowsError(try CaptureParser.parse(Data("GET / HTTP/1.1\r\n".utf8))) {
            XCTAssertEqual($0 as? CaptureParseError, .unrecognizedFormat)
        }
        let pcap = SyntheticCapture.pcap(records)
        XCTAssertThrowsError(try CaptureParser.parse(pcap.prefix(20))) { XCTAssertEqual($0 as? CaptureParseError, .truncatedHeader) }
        let pcapng = SyntheticCapture.pcapng(records)
        XCTAssertThrowsError(try CaptureParser.parse(pcapng.prefix(16))) { XCTAssertEqual($0 as? CaptureParseError, .truncatedHeader) }
    }

    func testRejectsUnsupportedVersion() {
        var bytes = [UInt8](SyntheticCapture.pcap(records))
        bytes[4] = 9
        XCTAssertThrowsError(try CaptureParser.parse(Data(bytes))) {
            XCTAssertEqual($0 as? CaptureParseError, .unsupportedVersion(major: 9, minor: 4))
        }
    }

    func testEnforcesFileSizeLimit() {
        let data = SyntheticCapture.pcap(records)
        XCTAssertThrowsError(try CaptureParser.parse(data, limits: CaptureLimits(maxFileBytes: 100))) {
            XCTAssertEqual($0 as? CaptureParseError, .fileTooLarge(size: data.count, limit: 100))
        }
    }

    func testStopsAtPacketLimit() throws {
        let capture = try CaptureParser.parse(SyntheticCapture.pcap(records), limits: CaptureLimits(maxPackets: 3))
        XCTAssertEqual(capture.packets.count, 3)
        XCTAssertTrue(capture.stoppedEarly)
        XCTAssertEqual(capture.warnings.count, 1)
        let ng = try CaptureParser.parse(SyntheticCapture.pcapng(records), limits: CaptureLimits(maxPackets: 2))
        XCTAssertEqual(ng.packets.count, 2)
        XCTAssertTrue(ng.stoppedEarly)
    }

    func testTruncatedFinalRecordKeepsEarlierPackets() throws {
        let data = SyntheticCapture.pcap(records)
        let capture = try CaptureParser.parse(data.prefix(data.count - 5))
        XCTAssertEqual(capture.packets.count, records.count - 1)
        XCTAssertTrue(capture.stoppedEarly)
        XCTAssertFalse(capture.warnings.isEmpty)
    }

    func testOversizedRecordLengthDoesNotAllocateOrCrash() throws {
        var bytes = [UInt8](SyntheticCapture.pcap(records))
        // First record header starts at 24; captured length is at 24 + 8.
        bytes.replaceSubrange(32..<36, with: [0xff, 0xff, 0xff, 0x7f])
        let capture = try CaptureParser.parse(Data(bytes))
        XCTAssertEqual(capture.packets.count, 0)
        XCTAssertTrue(capture.stoppedEarly)
    }

    func testPacketLargerThanLimitIsSkippedInPCAPNG() throws {
        let capture = try CaptureParser.parse(SyntheticCapture.pcapng(records), limits: CaptureLimits(maxPacketBytes: 50))
        XCTAssertTrue(capture.packets.allSatisfy { $0.capturedLength <= 50 })
        XCTAssertLessThan(capture.packets.count, records.count)
        XCTAssertFalse(capture.warnings.isEmpty)
    }

    func testPCAPNGWithCorruptBlockLengthStopsSafely() throws {
        var bytes = [UInt8](SyntheticCapture.pcapng(records))
        let sectionLength = 28, interfaceLength = 20
        let firstPacketBlock = sectionLength + interfaceLength
        bytes.replaceSubrange((firstPacketBlock + 4)..<(firstPacketBlock + 8), with: [0, 0, 0, 0])
        let capture = try CaptureParser.parse(Data(bytes))
        XCTAssertEqual(capture.packets.count, 0)
        XCTAssertTrue(capture.stoppedEarly)
    }

    func testPCAPNGPacketForUnknownInterfaceIsSkipped() throws {
        var bytes = [UInt8](SyntheticCapture.pcapng(records))
        let firstPacketBody = 28 + 20 + 8
        bytes.replaceSubrange(firstPacketBody..<(firstPacketBody + 4), with: [7, 0, 0, 0])
        let capture = try CaptureParser.parse(Data(bytes))
        XCTAssertEqual(capture.packets.count, records.count - 1)
        XCTAssertFalse(capture.stoppedEarly)
        XCTAssertEqual(capture.warnings.count, 1)
    }

    func testPCAPNGSimplePacketBlockHasNoTimestamp() throws {
        let frame = records[2].bytes
        var data = [UInt8](SyntheticCapture.pcapng([]))
        let padding = [UInt8](repeating: 0, count: (4 - frame.count % 4) % 4)
        let length = UInt32(12 + 4 + frame.count + padding.count)
        data += SyntheticCapture.cat(SyntheticCapture.le32(3), SyntheticCapture.le32(length),
                                     SyntheticCapture.le32(UInt32(frame.count)), frame, padding, SyntheticCapture.le32(length))
        let capture = try CaptureParser.parse(Data(data))
        XCTAssertEqual(capture.packets.count, 1)
        XCTAssertNil(capture.packets[0].timestamp)
        XCTAssertEqual(capture.bytes(of: capture.packets[0]), frame)
        XCTAssertEqual(capture.packets[0].summary.destinationPort, 443)
    }

    func testAcceptsDataSliceWithNonZeroStartIndex() throws {
        let padded = Data([0xde, 0xad, 0xbe, 0xef]) + SyntheticCapture.pcap(records)
        let capture = try CaptureParser.parse(padded.dropFirst(4))
        XCTAssertEqual(capture.packets.count, records.count)
    }

    // MARK: Robustness sweeps

    func testEveryTruncationOfValidFilesIsHandled() {
        for file in [SyntheticCapture.pcap(records), SyntheticCapture.pcapng(records), SyntheticCapture.pcapng(records, bigEndian: true)] {
            for length in 0..<file.count {
                if let capture = try? CaptureParser.parse(file.prefix(length)) {
                    XCTAssertLessThanOrEqual(capture.packets.count, records.count)
                    for packet in capture.packets { _ = capture.detail(of: packet) }
                }
            }
        }
    }

    func testRandomCorruptionNeverCrashes() {
        var generator = SeededGenerator(state: 0x5eed)
        for file in [SyntheticCapture.pcap(records), SyntheticCapture.pcapng(records)] {
            for _ in 0..<1500 {
                var bytes = [UInt8](file)
                for _ in 0..<Int.random(in: 1...6, using: &generator) {
                    bytes[Int.random(in: 0..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                }
                if let capture = try? CaptureParser.parse(Data(bytes)) {
                    for packet in capture.packets {
                        XCTAssertLessThanOrEqual(packet.range.upperBound, capture.data.count)
                        _ = capture.detail(of: packet)
                    }
                }
            }
        }
    }

    func testRandomBytesNeverCrash() {
        var generator = SeededGenerator(state: 42)
        let magics: [[UInt8]] = [[0xd4, 0xc3, 0xb2, 0xa1], [0xa1, 0xb2, 0xc3, 0xd4], [0x0a, 0x0d, 0x0d, 0x0a], [0x4d, 0x3c, 0xb2, 0xa1]]
        for round in 0..<800 {
            let length = Int.random(in: 0...400, using: &generator)
            let body = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = try? CaptureParser.parse(Data(magics[round % magics.count] + body))
        }
    }
}

final class PacketDecoderTests: XCTestCase {
    private func decode(_ bytes: [UInt8], linkType: UInt32 = 1) -> PacketDetail {
        PacketDecoder.decode(bytes, linkType: linkType, includeFields: true)
    }

    func testTCPDetailFields() {
        let frame = SyntheticCapture.ethernet(etherType: 0x0800, payload: SyntheticCapture.ipv4(
            source: [10, 0, 0, 1], destination: [10, 0, 0, 2], proto: 6,
            payload: SyntheticCapture.tcp(sourcePort: 1234, destinationPort: 80, sequence: 7, acknowledgement: 9,
                                          flags: 0x18, payload: Array("hello".utf8))))
        let detail = decode(frame)
        XCTAssertEqual(detail.layers.map { $0.name }, ["Ethernet", "IPv4", "TCP"])
        XCTAssertEqual(detail.summary.info, "[PSH, ACK] Seq=7 Ack=9 Win=65535 Len=5")
        XCTAssertEqual(detail.summary.serviceHint, "HTTP")
        XCTAssertTrue(detail.notes.isEmpty)
        let tcp = detail.layers[2].fields
        XCTAssertTrue(tcp.contains(PacketField("Destination port", "80")))
    }

    func testVLANTagIsSkipped() {
        let frame = SyntheticCapture.ethernet(etherType: 0x0800, payload: SyntheticCapture.ipv4(
            source: [10, 0, 0, 1], destination: [10, 0, 0, 2], proto: 17,
            payload: SyntheticCapture.udp(sourcePort: 68, destinationPort: 67)), vlan: 42)
        let detail = decode(frame)
        XCTAssertEqual(detail.summary.protocolName, "UDP")
        XCTAssertEqual(detail.summary.serviceHint, "DHCP")
        XCTAssertTrue(detail.layers[0].fields.contains(PacketField("VLAN", "42")))
    }

    func testTruncatedPacketIsReportedNotCrashed() {
        let frame = SyntheticCapture.ethernet(etherType: 0x0800, payload: SyntheticCapture.ipv4(
            source: [10, 0, 0, 1], destination: [10, 0, 0, 2], proto: 6,
            payload: SyntheticCapture.tcp(sourcePort: 1, destinationPort: 2)))
        // The decoder reads the first 16 bytes of the TCP header, so anything shorter is truncated.
        for length in 0..<(14 + 20 + 16) {
            let detail = decode(Array(frame.prefix(length)))
            XCTAssertEqual(detail.notes.count, 1, "length \(length)")
        }
        XCTAssertTrue(decode(Array(frame.prefix(40))).summary.info.contains("runcated"))
    }

    func testIPv4FragmentDoesNotInventPorts() {
        let frame = SyntheticCapture.ethernet(etherType: 0x0800, payload: SyntheticCapture.ipv4(
            source: [10, 0, 0, 1], destination: [10, 0, 0, 2], proto: 17, payload: [1, 2, 3, 4, 5, 6, 7, 8],
            fragmentOffsetUnits: 185))
        let summary = decode(frame).summary
        XCTAssertNil(summary.sourcePort)
        XCTAssertTrue(summary.info.contains("fragment"))
    }

    func testInvalidIPHeaderLength() {
        var packet = SyntheticCapture.ipv4(source: [1, 1, 1, 1], destination: [2, 2, 2, 2], proto: 6, payload: [])
        packet[0] = 0x42
        XCTAssertEqual(decode(packet, linkType: 101).summary.info, "Invalid IPv4 header")
    }

    func testRawIPAndLoopbackLinkTypes() {
        let packet = SyntheticCapture.ipv4(source: [127, 0, 0, 1], destination: [127, 0, 0, 1], proto: 17,
                                           payload: SyntheticCapture.udp(sourcePort: 9000, destinationPort: 123))
        XCTAssertEqual(decode(packet, linkType: 101).summary.serviceHint, "NTP")
        XCTAssertEqual(decode(packet, linkType: 228).summary.destinationPort, 123)
        XCTAssertEqual(decode([2, 0, 0, 0] + packet, linkType: 0).summary.source, "127.0.0.1")
        XCTAssertEqual(decode([0, 0, 0, 2] + packet, linkType: 0).summary.source, "127.0.0.1")
    }

    func testUnknownLinkTypeIsNotDecoded() {
        let detail = decode([1, 2, 3, 4], linkType: 127)
        XCTAssertEqual(detail.summary.protocolName, "Link 127")
        XCTAssertNil(detail.summary.source)
        XCTAssertEqual(detail.notes.count, 1)
    }

    func testIPv6Formatting() {
        var address = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(PacketDecoder.ipv6(address), "::")
        address[15] = 1
        XCTAssertEqual(PacketDecoder.ipv6(address), "::1")
        address = [0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0x02, 0x11, 0x22, 0xff, 0xfe, 0x33, 0x44, 0x55]
        XCTAssertEqual(PacketDecoder.ipv6(address), "fe80::211:22ff:fe33:4455")
        address = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1]
        XCTAssertEqual(PacketDecoder.ipv6(address), "2001:db8:0:1::1")
        address = [0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1]
        XCTAssertEqual(PacketDecoder.ipv6(address), "2001:db8:1:1:1:1:1:1")
        XCTAssertEqual(PacketDecoder.ipv6([1, 2]), "invalid")
    }

    func testHexDumpFormat() {
        let dump = Hex.dump(Array("Sentinel test 123".utf8))
        let lines = dump.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("0000  53 65 6e 74"))
        XCTAssertTrue(lines[0].hasSuffix("Sentinel test 12"))
        XCTAssertTrue(lines[1].hasPrefix("0010  33"))
        XCTAssertTrue(Hex.dump([UInt8](repeating: 0, count: 64), maxBytes: 16).contains("48 more bytes"))
    }
}

final class CaptureStoreTests: XCTestCase {
    private var directory: URL!
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("sentinel-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> CaptureStore {
        CaptureStore(directory: directory, now: { [unowned self] in self.clock })
    }

    func testSaveListLoadAndDelete() throws {
        let store = makeStore()
        XCTAssertTrue(store.list().isEmpty)
        let data = SyntheticCapture.demoCapture()
        let item = try store.save(data, originalName: "../../etc/evil\u{07}.pcap", format: .pcap, packetCount: 7)
        XCTAssertEqual(item.originalName, "evil.pcap")
        XCTAssertEqual(store.list(), [item])
        XCTAssertEqual(try store.data(for: item), data)
        try store.delete(id: item.id)
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertThrowsError(try store.data(for: item)) { XCTAssertEqual($0 as? CaptureStoreError, .notFound) }
        XCTAssertThrowsError(try store.delete(id: item.id))
    }

    func testRetentionPurgesOnlyExpiredCaptures() throws {
        let store = makeStore()
        let old = try store.save(Data([1]), originalName: "old.pcap", format: .pcap, packetCount: 0)
        clock = clock.addingTimeInterval(6 * 86_400)
        let recent = try store.save(Data([2]), originalName: "recent.pcapng", format: .pcapng, packetCount: 0)
        clock = clock.addingTimeInterval(2 * 86_400)

        XCTAssertTrue(store.purgeExpired(policy: .untilDeleted).isEmpty)
        XCTAssertTrue(store.purgeExpired(policy: .sessionOnly).isEmpty, "changing policy must never delete by itself")
        XCTAssertTrue(store.purgeExpired(policy: .thirtyDays).isEmpty)
        XCTAssertEqual(store.purgeExpired(policy: .sevenDays), [old])
        XCTAssertEqual(store.list(), [recent])
        XCTAssertEqual(store.purgeExpired(policy: .oneDay), [recent])
        XCTAssertTrue(store.list().isEmpty)
    }

    func testDeleteAllRemovesFiles() throws {
        let store = makeStore()
        try store.save(Data([1]), originalName: "a.pcap", format: .pcap, packetCount: 0)
        try store.save(Data([2]), originalName: "b.pcap", format: .pcap, packetCount: 0)
        XCTAssertEqual(try store.deleteAll(), 2)
        XCTAssertTrue(store.list().isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(remaining, ["index.json"])
    }

    func testRetentionPolicyDefaults() {
        XCTAssertFalse(RetentionPolicy.sessionOnly.savesImports)
        XCTAssertNil(RetentionPolicy.untilDeleted.maximumAge)
        XCTAssertEqual(RetentionPolicy.sevenDays.maximumAge, 604_800)
    }
}
