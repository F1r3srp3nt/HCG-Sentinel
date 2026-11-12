import Foundation

public enum RetentionPolicy: String, Codable, CaseIterable, Equatable {
    case sessionOnly
    case oneDay
    case sevenDays
    case thirtyDays
    case untilDeleted

    public var title: String {
        switch self {
        case .sessionOnly: return "Do not save imports"
        case .oneDay: return "1 day"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        case .untilDeleted: return "Until I delete them"
        }
    }

    /// Maximum age of a saved capture, or `nil` when nothing is removed automatically.
    public var maximumAge: TimeInterval? {
        switch self {
        case .oneDay: return 86_400
        case .sevenDays: return 7 * 86_400
        case .thirtyDays: return 30 * 86_400
        case .sessionOnly, .untilDeleted: return nil
        }
    }

    public var savesImports: Bool { self != .sessionOnly }
}

public struct StoredCapture: Codable, Identifiable, Equatable {
    public let id: UUID
    public let originalName: String
    public let importedAt: Date
    public let byteCount: Int
    public let format: CaptureFormat
    public let packetCount: Int
    public let fileName: String
}

public enum CaptureStoreError: Error, Equatable {
    case notFound
    case io(String)
}

/// Stores imported capture files inside the app sandbox. Nothing is uploaded,
/// and files leave only through explicit deletion or the retention policy.
public final class CaptureStore {
    private let directory: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public init(directory: URL, fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.fileManager = fileManager
        self.now = now
    }

    public func list() -> [StoredCapture] {
        guard let data = try? Data(contentsOf: indexURL),
              let items = try? CaptureStore.decoder.decode([StoredCapture].self, from: data) else { return [] }
        return items.sorted { $0.importedAt > $1.importedAt }
    }

    @discardableResult
    public func save(_ data: Data, originalName: String, format: CaptureFormat, packetCount: Int) throws -> StoredCapture {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let id = UUID()
            let item = StoredCapture(id: id, originalName: CaptureStore.sanitize(originalName), importedAt: now(),
                                     byteCount: data.count, format: format, packetCount: packetCount,
                                     fileName: "\(id.uuidString).\(format.rawValue)")
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUnlessOpen)
            #endif
            try data.write(to: directory.appendingPathComponent(item.fileName), options: options)
            try writeIndex(list() + [item])
            return item
        } catch {
            throw CaptureStoreError.io(error.localizedDescription)
        }
    }

    public func data(for item: StoredCapture) throws -> Data {
        guard list().contains(where: { $0.id == item.id }) else { throw CaptureStoreError.notFound }
        do {
            return try Data(contentsOf: directory.appendingPathComponent(item.fileName))
        } catch {
            throw CaptureStoreError.io(error.localizedDescription)
        }
    }

    public func delete(id: UUID) throws {
        var items = list()
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw CaptureStoreError.notFound }
        let item = items.remove(at: index)
        try? fileManager.removeItem(at: directory.appendingPathComponent(item.fileName))
        do { try writeIndex(items) } catch { throw CaptureStoreError.io(error.localizedDescription) }
    }

    /// Deletes every saved capture. Returns the number removed.
    @discardableResult
    public func deleteAll() throws -> Int {
        let items = list()
        for item in items {
            try? fileManager.removeItem(at: directory.appendingPathComponent(item.fileName))
        }
        do { try writeIndex([]) } catch { throw CaptureStoreError.io(error.localizedDescription) }
        return items.count
    }

    /// Removes captures older than the policy allows. Returns what was removed.
    @discardableResult
    public func purgeExpired(policy: RetentionPolicy) -> [StoredCapture] {
        guard let maximumAge = policy.maximumAge else { return [] }
        let cutoff = now().addingTimeInterval(-maximumAge)
        let items = list()
        let expired = items.filter { $0.importedAt < cutoff }
        guard !expired.isEmpty else { return [] }
        for item in expired {
            try? fileManager.removeItem(at: directory.appendingPathComponent(item.fileName))
        }
        try? writeIndex(items.filter { $0.importedAt >= cutoff })
        return expired
    }

    private func writeIndex(_ items: [StoredCapture]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if canImport(Darwin)
        // Captures can hold sensitive traffic: keep them out of device and iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = directory
        try? target.setResourceValues(values)
        #endif
        try CaptureStore.encoder.encode(items).write(to: indexURL, options: [.atomic])
    }

    static func sanitize(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "capture"
        let cleaned = String(last.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.map(Character.init))
        let trimmed = String(cleaned.prefix(120))
        return trimmed.isEmpty ? "capture" : trimmed
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
