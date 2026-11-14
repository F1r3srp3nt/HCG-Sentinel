import Foundation

/// A small, bounded DEFLATE (RFC 1951) decoder used to read zip and gzip archives in memory.
/// It never writes to disk and stops as soon as the output would exceed `maxOutput`, which defeats
/// decompression bombs.
public enum Inflate {
    public enum Failure: Error, Equatable {
        case invalidData(String)
        case truncated
        case outputLimit
    }

    /// Decodes a raw DEFLATE stream. Returns the output and the number of input bytes consumed.
    public static func inflate(_ input: [UInt8], maxOutput: Int) throws -> (output: [UInt8], consumed: Int) {
        var state = State(input: input, maxOutput: maxOutput)
        var last = 0
        repeat {
            last = try state.bits(1)
            let type = try state.bits(2)
            switch type {
            case 0: try state.stored()
            case 1: try state.codes(lengths: Inflate.fixedLength, distances: Inflate.fixedDistance)
            case 2: try state.dynamic()
            default: throw Failure.invalidData("reserved block type")
            }
        } while last == 0
        return (state.output, state.position)
    }

    /// Decodes a gzip (RFC 1952) member.
    public static func gunzip(_ input: [UInt8], maxOutput: Int) throws -> [UInt8] {
        guard input.count >= 18, input[0] == 0x1f, input[1] == 0x8b, input[2] == 8 else {
            throw Failure.invalidData("not a gzip stream")
        }
        let flags = input[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= input.count else { throw Failure.truncated }
            index += 2 + (Int(input[index]) | (Int(input[index + 1]) << 8))
        }
        if flags & 0x08 != 0 { index = try skipZeroTerminated(input, from: index) }
        if flags & 0x10 != 0 { index = try skipZeroTerminated(input, from: index) }
        if flags & 0x02 != 0 { index += 2 }
        guard index < input.count else { throw Failure.truncated }
        return try inflate(Array(input[index...]), maxOutput: maxOutput).output
    }

    private static func skipZeroTerminated(_ input: [UInt8], from start: Int) throws -> Int {
        var index = start
        while index < input.count && input[index] != 0 { index += 1 }
        guard index < input.count else { throw Failure.truncated }
        return index + 1
    }

    // MARK: Huffman tables

    struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []

        init(lengths: [Int]) throws {
            for length in lengths { counts[length] += 1 }
            if counts[0] == lengths.count { symbols = []; return } // no codes: only valid for unused distance trees
            var left = 1
            for length in 1...15 {
                left <<= 1
                left -= counts[length]
                if left < 0 { throw Failure.invalidData("over-subscribed code") }
            }
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<15 { offsets[length + 1] = offsets[length] + counts[length] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (symbol, length) in lengths.enumerated() where length != 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
        }
    }

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
                               2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    static let fixedLength: Huffman = {
        var lengths = [Int](repeating: 8, count: 288)
        for symbol in 144..<256 { lengths[symbol] = 9 }
        for symbol in 256..<280 { lengths[symbol] = 7 }
        return try! Huffman(lengths: lengths)
    }()

    static let fixedDistance: Huffman = try! Huffman(lengths: [Int](repeating: 5, count: 30))

    // MARK: Decoder state

    struct State {
        let input: [UInt8]
        let maxOutput: Int
        var position = 0
        var bitBuffer = 0
        var bitCount = 0
        var output: [UInt8] = []

        init(input: [UInt8], maxOutput: Int) {
            self.input = input
            self.maxOutput = maxOutput
        }

        mutating func bits(_ need: Int) throws -> Int {
            var value = bitBuffer
            while bitCount < need {
                guard position < input.count else { throw Failure.truncated }
                value |= Int(input[position]) << bitCount
                position += 1
                bitCount += 8
            }
            bitBuffer = value >> need
            bitCount -= need
            return value & ((1 << need) - 1)
        }

        mutating func append(_ byte: UInt8) throws {
            guard output.count < maxOutput else { throw Failure.outputLimit }
            output.append(byte)
        }

        mutating func stored() throws {
            bitBuffer = 0
            bitCount = 0
            guard position + 4 <= input.count else { throw Failure.truncated }
            let length = Int(input[position]) | (Int(input[position + 1]) << 8)
            let complement = Int(input[position + 2]) | (Int(input[position + 3]) << 8)
            position += 4
            guard length == (~complement & 0xffff) else { throw Failure.invalidData("stored length mismatch") }
            guard position + length <= input.count else { throw Failure.truncated }
            guard output.count + length <= maxOutput else { throw Failure.outputLimit }
            output.append(contentsOf: input[position..<(position + length)])
            position += length
        }

        mutating func decode(_ table: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for length in 1...15 {
                code |= try bits(1)
                let count = table.counts[length]
                if code - count < first { return table.symbols[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Failure.invalidData("invalid Huffman code")
        }

        mutating func codes(lengths: Huffman, distances: Huffman) throws {
            while true {
                let symbol = try decode(lengths)
                if symbol < 256 {
                    try append(UInt8(symbol))
                } else if symbol == 256 {
                    return
                } else {
                    let lengthIndex = symbol - 257
                    guard lengthIndex < 29 else { throw Failure.invalidData("invalid length symbol") }
                    let length = Inflate.lengthBase[lengthIndex] + (try bits(Inflate.lengthExtra[lengthIndex]))
                    let distanceSymbol = try decode(distances)
                    guard distanceSymbol < 30 else { throw Failure.invalidData("invalid distance symbol") }
                    let distance = Inflate.distanceBase[distanceSymbol] + (try bits(Inflate.distanceExtra[distanceSymbol]))
                    guard distance <= output.count else { throw Failure.invalidData("distance too far back") }
                    guard output.count + length <= maxOutput else { throw Failure.outputLimit }
                    let start = output.count - distance
                    for offset in 0..<length { output.append(output[start + offset]) }
                }
            }
        }

        mutating func dynamic() throws {
            let literalCount = try bits(5) + 257
            let distanceCount = try bits(5) + 1
            let codeLengthCount = try bits(4) + 4
            guard literalCount <= 286, distanceCount <= 30 else { throw Failure.invalidData("bad counts") }
            var codeLengths = [Int](repeating: 0, count: 19)
            for index in 0..<codeLengthCount { codeLengths[Inflate.codeLengthOrder[index]] = try bits(3) }
            let codeLengthTable = try Huffman(lengths: codeLengths)
            var lengths: [Int] = []
            let total = literalCount + distanceCount
            while lengths.count < total {
                let symbol = try decode(codeLengthTable)
                if symbol < 16 {
                    lengths.append(symbol)
                    continue
                }
                var repeatValue = 0
                var repeatCount: Int
                switch symbol {
                case 16:
                    guard let previous = lengths.last else { throw Failure.invalidData("repeat with no previous length") }
                    repeatValue = previous
                    repeatCount = 3 + (try bits(2))
                case 17: repeatCount = 3 + (try bits(3))
                default: repeatCount = 11 + (try bits(7))
                }
                guard lengths.count + repeatCount <= total else { throw Failure.invalidData("too many lengths") }
                lengths.append(contentsOf: repeatElement(repeatValue, count: repeatCount))
            }
            guard lengths[256] != 0 else { throw Failure.invalidData("no end-of-block code") }
            let literalTable = try Huffman(lengths: Array(lengths[0..<literalCount]))
            let distanceTable = try Huffman(lengths: Array(lengths[literalCount...]))
            try codes(lengths: literalTable, distances: distanceTable)
        }
    }
}
