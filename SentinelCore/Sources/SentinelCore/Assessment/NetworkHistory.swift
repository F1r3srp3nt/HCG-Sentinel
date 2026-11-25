import Foundation

public extension AssessmentReport {
    /// The whole report as plain text for export. With `maskNetworkIdentifiers` (the default for sharing) IP and MAC
    /// addresses, BSSIDs and e-mail addresses are replaced; credentials are always redacted.
    func text(maskNetworkIdentifiers: Bool = true) -> String {
        let redactor = ReportRedactor(maskNetworkIdentifiers: maskNetworkIdentifiers)
        let iso = ISO8601DateFormatter()
        var lines = ["HCG Sentinel Unleashed — Check My Network",
                     "Started: \(iso.string(from: startedAt))  Finished: \(iso.string(from: finishedAt))",
                     "Steps completed: \(completedSteps) of \(totalSteps)\(cancelled ? " (cancelled)" : "")",
                     "Result: \(headline)", ""]
        for finding in findings {
            lines.append("[\(finding.kind.rawValue)] \(redactor.redact(finding.title))")
            lines += finding.evidence.map { "  Evidence: \(redactor.redact($0))" }
            lines.append("  Limits: \(finding.limitations)")
            if let fix = finding.remediation { lines.append("  What to do: \(fix)") }
        }
        lines.append("")
        lines.append(disclaimer)
        lines.append("Measured from this iPhone only. Router configuration, other devices and radio-level data need an external diagnostic node.")
        return lines.joined(separator: "\n")
    }
}

/// One past network diagnostic, kept on this device so results can be compared over time.
public struct NetworkHistoryEntry: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable, Equatable {
        case networkCheck = "Check My Network"
        case ping = "Ping"
        case tcpConnect = "TCP connect test"
        case sweep = "Local sweep"
    }

    public var id: UUID
    public var at: Date
    public var kind: Kind
    /// One line, for the list.
    public var headline: String
    /// Short facts, e.g. "Loss 0 %", "Avg 12.4 ms", "Connection: Wi-Fi".
    public var facts: [String]
    /// The exportable text, with network identifiers masked.
    public var text: String

    public init(id: UUID = UUID(), at: Date, kind: Kind, headline: String, facts: [String], text: String) {
        self.id = id
        self.at = at
        self.kind = kind
        self.headline = headline
        self.facts = facts
        self.text = text
    }

    public static func networkCheck(_ report: AssessmentReport, connection: String) -> NetworkHistoryEntry {
        NetworkHistoryEntry(at: report.finishedAt, kind: .networkCheck, headline: report.headline,
                            facts: ["Connection: \(connection)", "Concerns: \(report.count(.securityConcern))",
                                    "Could not complete: \(report.count(.connectivityProblem) + report.count(.notChecked))"],
                            text: report.text())
    }

    /// `target` is masked in the stored text when it is an address; a host name the user typed is kept.
    public static func ping(target: String, configuration: PingConfiguration, results: [PingProbeResult], at: Date,
                            failure: String?) -> NetworkHistoryEntry {
        let stats = PingStatistics(results: results)
        let redactor = ReportRedactor.strict
        let shown = redactor.redact(target)
        func ms(_ v: Double?) -> String { v.map { String(format: "%.1f ms", $0) } ?? "—" }
        var facts = ["Answered \(stats.received)/\(stats.sent)"]
        if let loss = stats.lossPercent { facts.append(String(format: "Loss %.0f %%", loss)) }
        facts.append("Min/avg/max \(ms(stats.minimum)) / \(ms(stats.average)) / \(ms(stats.maximum))")
        // Stability: spread between fastest and slowest answer.
        if let lo = stats.minimum, let hi = stats.maximum, stats.received > 1 { facts.append(String(format: "Jitter range %.1f ms", hi - lo)) }
        let kind: Kind
        if case .tcpConnect = configuration.method { kind = .tcpConnect } else { kind = .ping }
        let headline = failure.map { "\(shown): \($0)" } ?? "\(shown): \(stats.received) of \(stats.sent) answered"
        var lines: [String] = ["HCG Sentinel Unleashed — \(configuration.method.title)", "Target: \(shown)",
                               "Probes: \(configuration.count), interval \(Int(configuration.interval)) s, timeout \(Int(configuration.timeout)) s"]
        if let failure = failure { lines.append("Failed: \(redactor.redact(failure))") }
        lines.append(contentsOf: facts)
        for r in results {
            switch r.outcome {
            case .reply(let v): lines.append("  #\(r.sequence) \(ms(v))")
            case .refused(let v): lines.append("  #\(r.sequence) refused in \(ms(v))")
            case .timeout: lines.append("  #\(r.sequence) timeout")
            case .error(let e): lines.append("  #\(r.sequence) \(redactor.redact(e))")
            }
        }
        let text = lines.joined(separator: "\n")
        return NetworkHistoryEntry(at: at, kind: kind, headline: redactor.redact(headline), facts: facts, text: text)
    }
}

/// File-backed history (Application Support), newest first, at most `maxEntries`.
public final class NetworkHistoryStore {
    public static let maxEntries = 50
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func list() -> [NetworkHistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([NetworkHistoryEntry].self, from: data)) ?? []).sorted { $0.at > $1.at }
    }

    @discardableResult
    public func add(_ entry: NetworkHistoryEntry) -> [NetworkHistoryEntry] {
        var all = list()
        all.insert(entry, at: 0)
        all = Array(all.sorted { $0.at > $1.at }.prefix(NetworkHistoryStore.maxEntries))
        write(all)
        return all
    }

    public func clear() {
        write([])
    }

    private func write(_ entries: [NetworkHistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
