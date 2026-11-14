import Foundation
import SentinelCore

/// One editable Exposure Check target.
struct ExposureEntry: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var localNetwork: Bool
}

/// Runs Security Lab assessments one at a time, off the main thread, and keeps their reports on this device.
/// Nothing starts by itself: every run begins with the user pressing Start, and Stop cancels it at once.
final class SecurityLabModel: ObservableObject {
    @Published private(set) var reports: [SecurityAssessmentRecord] = []
    @Published private(set) var running: SecurityModule?
    @Published private(set) var progress: AssessmentProgress?
    @Published private(set) var lastResult: [SecurityModule: UUID] = [:]
    @Published private(set) var previewMode = false
    @Published private(set) var remoteConnectionsEnabled = false
    @Published var message: String?

    // Secret Scanner
    @Published private(set) var sources: [URL] = []
    @Published var exclusionsText: String {
        didSet { defaults.set(exclusionsText, forKey: Keys.exclusions) }
    }
    @Published private(set) var suppressed: Set<String>

    // Exposure Check
    @Published var exposureEntries: [ExposureEntry] = [ExposureEntry(text: "", localNetwork: false)]
    @Published var authorizationConfirmed = false

    // Authentication Defense Lab
    @Published var labConfiguration = AuthLabConfiguration() {
        didSet { if labConfiguration != oldValue { labServer?.service.reset(configuration: labConfiguration); expectations = AuthDefenseExpectations(lab: labConfiguration) } }
    }
    @Published var expectations = AuthDefenseExpectations(lab: AuthLabConfiguration())
    @Published private(set) var labURL: URL?
    @Published var wrongPasswordsText = ""
    @Published var attemptCap = 6

    let store: SecurityReportStore
    private let log: ActivityLog
    private let registry: CapabilityRegistry
    private let defaults: UserDefaults
    private let exposureTransport = FoundationExposureTransport()
    private let queue = DispatchQueue(label: "sentinel.securitylab", qos: .userInitiated)
    private var control: AssessmentControl?
    private var labServer: AuthLabServer?
    private var labTarget: AuthLabTarget?
    private let fingerprintKey: [UInt8]
    private(set) var fingerprintKeyPersistent: Bool

    private enum Keys {
        static let exclusions = "SecurityLab.exclusions"
        static let suppressed = "SecurityLab.suppressedFingerprints"
    }

    init(store: SecurityReportStore, log: ActivityLog, registry: CapabilityRegistry, defaults: UserDefaults = .standard) {
        self.store = store
        self.log = log
        self.registry = registry
        self.defaults = defaults
        self.exclusionsText = defaults.string(forKey: Keys.exclusions) ?? ""
        self.suppressed = Set(defaults.stringArray(forKey: Keys.suppressed) ?? [])
        if let stored = Keychain.read(.secretFingerprintKey), stored.count == 32 {
            fingerprintKey = [UInt8](stored)
            fingerprintKeyPersistent = true
        } else {
            let fresh = SecureRandom.bytes(32)
            fingerprintKey = fresh
            // Without a stored key, suppressions only last until the app quits; the UI says so.
            fingerprintKeyPersistent = Keychain.write(Data(fresh), for: .secretFingerprintKey)
        }
        reload()
    }

    var isRunning: Bool { running != nil }

    func apply(_ settings: SentinelSettings) {
        previewMode = settings.previewMode
        remoteConnectionsEnabled = settings.remoteConnectionsEnabled
        if previewMode { stop(reason: "Preview mode on") }
        if !settings.remoteConnectionsEnabled && running == .exposureCheck { stop(reason: "Remote connections turned off") }
    }

    func reload() {
        reports = store.list()
    }

    func report(_ id: UUID) -> SecurityAssessmentRecord? {
        reports.first { $0.id == id } ?? store.load(id)
    }

    // MARK: Running

    private func begin(_ module: SecurityModule, timeout: TimeInterval) -> AssessmentControl? {
        guard running == nil, !previewMode else { return nil }
        let control = AssessmentControl(timeout: timeout)
        self.control = control
        running = module
        progress = AssessmentProgress(completed: 0, total: 0, current: "Starting")
        message = nil
        return control
    }

    private func finish(_ record: SecurityAssessmentRecord) {
        running = nil
        control = nil
        progress = nil
        do {
            try store.save(record)
        } catch {
            message = "The report could not be saved: \(error.localizedDescription)"
        }
        lastResult[record.module] = record.id
        reload()
        let severity: ActivitySeverity = record.findings.contains { $0.severity >= .high } ? .warning : .info
        log.record(.system, "\(record.module.title): \(record.status.label). \(record.headline)", severity: severity)
    }

    private func report(progress value: AssessmentProgress) {
        DispatchQueue.main.async { [weak self] in
            guard self?.running != nil else { return }
            self?.progress = value
        }
    }

    /// Stops the running assessment. The partial report is still saved and marked incomplete.
    func stop(reason: String = "Stopped by you") {
        guard let control = control else { return }
        control.cancel()
        log.record(.system, "Security Lab: \(reason)", severity: .notice)
    }

    // MARK: Secret Scanner

    func addSources(_ urls: [URL]) {
        for url in urls where !sources.contains(url) { sources.append(url) }
    }

    func removeSource(_ url: URL) {
        sources.removeAll { $0 == url }
    }

    var exclusions: [String] {
        exclusionsText.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func suppress(_ fingerprint: String) {
        suppressed.insert(fingerprint)
        defaults.set(Array(suppressed), forKey: Keys.suppressed)
        log.record(.system, "Secret Scanner: a finding was marked as a false positive")
    }

    func clearSuppressions() {
        suppressed = []
        defaults.removeObject(forKey: Keys.suppressed)
    }

    func startSecretScan() {
        guard !sources.isEmpty else { return }
        var configuration = SecretScanConfiguration(fingerprintKey: fingerprintKey)
        configuration.exclusions = exclusions
        configuration.suppressedFingerprints = suppressed
        guard let control = begin(.secretScanner, timeout: configuration.timeout) else { return }
        let sources = self.sources
        log.record(.system, "Secret Scanner started on \(sources.count) selected item(s). Nothing leaves this device.")
        queue.async { [weak self] in
            let accessing = sources.map { $0.startAccessingSecurityScopedResource() }
            defer { for (url, granted) in zip(sources, accessing) where granted { url.stopAccessingSecurityScopedResource() } }
            let record = SecretScanner(configuration: configuration).scan(sources, control: control) { self?.report(progress: $0) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if record.checks.contains(where: { $0.outcome == .passed || $0.outcome == .finding }) {
                    self.registry.recordVerified(.secretScanning, evidence: "A scan completed and read text files")
                }
                self.finish(record)
            }
        }
    }

    // MARK: Exposure Check

    func exposureScope() throws -> TargetScope {
        try TargetScope.parse(exposureEntries.map { (text: $0.text, localNetwork: $0.localNetwork) })
    }

    var canStartExposure: Bool {
        remoteConnectionsEnabled && authorizationConfirmed && !previewMode && running == nil
            && ((try? exposureScope())?.targets.isEmpty == false)
    }

    func startExposureCheck() {
        guard remoteConnectionsEnabled, authorizationConfirmed else { return }
        let scope: TargetScope
        do {
            scope = try exposureScope()
        } catch {
            message = "\(error)"
            return
        }
        guard !scope.targets.isEmpty else { return }
        let configuration = ExposureCheckConfiguration()
        guard let control = begin(.exposureCheck, timeout: configuration.overallTimeout) else { return }
        log.record(.system, "Exposure Check started for \(scope.targets.count) target(s) you confirmed you may test")
        let transport = exposureTransport
        queue.async { [weak self] in
            let record = ExposureCheck(transport: transport, configuration: configuration).run(scope: scope, control: control) { self?.report(progress: $0) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if record.checks.contains(where: { $0.id.hasPrefix("reachability@") && $0.outcome == .passed }) {
                    self.registry.recordVerified(.exposureCheck, evidence: "A target you entered returned an HTTP response")
                }
                self.finish(record)
            }
        }
    }

    // MARK: Authentication Defense Lab

    var labIsRunning: Bool { labServer?.isRunning == true }

    func startLab() {
        guard labServer == nil || labServer?.isRunning == false, !previewMode else { return }
        let server = AuthLabServer(configuration: labConfiguration)
        do {
            labTarget = try server.start()
            labServer = server
            labURL = labTarget?.baseURL
            log.record(.system, "Authentication Defense Lab service started on \(labTarget?.baseURL.absoluteString ?? "loopback") (this device only)")
        } catch {
            message = "The lab service could not start: \(error)"
            registry.recordFailure(.authDefenseLab, reason: "The loopback lab service could not start")
        }
        objectWillChange.send()
    }

    func stopLab() {
        if running == .authDefenseLab { stop(reason: "Lab service stopped") }
        labServer?.stop()
        labServer = nil
        labTarget = nil
        labURL = nil
        log.record(.system, "Authentication Defense Lab service stopped")
    }

    var labEvents: [AuthLabEvent] { labServer?.service.events ?? [] }

    var wrongPasswords: [String] {
        wrongPasswordsText.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
    }

    func labPlan() -> AuthDefensePlan? {
        guard let target = labTarget else { return nil }
        return AuthDefensePlan(target: target, account: AuthLabService.designatedTestAccounts[0], wrongPasswords: wrongPasswords,
                               attemptCap: attemptCap, interval: 1.5, requestTimeout: 5, expectations: expectations)
    }

    var labPlanProblem: String? {
        guard let plan = labPlan() else { return "Start the lab service first." }
        do {
            try AuthDefenseAssessment().validate(plan)
            return nil
        } catch {
            return "\(error)"
        }
    }

    func startAuthAssessment() {
        guard let plan = labPlan(), labPlanProblem == nil, let control = begin(.authDefenseLab, timeout: plan.overallTimeout) else { return }
        labServer?.service.reset(configuration: labConfiguration)
        log.record(.system, "Authentication Defense Lab assessment started: at most \(plan.attemptCap) attempts against the bundled lab")
        queue.async { [weak self] in
            let record = AuthDefenseAssessment().run(plan, control: control) { self?.report(progress: $0) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if record.workCompleted > 0 && record.status != .failedToExecute {
                    self.registry.recordVerified(.authDefenseLab, evidence: "The bundled lab answered login attempts")
                }
                self.finish(record)
            }
        }
    }

    // MARK: Reports

    func delete(_ id: UUID) {
        store.delete(id)
        reload()
    }

    func deleteAllReports() {
        store.deleteAll()
        reload()
        log.record(.system, "All Security Lab reports deleted")
    }

    /// Writes the redacted report to a temporary file for sharing. The file is replaced on each export.
    func exportFile(for record: SecurityAssessmentRecord) -> URL? {
        let text = SecurityReportRenderer.text(record)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Sentinel-\(record.module.rawValue)-report.md")
        do {
            try Data(text.utf8).write(to: url, options: [.atomic])
            log.record(.system, "\(record.module.title) report exported (redacted)")
            return url
        } catch {
            message = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// References for other HCG surfaces: status and counts only, never report contents.
    var references: [SecurityReportReference] { reports.prefix(5).map { $0.reference } }
}
