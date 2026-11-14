import Foundation

// MARK: Modules

/// The Security Lab modules. Each one records its own version in every report it produces.
public enum SecurityModule: String, Codable, CaseIterable, Identifiable {
    case secretScanner
    case exposureCheck
    case authDefenseLab

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .secretScanner: return "Secret Scanner"
        case .exposureCheck: return "Exposure Check"
        case .authDefenseLab: return "Authentication Defense Lab"
        }
    }

    public var version: String {
        switch self {
        case .secretScanner: return "1.0.0"
        case .exposureCheck: return "1.0.0"
        case .authDefenseLab: return "1.0.0"
        }
    }

    public var summary: String {
        switch self {
        case .secretScanner:
            return "Looks for likely exposed credentials in folders and archives you select."
        case .exposureCheck:
            return "Checks HTTP and HTTPS services you own or are authorised to test: reachability, TLS, HTTPS redirect, security headers and version disclosure."
        case .authDefenseLab:
            return "Measures how a login service defends against repeated wrong passwords, against Sentinel's bundled local test service."
        }
    }
}

// MARK: Outcomes, severity, confidence

/// The result of one check. These are deliberately distinct: an unavailable or broken check is never a pass.
public enum CheckOutcome: String, Codable, CaseIterable {
    /// The check ran and observed the expected, defensive behaviour.
    case passed
    /// The check ran and produced at least one finding.
    case finding
    /// The check ran but the evidence does not support a conclusion either way.
    case inconclusive
    /// The check cannot run in this environment or for this target.
    case unsupported
    /// The check was attempted and could not complete.
    case failedToExecute

    public var label: String {
        switch self {
        case .passed: return "Passed"
        case .finding: return "Finding"
        case .inconclusive: return "Inconclusive"
        case .unsupported: return "Unsupported"
        case .failedToExecute: return "Failed to execute"
        }
    }
}

/// How much harm the issue could cause if it is real. Shown separately from confidence.
public enum FindingSeverity: String, Codable, CaseIterable, Comparable {
    case info, low, medium, high, critical

    private var rank: Int { FindingSeverity.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: FindingSeverity, rhs: FindingSeverity) -> Bool { lhs.rank < rhs.rank }

    public var label: String { rawValue.capitalized }
}

/// How sure Sentinel is that the finding is real. Shown separately from severity.
public enum FindingConfidence: String, Codable, CaseIterable {
    case low, medium, high
    public var label: String { rawValue.capitalized }
}

/// Whether a finding was demonstrated or is an indicator that needs context.
public enum EvidenceBasis: String, Codable {
    /// Behaviour Sentinel directly observed, such as a certificate the system refused or a missing lockout.
    case verified
    /// An indicator such as a version banner or a missing header. It does not by itself confirm a vulnerability.
    case observation

    public var label: String {
        switch self {
        case .verified: return "Verified behaviour"
        case .observation: return "Observation"
        }
    }
}

public struct SecurityFinding: Codable, Equatable, Identifiable {
    public var id: String
    public var checkID: String
    public var title: String
    public var severity: FindingSeverity
    public var confidence: FindingConfidence
    public var basis: EvidenceBasis
    /// File and line, URL, or account the finding concerns. Never contains a secret value.
    public var location: String?
    /// Redacted evidence lines.
    public var evidence: [String]
    public var explanation: String
    public var remediation: String
    /// Keyed hash used for false-positive suppression. Never the secret itself.
    public var fingerprint: String?

    public init(id: String, checkID: String, title: String, severity: FindingSeverity, confidence: FindingConfidence,
                basis: EvidenceBasis, location: String? = nil, evidence: [String], explanation: String,
                remediation: String, fingerprint: String? = nil) {
        self.id = id
        self.checkID = checkID
        self.title = title
        self.severity = severity
        self.confidence = confidence
        self.basis = basis
        self.location = location
        self.evidence = evidence
        self.explanation = explanation
        self.remediation = remediation
        self.fingerprint = fingerprint
    }
}

public struct CheckResult: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var target: String?
    public var outcome: CheckOutcome
    public var detail: String

    public init(id: String, title: String, target: String? = nil, outcome: CheckOutcome, detail: String) {
        self.id = id
        self.title = title
        self.target = target
        self.outcome = outcome
        self.detail = detail
    }
}

// MARK: Scope, location, limits

public struct ScopeItem: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable {
        case folder, file, archive, url, host, testAccount, serverWorkspace

        public var label: String {
            switch self {
            case .folder: return "Folder"
            case .file: return "File"
            case .archive: return "Archive"
            case .url: return "URL"
            case .host: return "Host"
            case .testAccount: return "Test account"
            case .serverWorkspace: return "Server workspace"
            }
        }
    }

    public var kind: Kind
    /// Display value, already redacted (no credentials in URLs).
    public var value: String
    /// True when the user explicitly selected a local-network target.
    public var localNetwork: Bool

    public var id: String { "\(kind.rawValue):\(value)" }

    public init(kind: Kind, value: String, localNetwork: Bool = false) {
        self.kind = kind
        self.value = (kind == .url || kind == .host) ? Redactor.standard.url(value) : Redactor.standard.text(value)
        self.localNetwork = localNetwork
    }
}

public enum ExecutionLocation: Codable, Equatable {
    case thisDevice
    case pairedServer(name: String, deviceID: String)

    public var label: String {
        switch self {
        case .thisDevice: return "This device"
        case .pairedServer(let name, _): return "Paired server: \(name)"
        }
    }
}

public struct AssessmentLimits: Codable, Equatable {
    public var maxFiles: Int?
    public var maxFileBytes: Int?
    public var maxTotalBytes: Int?
    public var maxRequests: Int?
    public var maxAttempts: Int?
    public var minRequestInterval: TimeInterval?
    public var requestTimeout: TimeInterval?
    public var overallTimeout: TimeInterval

    public init(maxFiles: Int? = nil, maxFileBytes: Int? = nil, maxTotalBytes: Int? = nil, maxRequests: Int? = nil,
                maxAttempts: Int? = nil, minRequestInterval: TimeInterval? = nil, requestTimeout: TimeInterval? = nil,
                overallTimeout: TimeInterval) {
        self.maxFiles = maxFiles
        self.maxFileBytes = maxFileBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxRequests = maxRequests
        self.maxAttempts = maxAttempts
        self.minRequestInterval = minRequestInterval
        self.requestTimeout = requestTimeout
        self.overallTimeout = overallTimeout
    }

    /// Human-readable lines for scope cards and reports.
    public var lines: [String] {
        var lines: [String] = []
        if let value = maxFiles { lines.append("At most \(value) files") }
        if let value = maxFileBytes { lines.append("Files larger than \(ByteFormatting.string(value)) are skipped") }
        if let value = maxTotalBytes { lines.append("At most \(ByteFormatting.string(value)) read in total") }
        if let value = maxRequests { lines.append("At most \(value) requests") }
        if let value = maxAttempts { lines.append("Hard cap of \(value) login attempts") }
        if let value = minRequestInterval { lines.append("At least \(Self.seconds(value)) between requests") }
        if let value = requestTimeout { lines.append("\(Self.seconds(value)) limit per request") }
        lines.append("\(Self.seconds(overallTimeout)) limit for the whole assessment")
        return lines
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value.rounded() == value ? "\(Int(value)) s" : String(format: "%.1f s", value)
    }
}

public enum ByteFormatting {
    public static func string(_ bytes: Int) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) bytes"
    }
}

// MARK: The record

public enum AssessmentRunStatus: String, Codable {
    case running
    case completed
    case cancelled
    case timedOut
    case failedToExecute
    case unsupported

    public var label: String {
        switch self {
        case .running: return "Running"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .timedOut: return "Stopped at time limit"
        case .failedToExecute: return "Failed to execute"
        case .unsupported: return "Unsupported"
        }
    }
}

/// Everything an assessment did and found. Stored locally and rendered into reports.
public struct SecurityAssessmentRecord: Codable, Equatable, Identifiable {
    public var id: UUID
    public var module: SecurityModule
    public var moduleVersion: String
    public var scope: [ScopeItem]
    public var location: ExecutionLocation
    public var permissions: [String]
    public var startedAt: Date
    public var endedAt: Date?
    public var status: AssessmentRunStatus
    public var limits: AssessmentLimits
    public var checks: [CheckResult]
    public var findings: [SecurityFinding]
    /// Things in scope that were not examined, with the reason.
    public var notTested: [String]
    /// Execution errors. Never merged into findings.
    public var errors: [String]
    /// Inherent limits of the method, always shown in the report.
    public var limitations: [String]
    public var workCompleted: Int
    public var workTotal: Int
    /// Findings the user marked as false positives (by fingerprint) that were hidden from this run.
    public var suppressedCount: Int

    public init(id: UUID = UUID(), module: SecurityModule, scope: [ScopeItem], location: ExecutionLocation,
                permissions: [String], startedAt: Date, limits: AssessmentLimits, limitations: [String]) {
        self.id = id
        self.module = module
        self.moduleVersion = module.version
        self.scope = scope
        self.location = location
        self.permissions = permissions
        self.startedAt = startedAt
        self.endedAt = nil
        self.status = .running
        self.limits = limits
        self.checks = []
        self.findings = []
        self.notTested = []
        self.errors = []
        self.limitations = limitations
        self.workCompleted = 0
        self.workTotal = 0
        self.suppressedCount = 0
    }

    public func count(_ outcome: CheckOutcome) -> Int { checks.filter { $0.outcome == outcome }.count }

    public var highestSeverity: FindingSeverity? { findings.map { $0.severity }.max() }

    /// A neutral one-line summary. It never calls anything safe or secure.
    public var headline: String {
        switch status {
        case .running:
            return "Running…"
        case .unsupported:
            return "Not run: this assessment is unsupported here"
        case .failedToExecute:
            return "The assessment could not be executed"
        case .cancelled, .timedOut, .completed:
            let prefix: String
            switch status {
            case .cancelled: prefix = "Cancelled — incomplete. "
            case .timedOut: prefix = "Stopped at the time limit — incomplete. "
            default: prefix = ""
            }
            if !findings.isEmpty {
                return prefix + "\(findings.count) finding\(findings.count == 1 ? "" : "s") to review"
            }
            let undetermined = count(.inconclusive) + count(.unsupported) + count(.failedToExecute)
            if checks.isEmpty { return prefix + "No checks completed" }
            if undetermined > 0 { return prefix + "No findings, but \(undetermined) check\(undetermined == 1 ? "" : "s") did not reach a result" }
            return prefix + "No findings from these checks"
        }
    }

    public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }

    public var reference: SecurityReportReference {
        SecurityReportReference(id: id, module: module, status: status, startedAt: startedAt, endedAt: endedAt,
                                findingCount: findings.count, highestSeverity: highestSeverity)
    }
}

/// Metadata about a report, safe to publish to other HCG surfaces. It never contains findings,
/// evidence, scope values or anything else from inside the report.
public struct SecurityReportReference: Codable, Equatable, Identifiable {
    public var id: UUID
    public var module: SecurityModule
    public var status: AssessmentRunStatus
    public var startedAt: Date
    public var endedAt: Date?
    public var findingCount: Int
    public var highestSeverity: FindingSeverity?

    /// Opens the report for review in Sentinel. Opening never runs anything.
    public var link: URL { DeepLink.url(forReport: id) }
}

// MARK: Progress, cancellation, time limits

public struct AssessmentProgress: Equatable {
    public var completed: Int
    public var total: Int
    public var current: String

    public init(completed: Int, total: Int, current: String) {
        self.completed = completed
        self.total = total
        self.current = current
    }

    /// Fraction of real work done; nil while the total is still unknown.
    public var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }
}

/// Thread-safe cancellation flag with an overall deadline, checked by every engine between units of work.
public final class AssessmentControl {
    public enum Stop: Error, Equatable {
        case cancelled
        case timedOut
    }

    private let lock = NSLock()
    private var cancelled = false
    private var onCancel: [() -> Void] = []
    public let deadline: Date
    private let now: () -> Date

    public init(timeout: TimeInterval, now: @escaping () -> Date = Date.init) {
        self.now = now
        self.deadline = now().addingTimeInterval(timeout)
    }

    public func cancel() {
        lock.lock()
        let handlers = cancelled ? [] : onCancel
        cancelled = true
        onCancel = []
        lock.unlock()
        handlers.forEach { $0() }
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public var remaining: TimeInterval { deadline.timeIntervalSince(now()) }

    /// Throws when the user cancelled or the overall time limit passed.
    public func check() throws {
        if isCancelled { throw Stop.cancelled }
        if remaining <= 0 { throw Stop.timedOut }
    }

    /// Runs `handler` when cancelled (immediately if already cancelled). Used to abort blocking I/O.
    public func whenCancelled(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }
        onCancel.append(handler)
        lock.unlock()
    }

    /// Waits up to `seconds`, waking early on cancellation. Returns false if cancelled.
    @discardableResult
    public func pause(_ seconds: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if isCancelled { return false }
            Thread.sleep(forTimeInterval: min(0.05, max(0, end.timeIntervalSinceNow)))
        }
        return !isCancelled
    }
}

extension AssessmentRunStatus {
    init(stop: AssessmentControl.Stop) {
        switch stop {
        case .cancelled: self = .cancelled
        case .timedOut: self = .timedOut
        }
    }
}

// MARK: Rendering

/// Builds the readable report and the redacted export. Every line passes through the Redactor again,
/// so a secret that slipped into evidence still does not leave the device in an export.
public enum SecurityReportRenderer {
    public static func text(_ record: SecurityAssessmentRecord, generatedAt: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("# HCG Sentinel — \(record.module.title) report")
        lines.append("")
        lines.append("Report \(record.id.uuidString) · module \(record.module.rawValue) v\(record.moduleVersion)")
        lines.append("Status: \(record.status.label) — \(record.headline)")
        lines.append("Started \(formatter.string(from: record.startedAt))" + (record.endedAt.map { ", ended \(formatter.string(from: $0))" } ?? ""))
        lines.append("Executed on: \(record.location.label)")
        lines.append("Exported \(formatter.string(from: generatedAt)). Secret values are redacted.")
        lines.append("")
        lines.append("## Scope")
        for item in record.scope {
            lines.append("- \(item.kind.label): \(item.value)" + (item.localNetwork ? " (local network, explicitly selected)" : ""))
        }
        lines.append("")
        lines.append("Permissions granted for this run:")
        for permission in record.permissions { lines.append("- \(permission)") }
        lines.append("")
        lines.append("Limits:")
        for line in record.limits.lines { lines.append("- \(line)") }
        lines.append("Work completed: \(record.workCompleted) of \(record.workTotal)")
        lines.append("")
        lines.append("## Checks")
        for outcome in CheckOutcome.allCases {
            lines.append("- \(outcome.label): \(record.count(outcome))")
        }
        for check in record.checks {
            lines.append("- [\(check.outcome.label)] \(check.title)" + (check.target.map { " — \($0)" } ?? "") + ": \(check.detail)")
        }
        lines.append("")
        lines.append("## Findings")
        if record.findings.isEmpty { lines.append("None from these checks. This does not mean nothing is wrong.") }
        for finding in record.findings.sorted(by: { $0.severity > $1.severity }) {
            lines.append("")
            lines.append("### \(finding.title)")
            lines.append("Severity: \(finding.severity.label) · Confidence: \(finding.confidence.label) · \(finding.basis.label)")
            if let location = finding.location { lines.append("Location: \(location)") }
            lines.append("Evidence:")
            for line in finding.evidence { lines.append("    \(line)") }
            lines.append("Why it matters: \(finding.explanation)")
            lines.append("Next step: \(finding.remediation)")
        }
        if record.suppressedCount > 0 {
            lines.append("")
            lines.append("\(record.suppressedCount) finding(s) were hidden because you marked them as false positives.")
        }
        lines.append("")
        lines.append("## Not tested")
        if record.notTested.isEmpty { lines.append("- Nothing in scope was skipped.") }
        for line in record.notTested { lines.append("- \(line)") }
        lines.append("")
        lines.append("## Execution errors")
        if record.errors.isEmpty { lines.append("- None.") }
        for line in record.errors { lines.append("- \(line)") }
        lines.append("")
        lines.append("## Limitations")
        for line in record.limitations { lines.append("- \(line)") }
        lines.append("")
        lines.append("## Recommended next steps")
        for step in nextSteps(record) { lines.append("- \(step)") }
        return lines.map { Redactor.standard.text($0) }.joined(separator: "\n") + "\n"
    }

    public static func nextSteps(_ record: SecurityAssessmentRecord) -> [String] {
        var steps: [String] = []
        let remediations = record.findings.sorted { $0.severity > $1.severity }.map { $0.remediation }
        for remediation in remediations where !steps.contains(remediation) { steps.append(remediation) }
        if record.status == .cancelled || record.status == .timedOut {
            steps.append("Run the assessment again to completion; this report is incomplete.")
        }
        if record.count(.failedToExecute) > 0 || !record.errors.isEmpty {
            steps.append("Resolve the execution errors listed above and run again; those checks produced no result.")
        }
        if record.count(.inconclusive) > 0 {
            steps.append("Review the inconclusive checks manually; Sentinel could not reach a conclusion for them.")
        }
        if steps.isEmpty { steps.append("Keep the scope current and repeat the assessment after changes.") }
        return Array(steps.prefix(12))
    }
}

// MARK: Storage

/// Reports are stored as JSON in the app's sandbox and never leave the device unless the user exports them.
public final class SecurityReportStore {
    public let directory: URL
    private let fileManager: FileManager
    public let maxReports: Int

    public init(directory: URL, maxReports: Int = 100, fileManager: FileManager = .default) {
        self.directory = directory
        self.maxReports = maxReports
        self.fileManager = fileManager
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func url(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    public func save(_ record: SecurityAssessmentRecord) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try SecurityReportStore.encoder.encode(record)
        #if os(iOS)
        try data.write(to: url(for: record.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url(for: record.id), options: [.atomic])
        #endif
        prune()
    }

    public func load(_ id: UUID) -> SecurityAssessmentRecord? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? SecurityReportStore.decoder.decode(SecurityAssessmentRecord.self, from: data)
    }

    /// Newest first. Unreadable files are skipped.
    public func list() -> [SecurityAssessmentRecord] {
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? SecurityReportStore.decoder.decode(SecurityAssessmentRecord.self, from: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(_ id: UUID) {
        try? fileManager.removeItem(at: url(for: id))
    }

    public func deleteAll() {
        for record in list() { delete(record.id) }
    }

    private func prune() {
        let records = list()
        guard records.count > maxReports else { return }
        for record in records.suffix(from: maxReports) { delete(record.id) }
    }
}
