import XCTest
@testable import SentinelCore

/// Sentinel → hcg.diagnostic-report/1 conversion (unit tests, no network).
final class DeviceLinkSharingTests: XCTestCase {
    let installation = "0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a"

    func securityRecord() -> SecurityAssessmentRecord {
        var record = SecurityAssessmentRecord(module: .exposureCheck,
                                              scope: [ScopeItem(kind: .url, value: "https://admin:hunter2@example.test/login?token=abc123")],
                                              location: .thisDevice, permissions: ["network"], startedAt: Date(timeIntervalSince1970: 1_794_650_000),
                                              limits: AssessmentLimits(overallTimeout: 60), limitations: ["Checked from one network."])
        record.status = .completed
        record.endedAt = Date(timeIntervalSince1970: 1_794_650_060)
        record.findings = [SecurityFinding(id: "f1", checkID: "banner", title: "Version banner exposed", severity: .medium, confidence: .high,
                                           basis: .verified, location: "https://example.test/",
                                           evidence: ["Server: nginx/1.18.0", "Authorization: Bearer abcdefghijklmnop123456", "Set-Cookie: session=s3cr3t"],
                                           explanation: "The banner reveals the version.", remediation: "Hide the version.")]
        record.checks = [CheckResult(id: "tls", title: "TLS", target: "https://example.test", outcome: .passed, detail: "TLS 1.3")]
        record.suppressedCount = 1
        return record
    }

    func testSecurityLabRecordBecomesARedactedValidReport() throws {
        let report = SentinelReportSharing.report(from: securityRecord(), installationId: installation, appVersion: "1.4.0", deviceName: "Ana's iPhone")
        XCTAssertEqual(report.schema, DeviceLinkProtocol.reportSchema)
        XCTAssertEqual(report.kind, "security-lab.exposure-check")
        XCTAssertEqual(report.origin.app, "hcg.sentinel")
        XCTAssertEqual(report.origin.installationId, installation)
        XCTAssertTrue(report.redaction.applied)
        XCTAssertEqual(report.summary.findingCount, 1)
        XCTAssertEqual(report.summary.highestSeverity, "medium")
        let text = String(decoding: try report.encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("abcdefghijklmnop123456"))
        XCTAssertFalse(text.contains("s3cr3t"))
        XCTAssertFalse(text.contains("abc123"))
        XCTAssertTrue(text.contains("nginx/1.18.0"), "non-secret evidence is kept")
        XCTAssertEqual(ReportValidator.problems(report, encoded: try report.encoded()), [])
        XCTAssertTrue(report.limitations.contains { $0.contains("false positives") })
    }

    func testRunningAssessmentsAreNotShareable() {
        var r = securityRecord()
        r.status = .running
        XCTAssertFalse(SentinelReportSharing.canShare(r))
        XCTAssertTrue(SentinelReportSharing.canShare(securityRecord()))
    }

    func testNetworkCheckWithholdsNetworkIdentifiers() throws {
        let now = Date(timeIntervalSince1970: 1_794_650_000)
        let findings = [
            AssessmentFinding(id: "wifi", step: .wifiDetails, kind: .securityConcern, title: "Open Wi-Fi network (no encryption)",
                              evidence: ["Network: HomeNet-5G", "BSSID: aa:bb:cc:dd:ee:ff"], observedAt: now, limitations: "From the OS.",
                              remediation: "Use WPA2 or WPA3."),
            AssessmentFinding(id: "dns", step: .dnsResolution, kind: .observation, title: "DNS answered",
                              evidence: ["Resolver answered with 93.184.216.34 via gateway 192.168.1.1"], observedAt: now, limitations: "", remediation: nil),
            AssessmentFinding(id: "portal", step: .captivePortal, kind: .notChecked, title: "Not checked", evidence: [], observedAt: now,
                              limitations: "", remediation: nil),
        ]
        let net = AssessmentReport(startedAt: now, finishedAt: now.addingTimeInterval(20), findings: findings, completedSteps: 7, totalSteps: 8, cancelled: false)
        let report = SentinelReportSharing.report(from: net, installationId: installation, appVersion: "1.4.0", deviceName: "Ana's iPhone")
        let text = String(decoding: try report.encoded(), as: UTF8.self)
        for leaked in ["HomeNet-5G", "aa:bb:cc:dd:ee:ff", "93.184.216.34", "192.168.1.1"] {
            XCTAssertFalse(text.contains(leaked), "\(leaked) must not be shared")
        }
        XCTAssertEqual(report.kind, "network-check")
        XCTAssertEqual(report.summary.findingCount, 1)
        XCTAssertEqual(report.notTested, ["Captive portal / HTTP interception"])
        XCTAssertEqual(ReportValidator.problems(report, encoded: try report.encoded()), [])
    }

    func testSentinelAdvertisesOnlyReportSending() {
        let caps = SentinelLinkIdentity.capabilities()
        XCTAssertEqual(caps.map(\.id), [LinkCapabilityID.reportSend])
        XCTAssertFalse(caps.contains { $0.id.hasPrefix("terminal.") })
    }
}
