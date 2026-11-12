import Foundation

public enum ByteError: Error, Equatable {
    case outOfBounds(needed: Int, available: Int)
}

/// Bounds-checked sequential reader. Every read validates the remaining length
/// first, so malformed input raises `ByteError` instead of trapping.
public struct ByteCursor<Bytes: RandomAccessCollection> where Bytes.Element == UInt8, Bytes.Index == Int {
    public let bytes: Bytes
    public private(set) var offset: Int
    public var littleEndian: Bool

    public init(_ bytes: Bytes, offset: Int = 0, littleEndian: Bool = false) {
        self.bytes = bytes
        self.offset = max(0, min(offset, bytes.count))
        self.littleEndian = littleEndian
    }

    public var remaining: Int { bytes.count - offset }

    private func require(_ count: Int) throws {
        guard count >= 0, count <= remaining else {
            throw ByteError.outOfBounds(needed: count, available: remaining)
        }
    }

    private func byte(at relative: Int) -> UInt8 {
        bytes[bytes.startIndex + offset + relative]
    }

    public mutating func u8() throws -> UInt8 {
        try require(1)
        let value = byte(at: 0)
        offset += 1
        return value
    }

    public mutating func u16() throws -> UInt16 {
        try require(2)
        let a = UInt16(byte(at: 0)), b = UInt16(byte(at: 1))
        offset += 2
        return littleEndian ? (b << 8 | a) : (a << 8 | b)
    }

    public mutating func u32() throws -> UInt32 {
        try require(4)
        let a = UInt32(byte(at: 0)), b = UInt32(byte(at: 1)), c = UInt32(byte(at: 2)), d = UInt32(byte(at: 3))
        offset += 4
        return littleEndian ? (d << 24 | c << 16 | b << 8 | a) : (a << 24 | b << 16 | c << 8 | d)
    }

    public mutating func take(_ count: Int) throws -> [UInt8] {
        try require(count)
        let start = bytes.startIndex + offset
        let result = Array(bytes[start..<(start + count)])
        offset += count
        return result
    }

    public mutating func skip(_ count: Int) throws {
        try require(count)
        offset += count
    }
}

public enum Hex {
    private static let digits = Array("0123456789abcdef")

    public static func string<S: Sequence>(_ bytes: S, separator: String = "") -> String where S.Element == UInt8 {
        var parts: [String] = []
        for byte in bytes {
            parts.append(String([digits[Int(byte >> 4)], digits[Int(byte & 0x0f)]]))
        }
        return parts.joined(separator: separator)
    }

    /// Classic offset / hex / ASCII dump, limited to `maxBytes`.
    public static func dump(_ bytes: [UInt8], maxBytes: Int = 4096) -> String {
        let shown = Array(bytes.prefix(max(0, maxBytes)))
        var lines: [String] = []
        var index = 0
        while index < shown.count {
            let row = Array(shown[index..<min(index + 16, shown.count)])
            let offsetText = String(format: "%04x", index)
            var hexPart = row.map { String(format: "%02x", $0) }.joined(separator: " ")
            hexPart += String(repeating: " ", count: max(0, 47 - hexPart.count))
            let ascii = String(row.map { ($0 >= 0x20 && $0 < 0x7f) ? Character(UnicodeScalar($0)) : "." })
            lines.append("\(offsetText)  \(hexPart)  \(ascii)")
            index += 16
        }
        if bytes.count > shown.count {
            lines.append("… \(bytes.count - shown.count) more bytes not shown")
        }
        return lines.joined(separator: "\n")
    }
}
