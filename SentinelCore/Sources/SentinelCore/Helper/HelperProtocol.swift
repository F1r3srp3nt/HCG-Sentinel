import Foundation

/// Sentinel Helper Interface (SHI), version 1. See docs/HELPER_INTERFACE.md.
///
/// A deliberately narrow, authenticated request/response protocol between the
/// app and an optional, separately installed privileged helper. It has a fixed
/// operation allowlist with typed, range-checked parameters. There is no
/// shell, command, script or file-path operation, and none may be added
/// without a protocol version change.
public enum HelperProtocol {
    public static let version = 1
    public static let supportedVersions = [1]
    public static let maxFrameBytes = 65_536
    public static let nonceBytes = 32
    public static let minimumKeyBytes = 32
    public static let context = "hcg-sentinel-helper-v1"
}

public enum HelperOperation: String, Codable, CaseIterable {
    case reportCapabilities
    case getStatus
    case startCapture
    case stopCapture
    case setFilterRules
    case clearFilterRules
}

/// One wire frame. A single flat structure keeps decoding strict and simple;
/// which fields are required depends on `type`.
public struct HelperFrame: Codable, Equatable {
    public enum Kind: String {
        case hello, challenge, authenticate, session, request, response, error
    }

    public var type: String
    public var protocolVersions: [Int]?
    public var protocolVersion: Int?
    public var clientNonce: String?
    public var serverNonce: String?
    public var proof: String?
    public var sessionID: String?
    public var grantedOperations: [String]?
    public var sequence: Int?
    public var requestID: String?
    public var operation: String?
    /// Base64 of the JSON parameter or result document, so the MAC covers exact bytes.
    public var body: String?
    public var mac: String?
    public var ok: Bool?
    public var errorCode: String?
    public var errorMessage: String?

    public init(_ kind: Kind) {
        self.type = kind.rawValue
    }

    public var kind: Kind? { Kind(rawValue: type) }
}

public enum HelperFramingError: Error, Equatable {
    case frameTooLarge(Int)
    case invalidFrame
}

/// Length-prefixed framing: 4-byte big-endian length, then a JSON `HelperFrame`.
public enum HelperFraming {
    public static func encode(_ frame: HelperFrame) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(frame)
        guard body.count <= HelperProtocol.maxFrameBytes else { throw HelperFramingError.frameTooLarge(body.count) }
        let length = UInt32(body.count)
        var out = Data([UInt8(length >> 24), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
        out.append(body)
        return out
    }
}

/// Reassembles frames from a byte stream, rejecting oversized or malformed input.
public struct HelperFrameDecoder {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ data: Data) throws -> [HelperFrame] {
        buffer.append(contentsOf: data)
        var frames: [HelperFrame] = []
        while buffer.count >= 4 {
            let length = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
            guard length > 0, length <= HelperProtocol.maxFrameBytes else {
                buffer.removeAll()
                throw HelperFramingError.frameTooLarge(length)
            }
            guard buffer.count >= 4 + length else { break }
            let body = Data(buffer[4..<(4 + length)])
            buffer.removeFirst(4 + length)
            guard let frame = try? JSONDecoder().decode(HelperFrame.self, from: body) else {
                buffer.removeAll()
                throw HelperFramingError.invalidFrame
            }
            frames.append(frame)
        }
        return frames
    }
}

/// Mutual authentication with a pre-shared pairing key (HMAC-SHA256
/// challenge–response), plus per-message MACs keyed by a per-session key.
public enum HelperAuth {
    private static func mac(_ key: [UInt8], _ label: String, _ parts: [[UInt8]]) -> [UInt8] {
        var message = Array("\(HelperProtocol.context)|\(label)|".utf8)
        for part in parts { message += part }
        return HMACSHA256.authenticationCode(key: key, message: message)
    }

    public static func helperProof(key: [UInt8], clientNonce: [UInt8], serverNonce: [UInt8]) -> [UInt8] {
        mac(key, "helper", [clientNonce, serverNonce])
    }

    public static func clientProof(key: [UInt8], clientNonce: [UInt8], serverNonce: [UInt8]) -> [UInt8] {
        mac(key, "client", [clientNonce, serverNonce])
    }

    public static func sessionKey(key: [UInt8], clientNonce: [UInt8], serverNonce: [UInt8]) -> [UInt8] {
        mac(key, "session", [clientNonce, serverNonce])
    }

    public static func messageMAC(sessionKey: [UInt8], isRequest: Bool, sequence: Int, requestID: String,
                                  operation: String, ok: Bool?, body: Data) -> [UInt8] {
        let status = ok.map { $0 ? "ok" : "error" } ?? "-"
        let header = "\(sequence)|\(requestID)|\(operation)|\(status)|"
        return mac(sessionKey, isRequest ? "request" : "response", [Array(header.utf8), Array(body)])
    }

    public static func decodeBase64(_ string: String?, exactCount: Int? = nil) -> [UInt8]? {
        guard let string = string, let data = Data(base64Encoded: string) else { return nil }
        if let exactCount = exactCount, data.count != exactCount { return nil }
        return Array(data)
    }

    public static func base64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }
}

// MARK: - Operation documents

public struct HelperCapabilityReport: Codable, Equatable {
    public var helperVersion: String
    /// "rootful", "rootless", "test-harness" or "unknown". Informational only.
    public var packaging: String
    /// Operations the helper states it can actually perform in its environment.
    public var supportedOperations: [String]
    public var notes: String?

    public init(helperVersion: String, packaging: String, supportedOperations: [String], notes: String? = nil) {
        self.helperVersion = helperVersion
        self.packaging = packaging
        self.supportedOperations = supportedOperations
        self.notes = notes
    }
}

public struct HelperStatus: Codable, Equatable {
    public var activeCaptureID: String?
    public var filterRuleCount: Int

    public init(activeCaptureID: String?, filterRuleCount: Int) {
        self.activeCaptureID = activeCaptureID
        self.filterRuleCount = filterRuleCount
    }
}

public struct CaptureStartParameters: Codable, Equatable {
    public var interface: String
    public var snapLength: Int
    public var maxDurationSeconds: Int
    public var maxBytes: Int

    public init(interface: String, snapLength: Int, maxDurationSeconds: Int, maxBytes: Int) {
        self.interface = interface
        self.snapLength = snapLength
        self.maxDurationSeconds = maxDurationSeconds
        self.maxBytes = maxBytes
    }
}

public struct CaptureStopParameters: Codable, Equatable {
    public var captureID: String
    public init(captureID: String) { self.captureID = captureID }
}

public struct FilterRule: Codable, Equatable {
    public var id: String
    /// "block" or "allow".
    public var action: String
    /// "tcp", "udp" or "any".
    public var transport: String
    /// IPv4/IPv6 literal, optionally with a /prefix.
    public var remoteAddress: String
    public var remotePort: Int?

    public init(id: String, action: String, transport: String, remoteAddress: String, remotePort: Int? = nil) {
        self.id = id
        self.action = action
        self.transport = transport
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
    }
}

public struct FilterRulesParameters: Codable, Equatable {
    public var rules: [FilterRule]
    public init(rules: [FilterRule]) { self.rules = rules }
}

public enum HelperValidationError: Error, Equatable {
    case unknownOperation(String)
    case malformedParameters
    case unexpectedParameters
    case outOfRange(String)
}

/// Reference validation for every request. A helper must apply this (or an
/// equivalent) before acting; the client applies it before sending.
public enum HelperRequestValidator {
    public static let maxCaptureBytes = 256 * 1024 * 1024
    public static let maxCaptureSeconds = 3600
    public static let maxFilterRules = 64

    private static func matches(_ string: String, _ pattern: String) -> Bool {
        string.range(of: pattern, options: .regularExpression) != nil
    }

    public static func isValidIdentifier(_ string: String) -> Bool {
        matches(string, "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
    }

    @discardableResult
    public static func validate(operation name: String, body: Data) throws -> HelperOperation {
        guard let operation = HelperOperation(rawValue: name) else {
            throw HelperValidationError.unknownOperation(String(name.prefix(40)))
        }
        let decoder = JSONDecoder()
        switch operation {
        case .reportCapabilities, .getStatus, .clearFilterRules:
            guard body.isEmpty else { throw HelperValidationError.unexpectedParameters }
        case .startCapture:
            guard let p = try? decoder.decode(CaptureStartParameters.self, from: body) else {
                throw HelperValidationError.malformedParameters
            }
            guard matches(p.interface, "^[a-z][a-z0-9_]{0,14}$") else { throw HelperValidationError.outOfRange("interface") }
            guard (64...65_535).contains(p.snapLength) else { throw HelperValidationError.outOfRange("snapLength") }
            guard (1...maxCaptureSeconds).contains(p.maxDurationSeconds) else { throw HelperValidationError.outOfRange("maxDurationSeconds") }
            guard (1...maxCaptureBytes).contains(p.maxBytes) else { throw HelperValidationError.outOfRange("maxBytes") }
        case .stopCapture:
            guard let p = try? decoder.decode(CaptureStopParameters.self, from: body) else {
                throw HelperValidationError.malformedParameters
            }
            guard isValidIdentifier(p.captureID) else { throw HelperValidationError.outOfRange("captureID") }
        case .setFilterRules:
            guard let p = try? decoder.decode(FilterRulesParameters.self, from: body) else {
                throw HelperValidationError.malformedParameters
            }
            guard (1...maxFilterRules).contains(p.rules.count) else { throw HelperValidationError.outOfRange("rules") }
            for rule in p.rules {
                guard isValidIdentifier(rule.id) else { throw HelperValidationError.outOfRange("rule.id") }
                guard ["block", "allow"].contains(rule.action) else { throw HelperValidationError.outOfRange("rule.action") }
                guard ["tcp", "udp", "any"].contains(rule.transport) else { throw HelperValidationError.outOfRange("rule.transport") }
                guard matches(rule.remoteAddress, "^[0-9A-Fa-f:.]{2,45}(/[0-9]{1,3})?$") else {
                    throw HelperValidationError.outOfRange("rule.remoteAddress")
                }
                if let port = rule.remotePort {
                    guard (1...65_535).contains(port) else { throw HelperValidationError.outOfRange("rule.remotePort") }
                }
            }
        }
        return operation
    }
}
