import Foundation

public enum CaptureFormat: String, Codable, Equatable {
    case pcap
    case pcapng

    public var displayName: String { self == .pcap ? "pcap" : "pcapng" }
}

/// Hard resource ceilings applied while parsing untrusted capture files.
public struct CaptureLimits: Equatable {
    public var maxFileBytes: Int
    public var maxPackets: Int
    public var maxPacketBytes: Int
    public var maxBlocks: Int
    public var maxInterfaces: Int

    public init(maxFileBytes: Int = 64 * 1024 * 1024,
                maxPackets: Int = 100_000,
                maxPacketBytes: Int = 262_144,
                maxBlocks: Int = 400_000,
                maxInterfaces: Int = 64) {
        self.maxFileBytes = maxFileBytes
        self.maxPackets = maxPackets
        self.maxPacketBytes = maxPacketBytes
        self.maxBlocks = maxBlocks
        self.maxInterfaces = maxInterfaces
    }

    public static let `default` = CaptureLimits()
}

public enum CaptureParseError: Error, Equatable {
    case empty
    case fileTooLarge(size: Int, limit: Int)
    case unrecognizedFormat
    case truncatedHeader
    case unsupportedVersion(major: Int, minor: Int)
    case malformed(String)

    public var userMessage: String {
        switch self {
        case .empty:
            return "The file is empty."
        case .fileTooLarge(let size, let limit):
            return "The file is \(size) bytes; Sentinel only opens captures up to \(limit) bytes."
        case .unrecognizedFormat:
            return "This is not a pcap or pcapng capture (unrecognised file signature)."
        case .truncatedHeader:
            return "The file ends before its capture header is complete."
        case .unsupportedVersion(let major, let minor):
            return "Capture format version \(major).\(minor) is not supported."
        case .malformed(let reason):
            return "The capture is malformed: \(reason)"
        }
    }
}

public struct PacketSummary: Equatable {
    public var source: String?
    public var destination: String?
    public var sourcePort: UInt16?
    public var destinationPort: UInt16?
    public var protocolName: String
    /// Guess based only on well-known port numbers; never a payload inspection result.
    public var serviceHint: String?
    public var info: String

    public init(source: String? = nil, destination: String? = nil, sourcePort: UInt16? = nil,
                destinationPort: UInt16? = nil, protocolName: String = "Unknown",
                serviceHint: String? = nil, info: String = "") {
        self.source = source
        self.destination = destination
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.protocolName = protocolName
        self.serviceHint = serviceHint
        self.info = info
    }

    public var sourceEndpoint: String { PacketSummary.endpoint(source, sourcePort) }
    public var destinationEndpoint: String { PacketSummary.endpoint(destination, destinationPort) }

    private static func endpoint(_ address: String?, _ port: UInt16?) -> String {
        guard let address = address else { return "—" }
        guard let port = port else { return address }
        return address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }
}

public struct PacketField: Equatable {
    public let label: String
    public let value: String
    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

public struct PacketLayer: Equatable {
    public let name: String
    public let fields: [PacketField]
}

public struct PacketDetail: Equatable {
    public let summary: PacketSummary
    public let layers: [PacketLayer]
    public let notes: [String]
}

public struct CapturedPacket: Identifiable, Equatable {
    /// 1-based position in the file.
    public let id: Int
    /// `nil` when the record type carries no timestamp (pcapng Simple Packet Block).
    public let timestamp: Date?
    public let capturedLength: Int
    public let originalLength: Int
    public let linkType: UInt32
    public let interfaceIndex: Int?
    /// Byte range of the packet inside `ParsedCapture.data`.
    public let range: Range<Int>
    public let summary: PacketSummary
}

/// Result of parsing an imported capture file. This is always file data;
/// Sentinel has no live-capture backend.
public struct ParsedCapture {
    public let format: CaptureFormat
    public let data: Data
    public let packets: [CapturedPacket]
    public let linkTypes: [UInt32]
    public let warnings: [String]
    /// True when parsing stopped because a limit was reached or the file was damaged.
    public let stoppedEarly: Bool

    public func bytes(of packet: CapturedPacket) -> [UInt8] {
        guard packet.range.lowerBound >= 0, packet.range.upperBound <= data.count else { return [] }
        return Array(data[packet.range])
    }

    public func detail(of packet: CapturedPacket) -> PacketDetail {
        PacketDecoder.decode(bytes(of: packet), linkType: packet.linkType, includeFields: true)
    }

    public var timeSpan: (first: Date, last: Date)? {
        let stamps = packets.compactMap { $0.timestamp }
        guard let first = stamps.min(), let last = stamps.max() else { return nil }
        return (first, last)
    }
}

public enum LinkType {
    public static func name(_ value: UInt32) -> String {
        switch value {
        case 0: return "BSD loopback"
        case 1: return "Ethernet"
        case 12, 101: return "Raw IP"
        case 113: return "Linux cooked (SLL)"
        case 228: return "Raw IPv4"
        case 229: return "Raw IPv6"
        case 276: return "Linux cooked v2 (SLL2)"
        case 105: return "IEEE 802.11"
        case 127: return "802.11 radiotap"
        default: return "Link type \(value)"
        }
    }
}
