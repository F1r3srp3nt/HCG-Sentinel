import Foundation

/// Imports `hcg.diagnostic-report/1` files the user chooses (for example HCG System Tester's
/// "connection-security" findings) into Sentinel's Security Reports.
///
/// A report is data. It is decoded with HCG Device Link's own model, checked with the same validator HCG Server
/// uses, and shown as plain text. Nothing in it is opened, followed or run, and Sentinel does not contact the app
/// that produced it.
public enum ReportImporter {
    public enum Failure: Error, Equatable {
        case tooLarge(Int)
        case notJSON
        case wrongSchema(String)
        case refused([String])

        public var message: String {
            switch self {
            case .tooLarge(let bytes): return "The file is \(bytes / 1024) KiB; diagnostic reports are at most \(ReportValidator.maxBytes / 1024) KiB."
            case .notJSON: return "The file is not a diagnostic report (it could not be read as hcg.diagnostic-report/1 JSON)."
            case .wrongSchema(let schema): return "The file is a \"\(schema)\" document, not hcg.diagnostic-report/1."
            case .refused(let problems): return "The report was not imported: \(problems.joined(separator: "; "))."
            }
        }
    }

    public static func importReport(_ data: Data) -> Result<DiagnosticReport, Failure> {
        guard data.count <= ReportValidator.maxBytes else { return .failure(.tooLarge(data.count)) }
        guard let report = try? DiagnosticReport.decode(data) else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let schema = object["schema"] as? String {
                return .failure(.wrongSchema(String(schema.prefix(60))))
            }
            return .failure(.notJSON)
        }
        let problems = ReportValidator.problems(report, encoded: data)
        guard problems.isEmpty else { return .failure(.refused(problems)) }
        return .success(report)
    }
}

/// Imported reports kept on this device (Application Support), newest first. Bounded in count.
public final class ImportedReportStore {
    public static let maxReports = 50

    public struct Entry: Identifiable, Equatable {
        public var id: String { report.reportId }
        public var report: DiagnosticReport
        public var importedAt: Date
    }

    private let directory: URL
    private let now: () -> Date

    public init(directory: URL, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    public func list() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url -> Entry? in
            guard let data = try? Data(contentsOf: url), case .success(let report) = ReportImporter.importReport(data) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? report.createdAt
            return Entry(report: report, importedAt: date)
        }.sorted { $0.importedAt > $1.importedAt }
    }

    /// Validates and stores a report. Importing the same report ID again replaces it.
    public func add(_ data: Data) -> Result<Entry, ReportImporter.Failure> {
        switch ReportImporter.importReport(data) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let report):
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let safeID = report.reportId.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(64)
            let name = safeID.isEmpty ? UUID().uuidString : String(safeID)
            let url = directory.appendingPathComponent("\(name).json")
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                return .failure(.refused(["it could not be saved (\(error.localizedDescription))"]))
            }
            trim()
            return .success(Entry(report: report, importedAt: now()))
        }
    }

    public func delete(_ reportId: String) {
        let safeID = reportId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(safeID).json"))
    }

    private func trim() {
        let all = list()
        guard all.count > ImportedReportStore.maxReports else { return }
        for entry in all.suffix(from: ImportedReportStore.maxReports) { delete(entry.report.reportId) }
    }
}
