import Foundation

public enum ActivityCategory: String, Codable, CaseIterable {
    case system, network, bluetooth, radio, request, helper, settings, devices
}

public enum ActivitySeverity: String, Codable {
    case info, notice, warning, error
}

public struct ActivityEntry: Identifiable, Codable, Equatable {
    public let id: UUID
    public let date: Date
    public let category: ActivityCategory
    public let severity: ActivitySeverity
    public let message: String
}

/// Bounded in-memory history of what Sentinel itself did. Every message passes
/// through the redactor before it is stored or forwarded to a sink.
public final class ActivityLog {
    public let capacity: Int
    private let redactor: Redactor
    private let now: () -> Date
    private let lock = NSLock()
    private var storage: [ActivityEntry] = []

    /// Called (on the recording thread) after each new entry.
    public var onChange: (() -> Void)?
    /// Optional persistent destination; used only when diagnostic logging is enabled.
    public var sink: ((ActivityEntry) -> Void)?

    public init(capacity: Int = 300, redactor: Redactor = .standard, now: @escaping () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.redactor = redactor
        self.now = now
    }

    /// Newest first.
    public var entries: [ActivityEntry] {
        lock.lock(); defer { lock.unlock() }
        return storage.reversed()
    }

    @discardableResult
    public func record(_ category: ActivityCategory, _ message: String, severity: ActivitySeverity = .info) -> ActivityEntry {
        let entry = ActivityEntry(id: UUID(), date: now(), category: category, severity: severity,
                                  message: redactor.text(message))
        lock.lock()
        storage.append(entry)
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
        lock.unlock()
        sink?(entry)
        onChange?()
        return entry
    }

    public func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
        onChange?()
    }
}

/// Append-only, size-capped diagnostic log file. Entries are already redacted
/// by `ActivityLog`; this type only formats and stores them.
public final class DiagnosticLogFile {
    public let url: URL
    public let maxBytes: Int
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(url: URL, maxBytes: Int = 512 * 1024, fileManager: FileManager = .default) {
        self.url = url
        self.maxBytes = max(1024, maxBytes)
        self.fileManager = fileManager
    }

    public static func line(for entry: ActivityEntry) -> String {
        let stamp = String(format: "%.3f", entry.date.timeIntervalSince1970)
        let message = entry.message.replacingOccurrences(of: "\n", with: " ⏎ ")
        return "\(stamp) [\(entry.severity.rawValue)] [\(entry.category.rawValue)] \(message)\n"
    }

    public func append(_ entry: ActivityEntry) {
        lock.lock(); defer { lock.unlock() }
        let line = Data(DiagnosticLogFile.line(for: entry).utf8)
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var existing = (try? Data(contentsOf: url)) ?? Data()
        existing.append(line)
        if existing.count > maxBytes {
            // Keep the newest half, starting at a line boundary.
            var tail = existing.suffix(maxBytes / 2)
            if let newline = tail.firstIndex(of: 0x0a) { tail = tail.suffix(from: tail.index(after: newline)) }
            existing = Data(tail)
        }
        try? existing.write(to: url, options: [.atomic])
    }

    public var byteCount: Int {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    public func contents() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    public func delete() {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: url)
    }
}
