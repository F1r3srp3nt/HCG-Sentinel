import Foundation

/// Defensive parser for classic pcap and pcapng files.
///
/// The input is treated as hostile: every length is checked against the
/// remaining bytes and against `CaptureLimits` before it is used, and damage
/// after the file header ends parsing with a warning rather than a crash.
public enum CaptureParser {
    private static let summaryPrefix = 600

    public static func parse(_ input: Data, limits: CaptureLimits = .default) throws -> ParsedCapture {
        guard !input.isEmpty else { throw CaptureParseError.empty }
        guard input.count <= limits.maxFileBytes else {
            throw CaptureParseError.fileTooLarge(size: input.count, limit: limits.maxFileBytes)
        }
        let data = input.startIndex == 0 ? input : Data(input)
        guard data.count >= 4 else { throw CaptureParseError.truncatedHeader }
        let magic = [data[0], data[1], data[2], data[3]]
        do {
            switch magic {
            case [0xd4, 0xc3, 0xb2, 0xa1]: return try parsePCAP(data, littleEndian: true, nanoseconds: false, limits: limits)
            case [0xa1, 0xb2, 0xc3, 0xd4]: return try parsePCAP(data, littleEndian: false, nanoseconds: false, limits: limits)
            case [0x4d, 0x3c, 0xb2, 0xa1]: return try parsePCAP(data, littleEndian: true, nanoseconds: true, limits: limits)
            case [0xa1, 0xb2, 0x3c, 0x4d]: return try parsePCAP(data, littleEndian: false, nanoseconds: true, limits: limits)
            case [0x0a, 0x0d, 0x0d, 0x0a]: return try parsePCAPNG(data, limits: limits)
            default: throw CaptureParseError.unrecognizedFormat
            }
        } catch let error as CaptureParseError {
            throw error
        } catch {
            throw CaptureParseError.malformed("unexpected end of data")
        }
    }

    private static func summary(_ data: Data, range: Range<Int>, linkType: UInt32) -> PacketSummary {
        let end = min(range.upperBound, range.lowerBound + summaryPrefix)
        return PacketDecoder.decode(Array(data[range.lowerBound..<end]), linkType: linkType, includeFields: false).summary
    }

    // MARK: - pcap

    private static func parsePCAP(_ data: Data, littleEndian: Bool, nanoseconds: Bool,
                                  limits: CaptureLimits) throws -> ParsedCapture {
        guard data.count >= 24 else { throw CaptureParseError.truncatedHeader }
        var cursor = ByteCursor(data, offset: 4, littleEndian: littleEndian)
        let major = Int(try cursor.u16())
        let minor = Int(try cursor.u16())
        guard major == 2 else { throw CaptureParseError.unsupportedVersion(major: major, minor: minor) }
        try cursor.skip(8) // thiszone + sigfigs
        _ = try cursor.u32() // snaplen: informational only, never trusted for allocation
        let linkType = try cursor.u32() & 0xffff

        var packets: [CapturedPacket] = []
        var warnings: [String] = []
        var stoppedEarly = false
        let divisor: Double = nanoseconds ? 1_000_000_000 : 1_000_000

        while cursor.remaining > 0 {
            if packets.count >= limits.maxPackets {
                warnings.append("Stopped after \(limits.maxPackets) packets (import limit).")
                stoppedEarly = true
                break
            }
            guard cursor.remaining >= 16 else {
                warnings.append("Ignored \(cursor.remaining) trailing bytes that do not form a record header.")
                stoppedEarly = true
                break
            }
            let seconds = try cursor.u32()
            let fraction = try cursor.u32()
            let captured = Int(try cursor.u32())
            let original = Int(try cursor.u32())
            let number = packets.count + 1
            guard captured <= limits.maxPacketBytes else {
                warnings.append("Record \(number) declares \(captured) bytes, above the \(limits.maxPacketBytes)-byte packet limit. Parsing stopped.")
                stoppedEarly = true
                break
            }
            guard captured <= cursor.remaining else {
                warnings.append("Record \(number) is truncated (declares \(captured) bytes, \(cursor.remaining) remain). Parsing stopped.")
                stoppedEarly = true
                break
            }
            let range = cursor.offset..<(cursor.offset + captured)
            try cursor.skip(captured)
            let timestamp = Date(timeIntervalSince1970: Double(seconds) + Double(fraction) / divisor)
            packets.append(CapturedPacket(id: number, timestamp: timestamp, capturedLength: captured,
                                          originalLength: original, linkType: linkType, interfaceIndex: nil,
                                          range: range, summary: summary(data, range: range, linkType: linkType)))
        }
        return ParsedCapture(format: .pcap, data: data, packets: packets, linkTypes: [linkType],
                             warnings: warnings, stoppedEarly: stoppedEarly)
    }

    // MARK: - pcapng

    private struct Interface {
        let linkType: UInt32
        let snapLength: Int
        let unitsPerSecond: Double
    }

    private static func parsePCAPNG(_ data: Data, limits: CaptureLimits) throws -> ParsedCapture {
        guard data.count >= 28 else { throw CaptureParseError.truncatedHeader }
        var packets: [CapturedPacket] = []
        var warnings: [String] = []
        var interfaces: [Interface] = []
        var linkTypes: [UInt32] = []
        var stoppedEarly = false
        var littleEndian = true
        var position = 0
        var blockCount = 0
        var sawSection = false

        func stop(_ message: String) {
            warnings.append(message)
            stoppedEarly = true
        }

        while position < data.count {
            guard data.count - position >= 12 else {
                stop("Ignored \(data.count - position) trailing bytes that do not form a block.")
                break
            }
            blockCount += 1
            if blockCount > limits.maxBlocks {
                stop("Stopped after \(limits.maxBlocks) blocks (import limit).")
                break
            }
            var head = ByteCursor(data, offset: position, littleEndian: littleEndian)
            let rawType = try head.u32()
            let isSectionHeader = data[position] == 0x0a && data[position + 1] == 0x0d
                && data[position + 2] == 0x0d && data[position + 3] == 0x0a

            if isSectionHeader {
                // The byte-order magic defines the endianness of this section, including the block length.
                let b = [data[position + 8], data[position + 9], data[position + 10], data[position + 11]]
                if b == [0x4d, 0x3c, 0x2b, 0x1a] {
                    littleEndian = true
                } else if b == [0x1a, 0x2b, 0x3c, 0x4d] {
                    littleEndian = false
                } else if sawSection {
                    stop("Section header at offset \(position) has an invalid byte-order magic. Parsing stopped.")
                    break
                } else {
                    throw CaptureParseError.malformed("invalid pcapng byte-order magic")
                }
                head.littleEndian = littleEndian
            } else if !sawSection {
                throw CaptureParseError.malformed("pcapng file does not start with a section header")
            }

            let totalLength = Int(try head.u32())
            guard totalLength >= 12, totalLength % 4 == 0, totalLength <= data.count - position else {
                if !sawSection { throw CaptureParseError.malformed("invalid section header length \(totalLength)") }
                stop("Block at offset \(position) has an invalid length (\(totalLength)). Parsing stopped.")
                break
            }
            var tail = ByteCursor(data, offset: position + totalLength - 4, littleEndian: littleEndian)
            guard Int(try tail.u32()) == totalLength else {
                if !sawSection { throw CaptureParseError.malformed("section header length fields disagree") }
                stop("Block at offset \(position) has mismatched length fields. Parsing stopped.")
                break
            }
            let bodyStart = position + 8
            let bodyLength = totalLength - 12
            var body = ByteCursor(data[bodyStart..<(bodyStart + bodyLength)], littleEndian: littleEndian)
            defer { position += totalLength }

            if isSectionHeader {
                guard bodyLength >= 16 else {
                    if !sawSection { throw CaptureParseError.truncatedHeader }
                    stop("Section header at offset \(position) is too short. Parsing stopped.")
                    break
                }
                try body.skip(4)
                let major = Int(try body.u16())
                let minor = Int(try body.u16())
                guard major == 1 else {
                    if !sawSection { throw CaptureParseError.unsupportedVersion(major: major, minor: minor) }
                    stop("Section at offset \(position) uses unsupported version \(major).\(minor). Parsing stopped.")
                    break
                }
                sawSection = true
                interfaces.removeAll()
                continue
            }

            switch rawType {
            case 1: // Interface Description Block
                guard interfaces.count < limits.maxInterfaces else {
                    stop("More than \(limits.maxInterfaces) interfaces declared. Parsing stopped.")
                    break
                }
                guard bodyLength >= 8 else {
                    stop("Interface block at offset \(position) is too short. Parsing stopped.")
                    break
                }
                let linkType = UInt32(try body.u16())
                try body.skip(2)
                let snap = Int(try body.u32())
                var units: Double = 1_000_000
                while body.remaining >= 4 {
                    let code = try body.u16()
                    let length = Int(try body.u16())
                    if code == 0 { break }
                    let padded = (length + 3) & ~3
                    guard padded <= body.remaining else { break }
                    let value = try body.take(padded)
                    if code == 9, length >= 1 {
                        let exponent = Double(value[0] & 0x7f)
                        units = (value[0] & 0x80) != 0 ? pow(2, exponent) : pow(10, exponent)
                    }
                }
                interfaces.append(Interface(linkType: linkType, snapLength: snap, unitsPerSecond: units))
                if !linkTypes.contains(linkType) { linkTypes.append(linkType) }

            case 6, 2: // Enhanced Packet Block / obsolete Packet Block
                guard bodyLength >= 20 else {
                    warnings.append("Skipped a packet block at offset \(position): too short.")
                    continue
                }
                let interfaceID: Int
                if rawType == 6 {
                    interfaceID = Int(try body.u32())
                } else {
                    interfaceID = Int(try body.u16())
                    try body.skip(2)
                }
                let high = UInt64(try body.u32())
                let low = UInt64(try body.u32())
                let captured = Int(try body.u32())
                let original = Int(try body.u32())
                guard interfaceID < interfaces.count else {
                    warnings.append("Skipped a packet at offset \(position): unknown interface \(interfaceID).")
                    continue
                }
                guard captured <= body.remaining else {
                    warnings.append("Skipped a packet at offset \(position): declared length exceeds its block.")
                    continue
                }
                guard captured <= limits.maxPacketBytes else {
                    warnings.append("Skipped a packet at offset \(position): \(captured) bytes exceeds the packet limit.")
                    continue
                }
                if packets.count >= limits.maxPackets {
                    stop("Stopped after \(limits.maxPackets) packets (import limit).")
                    break
                }
                let interface = interfaces[interfaceID]
                let start = bodyStart + 20
                let range = start..<(start + captured)
                let ticks = Double(high << 32 | low)
                let timestamp = Date(timeIntervalSince1970: ticks / max(interface.unitsPerSecond, 1))
                packets.append(CapturedPacket(id: packets.count + 1, timestamp: timestamp, capturedLength: captured,
                                              originalLength: original, linkType: interface.linkType,
                                              interfaceIndex: interfaceID, range: range,
                                              summary: summary(data, range: range, linkType: interface.linkType)))

            case 3: // Simple Packet Block
                guard bodyLength >= 4, let interface = interfaces.first else {
                    warnings.append("Skipped a simple packet block at offset \(position).")
                    continue
                }
                let original = Int(try body.u32())
                var captured = min(original, body.remaining)
                if interface.snapLength > 0 { captured = min(captured, interface.snapLength) }
                guard captured <= limits.maxPacketBytes else {
                    warnings.append("Skipped a packet at offset \(position): \(captured) bytes exceeds the packet limit.")
                    continue
                }
                if packets.count >= limits.maxPackets {
                    stop("Stopped after \(limits.maxPackets) packets (import limit).")
                    break
                }
                let start = bodyStart + 4
                let range = start..<(start + captured)
                packets.append(CapturedPacket(id: packets.count + 1, timestamp: nil, capturedLength: captured,
                                              originalLength: original, linkType: interface.linkType,
                                              interfaceIndex: 0, range: range,
                                              summary: summary(data, range: range, linkType: interface.linkType)))

            default:
                break // Name resolution, statistics, custom blocks: not needed for inspection.
            }
            if stoppedEarly { break }
        }

        return ParsedCapture(format: .pcapng, data: data, packets: packets, linkTypes: linkTypes,
                             warnings: warnings, stoppedEarly: stoppedEarly)
    }
}
