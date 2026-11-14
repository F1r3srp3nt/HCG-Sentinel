import Foundation

/// Archive formats the Secret Scanner can read in memory. Nothing is ever extracted to disk.
public enum ArchiveKind: String, Equatable {
    case zip, tar, tarGzip, gzip

    /// Detects by name first, then confirms with the leading bytes.
    public static func detect(name: String, header: [UInt8]) -> ArchiveKind? {
        let lower = name.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return .tarGzip }
        if lower.hasSuffix(".tar") { return .tar }
        if lower.hasSuffix(".gz") { return .gzip }
        if lower.hasSuffix(".zip") || lower.hasSuffix(".jar") { return .zip }
        if header.count >= 4 && header[0] == 0x50 && header[1] == 0x4b && header[2] == 0x03 && header[3] == 0x04 { return .zip }
        if header.count >= 2 && header[0] == 0x1f && header[1] == 0x8b { return .gzip }
        return nil
    }

    public static func looksLikeArchive(_ name: String) -> Bool {
        let lower = name.lowercased()
        return [".zip", ".jar", ".tar", ".tgz", ".gz", ".7z", ".rar", ".xz", ".bz2", ".apk", ".ipa", ".war"].contains { lower.hasSuffix($0) }
    }
}

public struct ArchiveLimits: Equatable {
    public var maxEntries: Int
    public var maxEntryBytes: Int
    /// Remaining uncompressed bytes this archive may produce, shared with the rest of the scan.
    public var maxTotalBytes: Int

    public init(maxEntries: Int, maxEntryBytes: Int, maxTotalBytes: Int) {
        self.maxEntries = maxEntries
        self.maxEntryBytes = maxEntryBytes
        self.maxTotalBytes = maxTotalBytes
    }
}

public enum ArchiveItem: Equatable {
    case file(path: String, data: [UInt8])
    case skipped(path: String, reason: String)
    /// An entry whose name would escape the extraction folder (zip-slip) or is otherwise unsafe.
    case unsafePath(path: String, reason: String)
}

public enum ArchiveError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .malformed(let detail): return "The archive is malformed: \(detail)"
        case .unsupported(let detail): return "Unsupported archive feature: \(detail)"
        }
    }
}

public enum ArchiveReader {
    /// Reads every entry and hands it to `visit`. Stops early when limits, cancellation or the time limit say so.
    public static func read(_ bytes: [UInt8], kind: ArchiveKind, archiveName: String, limits: ArchiveLimits,
                            control: AssessmentControl, visit: (ArchiveItem) throws -> Void) throws {
        switch kind {
        case .zip:
            try readZip(bytes, limits: limits, control: control, visit: visit)
        case .tar:
            try readTar(bytes, limits: limits, control: control, visit: visit)
        case .tarGzip:
            let tar = try decompress(bytes, limit: limits.maxTotalBytes)
            try readTar(tar, limits: limits, control: control, visit: visit)
        case .gzip:
            var inner = archiveName
            if inner.lowercased().hasSuffix(".gz") { inner = String(inner.dropLast(3)) }
            do {
                let data = try Inflate.gunzip(bytes, maxOutput: min(limits.maxEntryBytes, limits.maxTotalBytes))
                try visit(.file(path: inner, data: data))
            } catch Inflate.Failure.outputLimit {
                try visit(.skipped(path: inner, reason: "decompresses to more than \(ByteFormatting.string(min(limits.maxEntryBytes, limits.maxTotalBytes))) (size limit; possible decompression bomb)"))
            }
        }
    }

    private static func decompress(_ bytes: [UInt8], limit: Int) throws -> [UInt8] {
        do {
            return try Inflate.gunzip(bytes, maxOutput: limit)
        } catch Inflate.Failure.outputLimit {
            throw ArchiveError.unsupported("the compressed tar expands beyond the \(ByteFormatting.string(limit)) scan budget (possible decompression bomb)")
        } catch {
            throw ArchiveError.malformed("gzip data could not be decoded")
        }
    }

    /// Why a stored name is unsafe to extract, or nil when it is a plain relative path.
    public static func unsafeReason(_ name: String) -> String? {
        if name.contains("\u{0}") { return "contains a NUL byte" }
        if name.hasPrefix("/") || name.hasPrefix("\\") { return "is an absolute path" }
        if name.contains("\\") { return "uses backslash separators" }
        if name.count >= 2, name[name.index(after: name.startIndex)] == ":", name.first?.isLetter == true { return "starts with a drive letter" }
        if name.split(separator: "/", omittingEmptySubsequences: false).contains("..") { return "climbs out of the archive with “..”" }
        return nil
    }

    /// Makes an entry name safe to display: no control characters, bounded length.
    public static func displayName(_ name: String) -> String {
        let cleaned = String(name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "?" : Character($0) })
        return cleaned.count > 200 ? String(cleaned.prefix(200)) + "…" : cleaned
    }

    // MARK: Zip

    private static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | (Int(b[i + 1]) << 8) }
    private static func u32(_ b: [UInt8], _ i: Int) -> Int { u16(b, i) | (u16(b, i + 2) << 16) }

    private static func readZip(_ b: [UInt8], limits: ArchiveLimits, control: AssessmentControl,
                                visit: (ArchiveItem) throws -> Void) throws {
        guard b.count >= 22 else { throw ArchiveError.malformed("too short for a zip file") }
        // Find the end-of-central-directory record in the last 64 KiB + 22 bytes.
        var eocd = -1
        var index = b.count - 22
        let lowest = max(0, b.count - 22 - 65_535)
        while index >= lowest {
            if b[index] == 0x50 && b[index + 1] == 0x4b && b[index + 2] == 0x05 && b[index + 3] == 0x06 { eocd = index; break }
            index -= 1
        }
        guard eocd >= 0 else { throw ArchiveError.malformed("no central directory") }
        let entryCount = u16(b, eocd + 10)
        let directorySize = u32(b, eocd + 12)
        let directoryOffset = u32(b, eocd + 16)
        if entryCount == 0xffff || directoryOffset == 0xffff_ffff || directorySize == 0xffff_ffff {
            throw ArchiveError.unsupported("ZIP64 archives")
        }
        guard directoryOffset + directorySize <= b.count else { throw ArchiveError.malformed("central directory outside the file") }
        var cursor = directoryOffset
        var produced = 0
        for entryIndex in 0..<entryCount {
            try control.check()
            guard entryIndex < limits.maxEntries else {
                try visit(.skipped(path: "(remaining entries)", reason: "the archive has more than \(limits.maxEntries) entries; the rest were not read"))
                return
            }
            guard cursor + 46 <= b.count, u32(b, cursor) == 0x0201_4b50 else { throw ArchiveError.malformed("bad central directory entry") }
            let madeBy = u16(b, cursor + 4)
            let flags = u16(b, cursor + 8)
            let method = u16(b, cursor + 10)
            let compressedSize = u32(b, cursor + 20)
            let size = u32(b, cursor + 24)
            let nameLength = u16(b, cursor + 28)
            let extraLength = u16(b, cursor + 30)
            let commentLength = u16(b, cursor + 32)
            let externalAttributes = u32(b, cursor + 38)
            let localOffset = u32(b, cursor + 42)
            guard cursor + 46 + nameLength <= b.count else { throw ArchiveError.malformed("entry name outside the file") }
            let rawName = String(decoding: b[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            cursor += 46 + nameLength + extraLength + commentLength
            let name = displayName(rawName)

            if rawName.hasSuffix("/") { continue }
            if let reason = unsafeReason(rawName) {
                try visit(.unsafePath(path: name, reason: reason))
                continue
            }
            let unixMode = (madeBy >> 8) == 3 ? (externalAttributes >> 16) & 0xf000 : 0
            if unixMode == 0xa000 {
                try visit(.skipped(path: name, reason: "symbolic link (never followed)"))
                continue
            }
            if flags & 1 != 0 {
                try visit(.skipped(path: name, reason: "encrypted entry (contents not readable)"))
                continue
            }
            if ArchiveKind.looksLikeArchive(rawName) {
                try visit(.skipped(path: name, reason: "nested archive (not opened)"))
                continue
            }
            let budget = min(limits.maxEntryBytes, limits.maxTotalBytes - produced)
            if size > budget {
                try visit(.skipped(path: name, reason: "\(ByteFormatting.string(size)) exceeds the size limit"))
                continue
            }
            guard localOffset + 30 <= b.count, u32(b, localOffset) == 0x0403_4b50 else { throw ArchiveError.malformed("bad local header for \(name)") }
            let dataStart = localOffset + 30 + u16(b, localOffset + 26) + u16(b, localOffset + 28)
            guard dataStart + compressedSize <= b.count else { throw ArchiveError.malformed("entry data outside the file for \(name)") }
            let compressed = Array(b[dataStart..<(dataStart + compressedSize)])
            let data: [UInt8]
            switch method {
            case 0:
                data = compressed
            case 8:
                do {
                    data = try Inflate.inflate(compressed, maxOutput: budget).output
                } catch Inflate.Failure.outputLimit {
                    try visit(.skipped(path: name, reason: "expands beyond its declared size and the size limit (possible decompression bomb)"))
                    continue
                } catch {
                    try visit(.skipped(path: name, reason: "compressed data is corrupt"))
                    continue
                }
            default:
                try visit(.skipped(path: name, reason: "compression method \(method) is not supported"))
                continue
            }
            produced += data.count
            try visit(.file(path: name, data: data))
        }
    }

    // MARK: Tar

    private static func field(_ b: [UInt8], _ offset: Int, _ length: Int) -> String {
        let slice = b[offset..<(offset + length)]
        let end = slice.firstIndex(of: 0) ?? slice.endIndex
        return String(decoding: b[offset..<end], as: UTF8.self)
    }

    private static func octal(_ b: [UInt8], _ offset: Int, _ length: Int) throws -> Int {
        if b[offset] & 0x80 != 0 { throw ArchiveError.unsupported("base-256 size fields") }
        let text = field(b, offset, length).trimmingCharacters(in: CharacterSet(charactersIn: " \u{0}"))
        if text.isEmpty { return 0 }
        guard let value = Int(text, radix: 8), value >= 0 else { throw ArchiveError.malformed("bad octal field") }
        return value
    }

    private static func readTar(_ b: [UInt8], limits: ArchiveLimits, control: AssessmentControl,
                                visit: (ArchiveItem) throws -> Void) throws {
        var offset = 0
        var entries = 0
        var produced = 0
        var pendingName: String?
        while offset + 512 <= b.count {
            try control.check()
            let header = Array(b[offset..<(offset + 512)])
            if header.allSatisfy({ $0 == 0 }) { return }
            let size = try octal(header, 124, 12)
            let type = header[156]
            var name = field(header, 0, 100)
            if field(header, 257, 5) == "ustar" {
                let prefix = field(header, 345, 155)
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            let dataStart = offset + 512
            let padded = (size + 511) / 512 * 512
            guard dataStart + size <= b.count else { throw ArchiveError.malformed("entry data runs past the end") }
            offset = dataStart + padded

            switch type {
            case UInt8(ascii: "L"): // GNU long name for the next entry
                pendingName = String(decoding: b[dataStart..<(dataStart + min(size, 4096))], as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}"))
                continue
            case UInt8(ascii: "x"): // pax extended header: honour the path record
                let text = String(decoding: b[dataStart..<(dataStart + min(size, 65_536))], as: UTF8.self)
                for record in text.split(separator: "\n") {
                    if let range = record.range(of: " path=") { pendingName = String(record[range.upperBound...]) }
                }
                continue
            case UInt8(ascii: "g"):
                continue
            default:
                break
            }
            if let long = pendingName { name = long; pendingName = nil }
            entries += 1
            guard entries <= limits.maxEntries else {
                try visit(.skipped(path: "(remaining entries)", reason: "the archive has more than \(limits.maxEntries) entries; the rest were not read"))
                return
            }
            let display = displayName(name)
            if type == UInt8(ascii: "5") { continue }
            if let reason = unsafeReason(name) {
                try visit(.unsafePath(path: display, reason: reason))
                continue
            }
            if type == UInt8(ascii: "2") || type == UInt8(ascii: "1") {
                try visit(.skipped(path: display, reason: type == UInt8(ascii: "2") ? "symbolic link (never followed)" : "hard link (never followed)"))
                continue
            }
            guard type == UInt8(ascii: "0") || type == 0 || type == UInt8(ascii: "7") else {
                try visit(.skipped(path: display, reason: "special file type (not read)"))
                continue
            }
            if ArchiveKind.looksLikeArchive(name) {
                try visit(.skipped(path: display, reason: "nested archive (not opened)"))
                continue
            }
            let budget = min(limits.maxEntryBytes, limits.maxTotalBytes - produced)
            if size > budget {
                try visit(.skipped(path: display, reason: "\(ByteFormatting.string(size)) exceeds the size limit"))
                continue
            }
            produced += size
            try visit(.file(path: display, data: Array(b[dataStart..<(dataStart + size)])))
        }
    }
}
