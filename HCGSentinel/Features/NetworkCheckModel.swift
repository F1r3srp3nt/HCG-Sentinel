import Foundation
import SentinelCore

/// Runs Check My Network. Starts only when the user presses Start; Cancel stops it at once.
final class NetworkCheckModel: ObservableObject {
    @Published private(set) var state: NetworkAssessment.State = .idle
    @Published private(set) var previewMode = false

    private let assessment: NetworkAssessment
    private let log: ActivityLog
    private let registry: CapabilityRegistry

    init(probe: NetworkAssessmentProbe, log: ActivityLog, registry: CapabilityRegistry) {
        self.assessment = NetworkAssessment(probe: probe)
        self.log = log
        self.registry = registry
        assessment.onChange = { [weak self] in self?.assessmentChanged() }
    }

    var isRunning: Bool { assessment.isRunning }

    var report: AssessmentReport? {
        if case .finished(let report) = state { return report }
        return nil
    }

    func apply(_ settings: SentinelSettings) {
        previewMode = settings.previewMode
        if previewMode && assessment.isRunning { cancel() }
    }

    func start() {
        guard !previewMode, !assessment.isRunning else { return }
        log.record(.network, "Check My Network started (contacts example.com, captive.apple.com and www.apple.com)")
        assessment.start()
    }

    func cancel() {
        guard assessment.isRunning else { return }
        assessment.cancel()
        log.record(.network, "Check My Network cancelled")
    }

    private func assessmentChanged() {
        state = assessment.state
        guard case .finished(let report) = assessment.state else { return }
        let concerns = report.count(.securityConcern)
        log.record(.network, "Check My Network finished: \(report.headline)", severity: concerns > 0 ? .warning : .info)
        // Verified only when at least one network test actually got an answer.
        let answered = report.findings.contains { $0.step.usesNetwork && ($0.kind == .observation || $0.kind == .notice || $0.kind == .securityConcern) }
        if answered && !report.cancelled {
            registry.recordVerified(.networkAssessment, evidence: "A Check My Network run completed with network tests answered")
        }
    }
}
