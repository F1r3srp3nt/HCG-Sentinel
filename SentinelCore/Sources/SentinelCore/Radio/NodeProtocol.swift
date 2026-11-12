import Foundation

/// Sentinel Node Protocol (SNP), version 1. See docs/NODE_PROTOCOL.md.
///
/// JSON text messages over a WebSocket. Every message is an envelope
/// `{"v":1,"type":"…","id":"…","payload":{…}}`. Version 1 is receive-side
/// analysis only: it defines no transmit, tuning-for-transmit or baseband operation.
public enum NodeProtocol {
    public static let version = 1
    public static let supportedVersions = [1]
    public static let maxMessageBytes = 1_048_576
    public static let maxBins = 8192
    public static let minBins = 16
    public static let handshakeTimeout: TimeInterval = 10
    public static let spectrumFeature = "spectrum"
}

public struct ClientHello: Codable, Equatable {
    public var protocolVersions: [Int]
    public var client: String
    public var clientVersion: String
    public var authToken: String?
}

public struct NodeHelloAck: Codable, Equatable {
    public var protocolVersion: Int
    public var nodeName: String
    public var nodeSoftware: String
    /// True when the node generates test data instead of reading radio hardware.
    public var simulated: Bool
}

public struct NodeHardware: Codable, Equatable, Identifiable {
    public var id: String
    public var driver: String
    public var description: String
    public var minFrequencyHz: Double
    public var maxFrequencyHz: Double
    public var maxSpanHz: Double
}

public struct NodeCapabilities: Codable, Equatable {
    public var features: [String]
    public var hardware: [NodeHardware]
    public var maxBins: Int
}

public struct NodeStatus: Codable, Equatable {
    /// "idle", "streaming" or "error".
    public var state: String
    public var hardwarePresent: Bool
    public var activeHardwareID: String?
    public var message: String?
}

public struct SpectrumRequest: Codable, Equatable {
    public var hardwareID: String
    public var centerFrequencyHz: Double
    public var spanHz: Double
    public var bins: Int
    public var maxFramesPerSecond: Double

    public init(hardwareID: String, centerFrequencyHz: Double, spanHz: Double, bins: Int = 512, maxFramesPerSecond: Double = 5) {
        self.hardwareID = hardwareID
        self.centerFrequencyHz = centerFrequencyHz
        self.spanHz = spanHz
        self.bins = bins
        self.maxFramesPerSecond = maxFramesPerSecond
    }
}

public struct SpectrumFrame: Codable, Equatable {
    public var sequence: Int
    /// Unix time in seconds, as reported by the node.
    public var timestamp: Double
    public var centerFrequencyHz: Double
    public var spanHz: Double
    /// Unit of `powers`; version 1 uses "dBFS".
    public var unit: String
    public var powers: [Double]

    public init(sequence: Int, timestamp: Double, centerFrequencyHz: Double, spanHz: Double, unit: String = "dBFS", powers: [Double]) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.centerFrequencyHz = centerFrequencyHz
        self.spanHz = spanHz
        self.unit = unit
        self.powers = powers
    }
}

public struct NodeErrorPayload: Codable, Equatable {
    public var code: String
    public var message: String
}

public enum ClientMessage: Equatable {
    case hello(ClientHello)
    case getCapabilities
    case getStatus
    case subscribeSpectrum(SpectrumRequest)
    case unsubscribeSpectrum
    case ping
    case bye
}

public enum NodeMessage: Equatable {
    case helloAck(NodeHelloAck)
    case capabilities(NodeCapabilities)
    case status(NodeStatus)
    case spectrumFrame(SpectrumFrame)
    case error(NodeErrorPayload)
    case pong
}

public enum NodeProtocolError: Error, Equatable {
    case messageTooLarge(Int)
    case notJSON
    case unsupportedVersion(Int)
    case unknownType(String)
    case missingPayload(String)
    case invalidPayload(String)

    public var userMessage: String {
        switch self {
        case .messageTooLarge(let size): return "The node sent a \(size)-byte message, above the protocol limit."
        case .notJSON: return "The node sent data that is not a valid protocol message."
        case .unsupportedVersion(let version): return "The node speaks protocol version \(version); this app supports version \(NodeProtocol.version)."
        case .unknownType(let type): return "The node sent an unknown message type “\(type)”."
        case .missingPayload(let type): return "The node’s “\(type)” message has no payload."
        case .invalidPayload(let reason): return "The node sent invalid data: \(reason)"
        }
    }
}

public enum NodeCodec {
    private struct Header: Decodable {
        let v: Int
        let type: String
    }

    private struct Envelope<Payload: Codable>: Codable {
        let v: Int
        let type: String
        let id: String?
        let payload: Payload?
    }

    private struct Empty: Codable {}

    public static func encode(_ message: ClientMessage, id: String? = nil) -> String {
        func render<P: Codable>(_ type: String, _ payload: P?) -> String {
            let envelope = Envelope(v: NodeProtocol.version, type: type, id: id, payload: payload)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(envelope), let text = String(data: data, encoding: .utf8) else { return "{}" }
            return text
        }
        let none: Empty? = nil
        switch message {
        case .hello(let hello): return render("hello", hello)
        case .getCapabilities: return render("get_capabilities", none)
        case .getStatus: return render("get_status", none)
        case .subscribeSpectrum(let request): return render("subscribe_spectrum", request)
        case .unsubscribeSpectrum: return render("unsubscribe_spectrum", none)
        case .ping: return render("ping", none)
        case .bye: return render("bye", none)
        }
    }

    public static func decode(_ text: String) throws -> NodeMessage {
        let data = Data(text.utf8)
        guard data.count <= NodeProtocol.maxMessageBytes else { throw NodeProtocolError.messageTooLarge(data.count) }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { throw NodeProtocolError.notJSON }
        guard NodeProtocol.supportedVersions.contains(header.v) else { throw NodeProtocolError.unsupportedVersion(header.v) }

        func payload<P: Codable>(_ type: P.Type) throws -> P {
            let envelope: Envelope<P>
            do {
                envelope = try decoder.decode(Envelope<P>.self, from: data)
            } catch {
                throw NodeProtocolError.invalidPayload("“\(header.type)” does not match the version \(header.v) schema")
            }
            guard let value = envelope.payload else { throw NodeProtocolError.missingPayload(header.type) }
            return value
        }

        switch header.type {
        case "hello_ack":
            let ack = try payload(NodeHelloAck.self)
            guard NodeProtocol.supportedVersions.contains(ack.protocolVersion) else {
                throw NodeProtocolError.unsupportedVersion(ack.protocolVersion)
            }
            return .helloAck(ack)
        case "capabilities":
            let capabilities = try payload(NodeCapabilities.self)
            guard capabilities.hardware.count <= 32, capabilities.features.count <= 64 else {
                throw NodeProtocolError.invalidPayload("too many hardware or feature entries")
            }
            return .capabilities(capabilities)
        case "status":
            return .status(try payload(NodeStatus.self))
        case "spectrum_frame":
            let frame = try payload(SpectrumFrame.self)
            try validate(frame)
            return .spectrumFrame(frame)
        case "error":
            return .error(try payload(NodeErrorPayload.self))
        case "pong":
            return .pong
        default:
            throw NodeProtocolError.unknownType(String(header.type.prefix(40)))
        }
    }

    public static func validate(_ frame: SpectrumFrame) throws {
        guard frame.powers.count >= NodeProtocol.minBins, frame.powers.count <= NodeProtocol.maxBins else {
            throw NodeProtocolError.invalidPayload("spectrum frame has \(frame.powers.count) bins (allowed \(NodeProtocol.minBins)–\(NodeProtocol.maxBins))")
        }
        guard frame.spanHz > 0, frame.spanHz.isFinite, frame.centerFrequencyHz >= 0, frame.centerFrequencyHz.isFinite else {
            throw NodeProtocolError.invalidPayload("spectrum frame has an invalid frequency range")
        }
        guard frame.unit == "dBFS" else {
            throw NodeProtocolError.invalidPayload("unsupported power unit “\(String(frame.unit.prefix(16)))”")
        }
        guard frame.powers.allSatisfy({ $0.isFinite && $0 >= -300 && $0 <= 100 }) else {
            throw NodeProtocolError.invalidPayload("spectrum frame contains out-of-range power values")
        }
    }
}
