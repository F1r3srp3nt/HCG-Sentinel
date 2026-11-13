import Foundation

/// Sentinel Node Protocol (SNP), version 2. See docs/NODE_PROTOCOL.md.
///
/// JSON text messages over a WebSocket. Every message is an envelope
/// `{"v":2,"type":"…","seq":n,"payload":"<JSON text>","mac":"<base64>"}`.
///
/// Version 2 adds mutual authentication with a pre-shared pairing key. The node's capability report travels
/// inside the authenticated challenge, and every message after the handshake carries a sequence number and an
/// HMAC, so a node is only treated as connected once it has proved it holds the key. Version 1 (unauthenticated)
/// is no longer accepted.
///
/// The protocol is receive-side analysis only: it defines no transmit, injection, tuning-for-transmit, monitor-mode
/// switching or baseband operation.
public enum NodeProtocol {
    public static let version = 2
    public static let supportedVersions = [2]
    public static let maxMessageBytes = 1_048_576
    public static let maxBins = 8192
    public static let minBins = 16
    public static let maxWifiNetworks = 512
    public static let handshakeTimeout: TimeInterval = 10
    public static let requestTimeout: TimeInterval = 30
    public static let nonceBytes = 32
    public static let minimumKeyBytes = 32
    public static let context = "snp-v2"

    public static let spectrumFeature = "spectrum"
    public static let wifiScanFeature = "wifi_scan"
    /// Features this client understands. Anything else a node lists is ignored.
    public static let knownFeatures: Set<String> = [spectrumFeature, wifiScanFeature]
}

// MARK: - Payloads

public struct ClientHello: Codable, Equatable {
    public var protocolVersions: [Int]
    public var client: String
    public var clientVersion: String
    public var clientNonce: String
}

public struct NodeInfo: Codable, Equatable {
    public var nodeName: String
    public var nodeSoftware: String
    /// True when the node generates test data instead of reading radio hardware.
    public var simulated: Bool

    public init(nodeName: String, nodeSoftware: String, simulated: Bool) {
        self.nodeName = nodeName
        self.nodeSoftware = nodeSoftware
        self.simulated = simulated
    }
}

public struct NodeHardware: Codable, Equatable, Identifiable {
    public var id: String
    public var driver: String
    public var description: String
    public var minFrequencyHz: Double
    public var maxFrequencyHz: Double
    public var maxSpanHz: Double

    public init(id: String, driver: String, description: String, minFrequencyHz: Double, maxFrequencyHz: Double, maxSpanHz: Double) {
        self.id = id
        self.driver = driver
        self.description = description
        self.minFrequencyHz = minFrequencyHz
        self.maxFrequencyHz = maxFrequencyHz
        self.maxSpanHz = maxSpanHz
    }
}

public struct NodeCapabilities: Codable, Equatable {
    public var features: [String]
    public var hardware: [NodeHardware]
    public var maxBins: Int

    public init(features: [String], hardware: [NodeHardware], maxBins: Int) {
        self.features = features
        self.hardware = hardware
        self.maxBins = maxBins
    }

    /// Features this client recognises. Unknown strings never enable anything.
    public var recognizedFeatures: Set<String> {
        Set(features).intersection(NodeProtocol.knownFeatures)
    }
}

/// Sent by the node in answer to `hello`. Authenticated as a whole by the envelope MAC.
public struct NodeChallenge: Codable, Equatable {
    public var protocolVersion: Int
    public var nodeNonce: String
    public var node: NodeInfo
    public var capabilities: NodeCapabilities

    public init(protocolVersion: Int, nodeNonce: String, node: NodeInfo, capabilities: NodeCapabilities) {
        self.protocolVersion = protocolVersion
        self.nodeNonce = nodeNonce
        self.node = node
        self.capabilities = capabilities
    }
}

public struct NodeStatus: Codable, Equatable {
    /// "idle", "streaming", "scanning" or "error".
    public var state: String
    public var hardwarePresent: Bool
    public var activeHardwareID: String?
    public var message: String?

    public init(state: String, hardwarePresent: Bool, activeHardwareID: String? = nil, message: String? = nil) {
        self.state = state
        self.hardwarePresent = hardwarePresent
        self.activeHardwareID = activeHardwareID
        self.message = message
    }
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
    /// Unit of `powers`; "dBFS".
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

public struct WifiScanRequest: Codable, Equatable {
    public var hardwareID: String?
    public init(hardwareID: String? = nil) { self.hardwareID = hardwareID }
}

public struct WifiNetwork: Codable, Equatable, Identifiable {
    /// Nil for a hidden network.
    public var ssid: String?
    public var bssid: String
    public var channel: Int
    public var frequencyMHz: Int
    public var rssiDbm: Int
    /// "open", "wep", "wpa", "wpa2", "wpa3", "wpa2-enterprise", "wpa3-enterprise", "owe" or "unknown".
    public var security: String

    public var id: String { bssid }

    public init(ssid: String?, bssid: String, channel: Int, frequencyMHz: Int, rssiDbm: Int, security: String) {
        self.ssid = ssid
        self.bssid = bssid
        self.channel = channel
        self.frequencyMHz = frequencyMHz
        self.rssiDbm = rssiDbm
        self.security = security
    }
}

public struct WifiScanResult: Codable, Equatable {
    /// Unix time in seconds, as reported by the node.
    public var scannedAt: Double
    /// The node's own interface that performed the scan, e.g. "wlan0".
    public var interface: String
    public var networks: [WifiNetwork]

    public init(scannedAt: Double, interface: String, networks: [WifiNetwork]) {
        self.scannedAt = scannedAt
        self.interface = interface
        self.networks = networks
    }
}

public struct NodeErrorPayload: Codable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct EmptyPayload: Codable, Equatable {
    public init() {}
}

// MARK: - Envelope

public struct NodeEnvelope: Codable, Equatable {
    public var v: Int
    public var type: String
    public var seq: Int?
    /// The payload as JSON text, so the MAC covers exact bytes.
    public var payload: String?
    public var mac: String?

    public init(v: Int = NodeProtocol.version, type: String, seq: Int? = nil, payload: String? = nil, mac: String? = nil) {
        self.v = v
        self.type = type
        self.seq = seq
        self.payload = payload
        self.mac = mac
    }
}

public enum NodeMessageType {
    // Client → node
    public static let hello = "hello"
    public static let authenticate = "authenticate"
    public static let getStatus = "get_status"
    public static let subscribeSpectrum = "subscribe_spectrum"
    public static let unsubscribeSpectrum = "unsubscribe_spectrum"
    public static let getWifiScan = "get_wifi_scan"
    public static let ping = "ping"
    public static let bye = "bye"
    // Node → client
    public static let challenge = "challenge"
    public static let ready = "ready"
    public static let status = "status"
    public static let spectrumFrame = "spectrum_frame"
    public static let wifiScan = "wifi_scan"
    public static let error = "error"
    public static let pong = "pong"

    public static let fromNode: Set<String> = [challenge, ready, status, spectrumFrame, wifiScan, error, pong]
}

public enum NodeProtocolError: Error, Equatable {
    case messageTooLarge(Int)
    case notJSON
    case unsupportedVersion(Int)
    case unknownType(String)
    case missingPayload(String)
    case invalidPayload(String)
    case authenticationFailed(String)
    case outOfOrder(String)

    public var userMessage: String {
        switch self {
        case .messageTooLarge(let size): return "The node sent a \(size)-byte message, above the protocol limit."
        case .notJSON: return "The node sent data that is not a valid protocol message."
        case .unsupportedVersion(let version):
            return "The node speaks protocol version \(version); this app requires version \(NodeProtocol.version) (authenticated). Update the node software."
        case .unknownType(let type): return "The node sent an unknown message type “\(type)”."
        case .missingPayload(let type): return "The node’s “\(type)” message has no payload."
        case .invalidPayload(let reason): return "The node sent invalid data: \(reason)"
        case .authenticationFailed(let reason): return "Authentication failed: \(reason)"
        case .outOfOrder(let reason): return "The node broke the protocol sequence: \(reason)"
        }
    }
}

// MARK: - Codec

public enum NodeCodec {
    private struct Header: Decodable {
        let v: Int
        let type: String
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// JSON text for a payload value.
    public static func payloadText<P: Encodable>(_ value: P) -> String {
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    public static func encode(_ envelope: NodeEnvelope) -> String {
        guard let data = try? encoder.encode(envelope), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Parses and size/version-checks an envelope. Does not verify its MAC.
    public static func envelope(from text: String) throws -> NodeEnvelope {
        let data = Data(text.utf8)
        guard data.count <= NodeProtocol.maxMessageBytes else { throw NodeProtocolError.messageTooLarge(data.count) }
        // Version and type first, so an older node gets a clear version error rather than a schema error.
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw NodeProtocolError.notJSON }
        guard NodeProtocol.supportedVersions.contains(header.v) else { throw NodeProtocolError.unsupportedVersion(header.v) }
        guard NodeMessageType.fromNode.contains(header.type) else {
            throw NodeProtocolError.unknownType(String(header.type.prefix(40)))
        }
        guard let envelope = try? JSONDecoder().decode(NodeEnvelope.self, from: data) else {
            throw NodeProtocolError.invalidPayload("the “\(header.type)” envelope does not match the version \(header.v) format")
        }
        return envelope
    }

    public static func decodePayload<P: Decodable>(_ type: P.Type, from envelope: NodeEnvelope) throws -> P {
        guard let text = envelope.payload else { throw NodeProtocolError.missingPayload(envelope.type) }
        guard let value = try? JSONDecoder().decode(P.self, from: Data(text.utf8)) else {
            throw NodeProtocolError.invalidPayload("“\(envelope.type)” does not match the version \(NodeProtocol.version) schema")
        }
        return value
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

    public static func validate(_ capabilities: NodeCapabilities) throws {
        guard capabilities.hardware.count <= 32, capabilities.features.count <= 64 else {
            throw NodeProtocolError.invalidPayload("too many hardware or feature entries")
        }
        guard capabilities.maxBins >= 0, capabilities.maxBins <= 1_000_000 else {
            throw NodeProtocolError.invalidPayload("invalid maxBins")
        }
        for item in capabilities.hardware {
            guard !item.id.isEmpty, item.id.count <= 64,
                  item.minFrequencyHz.isFinite, item.maxFrequencyHz.isFinite, item.maxSpanHz.isFinite,
                  item.minFrequencyHz >= 0, item.maxFrequencyHz > item.minFrequencyHz, item.maxSpanHz > 0 else {
                throw NodeProtocolError.invalidPayload("hardware entry “\(String(item.id.prefix(32)))” has an invalid range")
            }
        }
    }

    private static let bssidPattern = "^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$"
    public static let securityValues: Set<String> = ["open", "wep", "wpa", "wpa2", "wpa3", "wpa2-enterprise", "wpa3-enterprise", "owe", "unknown"]

    public static func validate(_ scan: WifiScanResult) throws {
        guard scan.networks.count <= NodeProtocol.maxWifiNetworks else {
            throw NodeProtocolError.invalidPayload("Wi-Fi scan lists \(scan.networks.count) networks (limit \(NodeProtocol.maxWifiNetworks))")
        }
        guard scan.scannedAt.isFinite, scan.scannedAt > 0, !scan.interface.isEmpty, scan.interface.count <= 32 else {
            throw NodeProtocolError.invalidPayload("Wi-Fi scan has an invalid time or interface")
        }
        for network in scan.networks {
            guard network.bssid.range(of: bssidPattern, options: .regularExpression) != nil else {
                throw NodeProtocolError.invalidPayload("Wi-Fi scan contains an invalid BSSID")
            }
            if let ssid = network.ssid, ssid.utf8.count > 32 {
                throw NodeProtocolError.invalidPayload("Wi-Fi scan contains an SSID longer than 32 bytes")
            }
            guard (1...233).contains(network.channel), (2_400...7_125).contains(network.frequencyMHz),
                  (-120...0).contains(network.rssiDbm), securityValues.contains(network.security) else {
                throw NodeProtocolError.invalidPayload("Wi-Fi scan entry \(network.bssid) has out-of-range values")
            }
        }
    }
}

// MARK: - Authentication

/// HMAC-SHA256 constructions used by SNP v2. `clientNonce` and `nodeNonce` are the base64 strings as sent.
public enum NodeAuth {
    private static func mac(_ key: [UInt8], _ parts: [String]) -> [UInt8] {
        HMACSHA256.authenticationCode(key: key, message: Array(([NodeProtocol.context] + parts).joined(separator: "|").utf8))
    }

    /// The node's proof, covering the client's nonce and the exact challenge payload (node info and capabilities).
    public static func challengeMAC(key: [UInt8], clientNonce: String, payload: String) -> [UInt8] {
        mac(key, ["challenge", clientNonce, payload])
    }

    public static func authenticateMAC(key: [UInt8], clientNonce: String, nodeNonce: String) -> [UInt8] {
        mac(key, ["authenticate", clientNonce, nodeNonce])
    }

    public static func sessionKey(key: [UInt8], clientNonce: String, nodeNonce: String) -> [UInt8] {
        mac(key, ["session", clientNonce, nodeNonce])
    }

    /// Per-message MAC after the handshake. `sender` is "node" or "client".
    public static func messageMAC(sessionKey: [UInt8], sender: String, seq: Int, type: String, payload: String) -> [UInt8] {
        mac(sessionKey, ["message", sender, String(seq), type, payload])
    }

    public static func base64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }

    public static func bytes(fromBase64 string: String?) -> [UInt8]? {
        guard let string = string, let data = Data(base64Encoded: string) else { return nil }
        return Array(data)
    }

    /// Parses a pairing key entered as hexadecimal (whitespace ignored). Nil when shorter than 32 bytes or not hex.
    public static func pairingKey(fromHex text: String) -> [UInt8]? {
        let cleaned = text.filter { !$0.isWhitespace }
        guard cleaned.count >= NodeProtocol.minimumKeyBytes * 2, cleaned.count % 2 == 0, cleaned.count <= 256 else { return nil }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
