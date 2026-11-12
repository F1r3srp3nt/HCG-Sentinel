import Foundation

/// Decodes link, network and transport headers of a single captured packet.
/// Payloads are never interpreted or decrypted; service names are port-number hints only.
public enum PacketDecoder {
    public static func decode(_ bytes: [UInt8], linkType: UInt32, includeFields: Bool) -> PacketDetail {
        var context = Context(includeFields: includeFields)
        do {
            try decodeLink(bytes[...], linkType: linkType, context: &context)
        } catch {
            context.notes.append("Packet data ends inside the \(context.currentLayer) header (truncated capture).")
            if context.summary.info.isEmpty {
                context.summary.info = "Truncated \(context.currentLayer) header"
            } else {
                context.summary.info += " [truncated]"
            }
        }
        return PacketDetail(summary: context.summary, layers: context.layers, notes: context.notes)
    }

    // MARK: - Context

    private struct Context {
        let includeFields: Bool
        var summary = PacketSummary()
        var layers: [PacketLayer] = []
        var notes: [String] = []
        var currentLayer = "link"

        mutating func add(_ name: String, _ fields: @autoclosure () -> [PacketField]) {
            if includeFields { layers.append(PacketLayer(name: name, fields: fields())) }
        }
    }

    private typealias Slice = ArraySlice<UInt8>

    // MARK: - Link layer

    private static func decodeLink(_ bytes: Slice, linkType: UInt32, context: inout Context) throws {
        switch linkType {
        case 1:
            try decodeEthernet(bytes, context: &context)
        case 12, 101:
            try decodeRawIP(bytes, context: &context)
        case 228:
            try decodeIPv4(bytes, context: &context)
        case 229:
            try decodeIPv6(bytes, context: &context)
        case 0:
            context.currentLayer = "loopback"
            var cursor = ByteCursor(bytes, littleEndian: true)
            let little = try cursor.u32()
            let family = little <= 0xff ? little : little.byteSwapped
            context.add("BSD loopback", [PacketField("Address family", "\(family)")])
            let rest = bytes.dropFirst(4)
            if family == 2 {
                try decodeIPv4(rest, context: &context)
            } else if [24, 28, 30, 10].contains(family) {
                try decodeIPv6(rest, context: &context)
            } else {
                context.summary.protocolName = "Loopback"
                context.summary.info = "Address family \(family)"
            }
        case 113:
            context.currentLayer = "Linux cooked"
            var cursor = ByteCursor(bytes)
            let packetType = try cursor.u16()
            try cursor.skip(12)
            let proto = try cursor.u16()
            context.add("Linux cooked capture", [PacketField("Packet type", "\(packetType)"),
                                                 PacketField("Protocol", etherTypeName(proto))])
            try decodeNetwork(etherType: proto, bytes.dropFirst(16), context: &context)
        case 276:
            context.currentLayer = "Linux cooked v2"
            var cursor = ByteCursor(bytes)
            let proto = try cursor.u16()
            try cursor.skip(18)
            context.add("Linux cooked capture v2", [PacketField("Protocol", etherTypeName(proto))])
            try decodeNetwork(etherType: proto, bytes.dropFirst(20), context: &context)
        default:
            context.summary.protocolName = "Link \(linkType)"
            context.summary.info = "\(LinkType.name(linkType)) frames are not decoded (\(bytes.count) bytes)"
            context.notes.append("Sentinel does not decode \(LinkType.name(linkType)) frames; raw bytes are shown.")
        }
    }

    private static func decodeEthernet(_ bytes: Slice, context: inout Context) throws {
        context.currentLayer = "Ethernet"
        var cursor = ByteCursor(bytes)
        let destination = mac(try cursor.take(6))
        let source = mac(try cursor.take(6))
        var etherType = try cursor.u16()
        var fields = [PacketField("Destination", destination), PacketField("Source", source)]
        var tags = 0
        while (etherType == 0x8100 || etherType == 0x88a8) && tags < 2 {
            let tci = try cursor.u16()
            fields.append(PacketField("VLAN", "\(tci & 0x0fff)"))
            etherType = try cursor.u16()
            tags += 1
        }
        fields.append(PacketField("EtherType", etherTypeName(etherType)))
        context.add("Ethernet", fields)
        context.summary.source = source
        context.summary.destination = destination
        try decodeNetwork(etherType: etherType, bytes.dropFirst(cursor.offset), context: &context)
    }

    private static func decodeNetwork(etherType: UInt16, _ bytes: Slice, context: inout Context) throws {
        switch etherType {
        case 0x0800: try decodeIPv4(bytes, context: &context)
        case 0x86dd: try decodeIPv6(bytes, context: &context)
        case 0x0806: try decodeARP(bytes, context: &context)
        default:
            context.summary.protocolName = etherType <= 1500 ? "802.3" : String(format: "0x%04x", etherType)
            context.summary.info = "\(etherTypeName(etherType)), \(bytes.count) bytes"
        }
    }

    private static func decodeRawIP(_ bytes: Slice, context: inout Context) throws {
        context.currentLayer = "IP"
        var cursor = ByteCursor(bytes)
        let version = try cursor.u8() >> 4
        if version == 4 {
            try decodeIPv4(bytes, context: &context)
        } else if version == 6 {
            try decodeIPv6(bytes, context: &context)
        } else {
            context.summary.protocolName = "Raw"
            context.summary.info = "Unknown IP version \(version)"
        }
    }

    // MARK: - Network layer

    private static func decodeARP(_ bytes: Slice, context: inout Context) throws {
        context.currentLayer = "ARP"
        var cursor = ByteCursor(bytes)
        let hardware = try cursor.u16()
        let proto = try cursor.u16()
        let hardwareLength = Int(try cursor.u8())
        let protoLength = Int(try cursor.u8())
        let operation = try cursor.u16()
        context.summary.protocolName = "ARP"
        guard hardware == 1, proto == 0x0800, hardwareLength == 6, protoLength == 4 else {
            context.summary.info = "ARP operation \(operation) (non-Ethernet/IPv4)"
            return
        }
        let senderMAC = mac(try cursor.take(6))
        let senderIP = ipv4(try cursor.take(4))
        let targetMAC = mac(try cursor.take(6))
        let targetIP = ipv4(try cursor.take(4))
        switch operation {
        case 1: context.summary.info = "Who has \(targetIP)? Tell \(senderIP)"
        case 2: context.summary.info = "\(senderIP) is at \(senderMAC)"
        default: context.summary.info = "ARP operation \(operation)"
        }
        context.add("ARP", [PacketField("Operation", operation == 1 ? "request (1)" : operation == 2 ? "reply (2)" : "\(operation)"),
                            PacketField("Sender MAC", senderMAC), PacketField("Sender IP", senderIP),
                            PacketField("Target MAC", targetMAC), PacketField("Target IP", targetIP)])
    }

    private static func decodeIPv4(_ bytes: Slice, context: inout Context) throws {
        context.currentLayer = "IPv4"
        var cursor = ByteCursor(bytes)
        let versionAndLength = try cursor.u8()
        let headerLength = Int(versionAndLength & 0x0f) * 4
        guard versionAndLength >> 4 == 4, headerLength >= 20 else {
            context.summary.protocolName = "IPv4"
            context.summary.info = "Invalid IPv4 header"
            context.notes.append("IPv4 header has an invalid version or length field.")
            return
        }
        try cursor.skip(1)
        let totalLength = Int(try cursor.u16())
        let identification = try cursor.u16()
        let flagsAndOffset = try cursor.u16()
        let ttl = try cursor.u8()
        let proto = try cursor.u8()
        try cursor.skip(2)
        let source = ipv4(try cursor.take(4))
        let destination = ipv4(try cursor.take(4))
        try cursor.skip(headerLength - 20)
        let fragmentOffset = Int(flagsAndOffset & 0x1fff) * 8
        let moreFragments = flagsAndOffset & 0x2000 != 0
        context.summary.source = source
        context.summary.destination = destination
        context.add("IPv4", [PacketField("Source", source), PacketField("Destination", destination),
                             PacketField("Protocol", ipProtocolName(proto)), PacketField("TTL", "\(ttl)"),
                             PacketField("Total length", "\(totalLength)"),
                             PacketField("Identification", String(format: "0x%04x", identification)),
                             PacketField("Fragment offset", "\(fragmentOffset)\(moreFragments ? " (more fragments)" : "")")])
        if fragmentOffset != 0 {
            context.summary.protocolName = ipProtocolName(proto)
            context.summary.info = "IPv4 fragment (offset \(fragmentOffset)); transport header not present"
            return
        }
        let payloadLength = totalLength >= headerLength ? totalLength - headerLength : nil
        try decodeTransport(proto, bytes.dropFirst(headerLength), payloadLength: payloadLength, context: &context)
    }

    private static func decodeIPv6(_ bytes: Slice, context: inout Context) throws {
        context.currentLayer = "IPv6"
        var cursor = ByteCursor(bytes)
        let first = try cursor.u8()
        guard first >> 4 == 6 else {
            context.summary.protocolName = "IPv6"
            context.summary.info = "Invalid IPv6 header"
            return
        }
        try cursor.skip(3)
        let payloadLength = Int(try cursor.u16())
        var nextHeader = try cursor.u8()
        let hopLimit = try cursor.u8()
        let source = ipv6(try cursor.take(16))
        let destination = ipv6(try cursor.take(16))
        context.summary.source = source
        context.summary.destination = destination
        var consumed = 0
        var extensions: [String] = []
        var steps = 0
        while [0, 43, 60, 44].contains(nextHeader) && steps < 8 {
            steps += 1
            let following = try cursor.u8()
            if nextHeader == 44 {
                try cursor.skip(1)
                let offsetField = try cursor.u16()
                try cursor.skip(4)
                consumed += 8
                extensions.append("fragment")
                if offsetField >> 3 != 0 {
                    context.add("IPv6", ipv6Fields(source, destination, nextHeader, hopLimit, payloadLength, extensions))
                    context.summary.protocolName = ipProtocolName(following)
                    context.summary.info = "IPv6 fragment (offset \(Int(offsetField >> 3) * 8)); transport header not present"
                    return
                }
            } else {
                let length = (Int(try cursor.u8()) + 1) * 8
                try cursor.skip(length - 2)
                consumed += length
                extensions.append(nextHeader == 0 ? "hop-by-hop" : nextHeader == 43 ? "routing" : "destination options")
            }
            nextHeader = following
        }
        context.add("IPv6", ipv6Fields(source, destination, nextHeader, hopLimit, payloadLength, extensions))
        let remainingPayload = payloadLength >= consumed ? payloadLength - consumed : nil
        try decodeTransport(nextHeader, bytes.dropFirst(cursor.offset), payloadLength: remainingPayload, context: &context)
    }

    private static func ipv6Fields(_ source: String, _ destination: String, _ next: UInt8, _ hop: UInt8,
                                   _ payload: Int, _ extensions: [String]) -> [PacketField] {
        var fields = [PacketField("Source", source), PacketField("Destination", destination),
                      PacketField("Next header", ipProtocolName(next)), PacketField("Hop limit", "\(hop)"),
                      PacketField("Payload length", "\(payload)")]
        if !extensions.isEmpty { fields.append(PacketField("Extension headers", extensions.joined(separator: ", "))) }
        return fields
    }

    // MARK: - Transport layer

    private static func decodeTransport(_ proto: UInt8, _ bytes: Slice, payloadLength: Int?,
                                        context: inout Context) throws {
        context.summary.protocolName = ipProtocolName(proto)
        switch proto {
        case 6:
            context.currentLayer = "TCP"
            var cursor = ByteCursor(bytes)
            let sourcePort = try cursor.u16()
            let destinationPort = try cursor.u16()
            let sequence = try cursor.u32()
            let acknowledgement = try cursor.u32()
            let offsetAndFlags = try cursor.u16()
            let window = try cursor.u16()
            let headerLength = Int(offsetAndFlags >> 12) * 4
            let flags = tcpFlags(offsetAndFlags)
            let dataLength = payloadLength.map { max(0, $0 - headerLength) }
            context.summary.sourcePort = sourcePort
            context.summary.destinationPort = destinationPort
            context.summary.serviceHint = serviceHint(sourcePort, destinationPort, tcp: true)
            var info = "[\(flags.joined(separator: ", "))] Seq=\(sequence)"
            if offsetAndFlags & 0x10 != 0 { info += " Ack=\(acknowledgement)" }
            info += " Win=\(window)"
            if let dataLength = dataLength { info += " Len=\(dataLength)" }
            context.summary.info = info
            context.add("TCP", [PacketField("Source port", "\(sourcePort)"),
                                PacketField("Destination port", "\(destinationPort)"),
                                PacketField("Sequence", "\(sequence)"), PacketField("Acknowledgement", "\(acknowledgement)"),
                                PacketField("Flags", flags.joined(separator: ", ")),
                                PacketField("Window", "\(window)"), PacketField("Header length", "\(headerLength)"),
                                PacketField("Payload length", dataLength.map { "\($0)" } ?? "unknown")])
            if headerLength < 20 { context.notes.append("TCP data offset is below the 20-byte minimum.") }
        case 17:
            context.currentLayer = "UDP"
            var cursor = ByteCursor(bytes)
            let sourcePort = try cursor.u16()
            let destinationPort = try cursor.u16()
            let length = Int(try cursor.u16())
            context.summary.sourcePort = sourcePort
            context.summary.destinationPort = destinationPort
            context.summary.serviceHint = serviceHint(sourcePort, destinationPort, tcp: false)
            context.summary.info = "Len=\(max(0, length - 8))"
            context.add("UDP", [PacketField("Source port", "\(sourcePort)"),
                                PacketField("Destination port", "\(destinationPort)"),
                                PacketField("Length", "\(length)")])
        case 1, 58:
            context.currentLayer = proto == 1 ? "ICMP" : "ICMPv6"
            var cursor = ByteCursor(bytes)
            let type = try cursor.u8()
            let code = try cursor.u8()
            let name = proto == 1 ? icmpName(type) : icmpv6Name(type)
            context.summary.info = "\(name) (type \(type), code \(code))"
            context.add(context.currentLayer, [PacketField("Type", "\(type) – \(name)"), PacketField("Code", "\(code)")])
        default:
            context.summary.info = "\(ipProtocolName(proto)) payload, \(payloadLength ?? bytes.count) bytes"
        }
    }

    // MARK: - Formatting

    static func mac(_ bytes: [UInt8]) -> String { Hex.string(bytes, separator: ":") }

    static func ipv4(_ bytes: [UInt8]) -> String { bytes.map { String($0) }.joined(separator: ".") }

    /// RFC 5952 style: lowercase, longest zero run (two or more groups) compressed.
    public static func ipv6(_ bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return "invalid" }
        let groups = (0..<8).map { UInt16(bytes[2 * $0]) << 8 | UInt16(bytes[2 * $0 + 1]) }
        var bestStart = -1, bestLength = 0, runStart = -1, runLength = 0
        for (index, group) in groups.enumerated() {
            if group == 0 {
                if runStart < 0 { runStart = index; runLength = 0 }
                runLength += 1
                if runLength > bestLength { bestStart = runStart; bestLength = runLength }
            } else {
                runStart = -1
            }
        }
        let text: (ArraySlice<UInt16>) -> String = { $0.map { String($0, radix: 16) }.joined(separator: ":") }
        guard bestLength >= 2 else { return text(groups[...]) }
        return text(groups[0..<bestStart]) + "::" + text(groups[(bestStart + bestLength)...])
    }

    private static func tcpFlags(_ value: UInt16) -> [String] {
        let names: [(UInt16, String)] = [(0x02, "SYN"), (0x01, "FIN"), (0x04, "RST"), (0x08, "PSH"),
                                         (0x10, "ACK"), (0x20, "URG"), (0x40, "ECE"), (0x80, "CWR")]
        let set = names.filter { value & $0.0 != 0 }.map { $0.1 }
        return set.isEmpty ? ["none"] : set
    }

    private static func etherTypeName(_ value: UInt16) -> String {
        switch value {
        case 0x0800: return "IPv4 (0x0800)"
        case 0x86dd: return "IPv6 (0x86dd)"
        case 0x0806: return "ARP (0x0806)"
        case 0x88cc: return "LLDP (0x88cc)"
        case 0x888e: return "EAPOL (0x888e)"
        default: return String(format: "0x%04x", value)
        }
    }

    private static func ipProtocolName(_ value: UInt8) -> String {
        switch value {
        case 1: return "ICMP"
        case 2: return "IGMP"
        case 6: return "TCP"
        case 17: return "UDP"
        case 41: return "IPv6-in-IP"
        case 47: return "GRE"
        case 50: return "ESP"
        case 51: return "AH"
        case 58: return "ICMPv6"
        case 132: return "SCTP"
        default: return "IP proto \(value)"
        }
    }

    private static func icmpName(_ type: UInt8) -> String {
        switch type {
        case 0: return "Echo reply"
        case 3: return "Destination unreachable"
        case 5: return "Redirect"
        case 8: return "Echo request"
        case 11: return "Time exceeded"
        default: return "ICMP"
        }
    }

    private static func icmpv6Name(_ type: UInt8) -> String {
        switch type {
        case 1: return "Destination unreachable"
        case 2: return "Packet too big"
        case 3: return "Time exceeded"
        case 128: return "Echo request"
        case 129: return "Echo reply"
        case 133: return "Router solicitation"
        case 134: return "Router advertisement"
        case 135: return "Neighbor solicitation"
        case 136: return "Neighbor advertisement"
        default: return "ICMPv6"
        }
    }

    private static func serviceHint(_ a: UInt16, _ b: UInt16, tcp: Bool) -> String? {
        for port in [min(a, b), max(a, b)] {
            switch (port, tcp) {
            case (22, true): return "SSH"
            case (53, _): return "DNS"
            case (67, false), (68, false): return "DHCP"
            case (80, true), (8080, true): return "HTTP"
            case (123, false): return "NTP"
            case (443, true): return "TLS/HTTPS"
            case (443, false): return "QUIC"
            case (853, true): return "DNS over TLS"
            case (1900, false): return "SSDP"
            case (5353, false): return "mDNS"
            default: continue
            }
        }
        return nil
    }
}
