import Foundation
// Re-exported so the app reaches the Device Link client through SentinelCore,
// the only package the Xcode project links.
@_exported import HCGDeviceLink

/// Turns Sentinel results into `hcg.diagnostic-report/1` documents for sharing
/// with a paired device through HCG Server (Device Link). Every string goes
/// through Sentinel's own `Redactor` first and then the shared
/// `hcg.redaction/1` rules. Network identifiers (Wi-Fi name, BSSID, addresses)
/// are never shared.
public enum SentinelReportSharing {
    public static let app = "hcg.sentinel"

    /// Sentinel's redactor, then the shared rules.
    static func sentinelRedacted(_ s: String) -> String { Redactor.standard.text(s) }

    static func kind(_ module: SecurityModule) -> String {
        switch module {
        case .secretScanner: return "security-lab.secret-scanner"
        case .exposureCheck: return "security-lab.exposure-check"
        case .authDefenseLab: return "security-lab.auth-defense-lab"
        }
    }

    /// Whether a Security Lab record can be shared (finished runs only).
    public static func canShare(_ record: SecurityAssessmentRecord) -> Bool { record.status != .running }

    public static func report(from record: SecurityAssessmentRecord, installationId: String, appVersion: String, deviceName: String,
                              sharedAt: Date = Date()) -> DiagnosticReport {
        let r = sentinelRedacted
        let scope = record.scope.map { "\($0.kind.label): \(r($0.value))" + ($0.localNetwork ? " (local network)" : "") }
        let findings = record.findings.map { f in
            DiagnosticReport.Finding(title: r(f.title), severity: f.severity.rawValue, confidence: f.confidence.rawValue, basis: f.basis.rawValue,
                                     location: f.location.map(r), evidence: f.evidence.map(r), explanation: r(f.explanation),
                                     remediation: r(f.remediation))
        }
        let checks = record.checks.map { c in
            DiagnosticReport.Check(title: r(c.title) + (c.target.map { " (\(r($0)))" } ?? ""), outcome: c.outcome.rawValue, detail: r(c.detail))
        }
        var limitations = record.limitations.map(r)
        if record.suppressedCount > 0 {
            limitations.append("\(record.suppressedCount) finding(s) marked as false positives were hidden by the user.")
        }
        limitations += record.errors.map { "Execution error: " + r($0) }
        limitations.append("Performed on: \(record.location.label).")
        return DiagnosticReport.make(
            reportId: record.id.uuidString, kind: kind(record.module), title: "\(record.module.title) — \(record.headline)",
            origin: .init(app: app, appVersion: appVersion, installationId: installationId, deviceName: deviceName,
                          module: record.module.rawValue, moduleVersion: record.moduleVersion),
            createdAt: record.startedAt, completedAt: record.endedAt,
            summary: .init(status: record.status.rawValue, highestSeverity: record.highestSeverity?.rawValue, findingCount: record.findings.count),
            scope: scope, findings: findings, checks: checks, limitations: limitations, notTested: record.notTested.map(r),
            redactor: .standard, sharedAt: sharedAt)
    }

    /// Check My Network results. Strict redaction: IP and MAC addresses and
    /// e-mail addresses are masked, and Wi-Fi details are withheld entirely.
    public static func report(from network: AssessmentReport, reportId: String = UUID().uuidString, installationId: String,
                              appVersion: String, deviceName: String, sharedAt: Date = Date()) -> DiagnosticReport {
        let r = sentinelRedacted
        let concerns = network.findings.filter { $0.kind == .securityConcern || $0.kind == .notice }
        let findings = concerns.map { f in
            DiagnosticReport.Finding(title: r(f.title), severity: f.kind == .securityConcern ? "medium" : "info", confidence: nil, basis: "observation",
                                     location: f.step.title, evidence: evidence(f), explanation: r(f.limitations), remediation: f.remediation.map(r))
        }
        let checks = network.findings.map { f in
            DiagnosticReport.Check(title: f.step.title, outcome: outcome(f.kind), detail: r(f.title))
        }
        let status = network.cancelled ? "cancelled" : "completed"
        return DiagnosticReport.make(
            reportId: reportId, kind: "network-check", title: "Check My Network — \(network.headline)",
            origin: .init(app: app, appVersion: appVersion, installationId: installationId, deviceName: deviceName, module: "networkCheck", moduleVersion: nil),
            createdAt: network.startedAt, completedAt: network.finishedAt,
            summary: .init(status: status, highestSeverity: concerns.contains { $0.kind == .securityConcern } ? "medium" : nil, findingCount: concerns.count),
            scope: ["The network this device was connected to (\(network.completedSteps) of \(network.totalSteps) steps)"],
            findings: findings, checks: checks,
            limitations: [AssessmentReport.disclaimer, "Network names, BSSIDs, IP and MAC addresses are withheld from shared reports."],
            notTested: network.findings.filter { $0.kind == .notChecked }.map { $0.step.title },
            redactor: .strict, sharedAt: sharedAt)
    }

    static func evidence(_ f: AssessmentFinding) -> [String] {
        if f.step == .wifiDetails { return ["Wi-Fi details withheld from shared reports."] }
        return f.evidence.map(sentinelRedacted)
    }

    static func outcome(_ k: AssessmentFinding.Kind) -> String {
        switch k {
        case .securityConcern: return "finding"
        case .notice: return "notice"
        case .connectivityProblem: return "failedToExecute"
        case .unavailable: return "unsupported"
        case .notChecked: return "notChecked"
        case .observation: return "passed"
        }
    }
}

/// Sentinel's Device Link identity: what this installation tells HCG Server
/// about itself. Sentinel only sends reports; it advertises no Terminal or
/// privileged capability.
public enum SentinelLinkIdentity {
    public static let contract = "hcg.sentinel.connect/1"

    public static func capabilities() -> [LinkCapability] {
        [LinkCapability(id: LinkCapabilityID.reportSend, state: .available)]
    }

    public static func installationInfo(identity: InstallationIdentity, name: String, platform: String, appVersion: String,
                                        deviceId: String?) -> LinkInstallationInfo {
        LinkInstallationInfo(installationId: identity.installationId, deviceId: deviceId, name: name, platform: platform, app: SentinelReportSharing.app,
                             appVersion: appVersion, variant: nil, publicKey: identity.signer.publicKeyBase64, capabilities: capabilities())
    }
}
