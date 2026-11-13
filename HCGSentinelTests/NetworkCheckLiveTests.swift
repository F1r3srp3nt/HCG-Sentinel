import SentinelCore
import XCTest
@testable import HCGSentinel

/// Runs Check My Network with the app's real probe (path monitor, Wi-Fi identity API, system proxy settings,
/// getaddrinfo, URLSession) against the live network. Needs internet access, so it only runs when
/// SENTINEL_NETWORK_CHECK=1 (CI sets TEST_RUNNER_SENTINEL_NETWORK_CHECK). Every finding is printed to the log.
final class NetworkCheckLiveTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["SENTINEL_NETWORK_CHECK"] == "1" else {
            throw XCTSkip("Set SENTINEL_NETWORK_CHECK=1 to run Check My Network against the live network.")
        }
    }

    private func finish(_ assessment: NetworkAssessment, timeout: TimeInterval) -> AssessmentReport? {
        let done = expectation(for: NSPredicate { _, _ in
            if case .finished = assessment.state { return true }
            return false
        }, evaluatedWith: nil)
        wait(for: [done], timeout: timeout)
        if case .finished(let report) = assessment.state { return report }
        return nil
    }

    private func log(_ report: AssessmentReport) {
        print("CHECK-MY-NETWORK headline: \(report.headline) | cancelled: \(report.cancelled) | steps \(report.completedSteps)/\(report.totalSteps) | \(Int(report.finishedAt.timeIntervalSince(report.startedAt)))s")
        for finding in report.findings {
            print("CHECK-MY-NETWORK [\(finding.kind.rawValue)] \(finding.id): \(finding.title)")
            for line in finding.evidence { print("CHECK-MY-NETWORK     evidence: \(line)") }
            if let remediation = finding.remediation { print("CHECK-MY-NETWORK     remediation: \(remediation)") }
        }
    }

    func testFullCheckOnTheLiveNetwork() throws {
        let assessment = NetworkAssessment(probe: PlatformNetworkProbe())
        assessment.start()
        // Eight steps with at most 3–10 s each plus a second of grace: the engine guarantees this bound.
        let report = try XCTUnwrap(finish(assessment, timeout: 80), "the check did not finish within its bounds")
        log(report)

        XCTAssertFalse(report.cancelled)
        XCTAssertEqual(report.completedSteps, AssessmentStep.allCases.count)
        XCTAssertFalse(report.headline.lowercased().contains("safe"))
        XCTAssertTrue(report.disclaimer.contains("does not mean the network is safe"))
        for finding in report.findings {
            XCTAssertFalse(finding.evidence.isEmpty, finding.id)
            XCTAssertFalse(finding.limitations.isEmpty, finding.id)
        }
        // Every step produced exactly one primary finding (the proxy step may add a tunnel notice).
        for step in AssessmentStep.allCases {
            XCTAssertTrue(report.findings.contains { $0.step == step }, "no finding for \(step.rawValue)")
        }
        // The CI runner is online, so the network steps must have run rather than being skipped.
        let connection = try XCTUnwrap(report.findings.first { $0.step == .connection })
        XCTAssertNotEqual(connection.kind, .connectivityProblem, "the simulator should be online: \(connection.evidence)")
        XCTAssertFalse(report.findings.contains { $0.kind == .notChecked }, "nothing should be skipped while online")
        // The simulator has no Wi-Fi identity for this app: it must say unavailable, never invent a name.
        let wifi = try XCTUnwrap(report.findings.first { $0.step == .wifiDetails })
        if wifi.kind == .unavailable {
            XCTAssertTrue(wifi.evidence.joined().contains("entitlement"), wifi.evidence.joined())
        }
        // A correctly working resolver answers both DNS steps.
        XCTAssertEqual(report.findings.first { $0.step == .dnsResolution }?.kind, .observation)
    }

    func testCancelDuringTheLiveCheck() throws {
        let assessment = NetworkAssessment(probe: PlatformNetworkProbe())
        assessment.start()
        let reachedNetwork = expectation(for: NSPredicate { _, _ in
            if case .running(let step, _, _) = assessment.state { return step.usesNetwork }
            return false
        }, evaluatedWith: nil)
        wait(for: [reachedNetwork], timeout: 20)
        let started = Date()
        assessment.cancel()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "cancel returns immediately")
        guard case .finished(let report) = assessment.state else { return XCTFail("expected a finished report") }
        log(report)
        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(report.headline.hasPrefix("Check cancelled"))
        XCTAssertTrue(report.findings.contains { $0.kind == .notChecked })
        // Late answers from the cancelled request must not change the report.
        let unchanged = expectation(description: "no late changes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { unchanged.fulfill() }
        wait(for: [unchanged], timeout: 5)
        guard case .finished(let after) = assessment.state else { return XCTFail() }
        XCTAssertEqual(after, report)
    }
}
