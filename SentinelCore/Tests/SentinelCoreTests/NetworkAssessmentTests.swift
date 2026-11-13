import XCTest
@testable import SentinelCore

final class ManualScheduler: AssessmentScheduler {
    private(set) var pending: [(TimeInterval, () -> Void)] = []
    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) { pending.append((seconds, block)) }
    func fireAll() {
        let blocks = pending
        pending.removeAll()
        blocks.forEach { $0.1() }
    }
}

final class MockAssessmentProbe: NetworkAssessmentProbe {
    final class Task: AssessmentCancellable {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    var connection: ConnectionFacts? = ConnectionFacts(isOnline: true, statusDescription: "Online", interfaceTypes: ["Wi-Fi"],
                                                       supportsIPv6: true, gateways: ["192.0.2.1"])
    var wifi = WiFiFacts(ssid: "HomeLab", bssid: "02:00:00:00:00:01", security: .personal)
    var proxy = ProxyFacts()
    var resolveResults: [String: ResolveOutcome] = [:]
    var nonexistentResult: ResolveOutcome = .notFound
    var fetchResults: [String: FetchOutcome] = [:]
    /// Operations listed here never complete (to test cancellation and timeouts).
    var hang: Set<String> = []
    private(set) var resolvedHosts: [String] = []
    private(set) var fetchedURLs: [String] = []
    private(set) var tasks: [Task] = []
    var lateCompletions: [() -> Void] = []

    func connectionFacts(completion: @escaping (ConnectionFacts?) -> Void) {
        if hang.contains("connection") { return }
        completion(connection)
    }

    func wifiFacts(completion: @escaping (WiFiFacts) -> Void) { completion(wifi) }
    func proxyFacts(completion: @escaping (ProxyFacts) -> Void) { completion(proxy) }

    func resolve(host: String, timeout: TimeInterval, completion: @escaping (ResolveOutcome) -> Void) -> AssessmentCancellable? {
        resolvedHosts.append(host)
        let task = Task()
        tasks.append(task)
        let result = resolveResults[host] ?? (host == "example.com" ? .addresses(["93.184.215.14"]) : nonexistentResult)
        if hang.contains(host) || hang.contains("resolve") {
            lateCompletions.append { completion(result) }
        } else {
            completion(result)
        }
        return task
    }

    func fetch(url: URL, timeout: TimeInterval, completion: @escaping (FetchOutcome) -> Void) -> AssessmentCancellable? {
        fetchedURLs.append(url.absoluteString)
        let task = Task()
        tasks.append(task)
        let defaultResult: FetchOutcome = url.scheme == "http"
            ? .response(status: 200, location: nil, bodyPrefix: "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>", certificates: [])
            : .response(status: 200, location: nil, bodyPrefix: "<!doctype html>", certificates: [url.host ?? "", "Test Root CA"])
        let result = fetchResults[url.absoluteString] ?? defaultResult
        if hang.contains(url.absoluteString) {
            lateCompletions.append { completion(result) }
        } else {
            completion(result)
        }
        return task
    }
}

final class NetworkAssessmentTests: XCTestCase {
    private var probe: MockAssessmentProbe!
    private var scheduler: ManualScheduler!
    private var assessment: NetworkAssessment!
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        probe = MockAssessmentProbe()
        scheduler = ManualScheduler()
        assessment = NetworkAssessment(probe: probe, scheduler: scheduler, now: { [unowned self] in self.clock },
                                       randomLabel: { "sentinel-check-0001" })
    }

    private func runAssessment() -> AssessmentReport {
        assessment.start()
        guard case .finished(let report) = assessment.state else {
            XCTFail("expected a finished report, state \(assessment.state)")
            return AssessmentReport(startedAt: clock, finishedAt: clock, findings: [], completedSteps: 0, totalSteps: 0, cancelled: false)
        }
        return report
    }

    private func finding(_ report: AssessmentReport, _ id: String) -> AssessmentFinding? {
        report.findings.first { $0.id == id }
    }

    // MARK: Report wording

    func testCleanResultIsNeverCalledSafe() {
        let report = runAssessment()
        XCTAssertEqual(report.count(.securityConcern), 0)
        XCTAssertEqual(report.count(.connectivityProblem), 0)
        XCTAssertEqual(report.headline, "No security concerns found by these checks")
        XCTAssertFalse(report.headline.lowercased().contains("safe"))
        XCTAssertTrue(report.disclaimer.contains("does not mean the network is safe"))
        XCTAssertEqual(report.completedSteps, AssessmentStep.allCases.count)
        for finding in report.findings {
            XCTAssertFalse(finding.evidence.isEmpty, finding.id)
            XCTAssertFalse(finding.limitations.isEmpty, finding.id)
            XCTAssertEqual(finding.observedAt, clock, finding.id)
        }
        XCTAssertEqual(probe.resolvedHosts, ["example.com", "sentinel-check-0001.example.com"])
        XCTAssertEqual(probe.fetchedURLs, ["http://captive.apple.com/hotspot-detect.html", "https://example.com/",
                                           "https://www.apple.com/library/test/success.html"])
    }

    func testHeadlineNeverClaimsSafetyInAnyState() {
        let kinds: [AssessmentFinding.Kind] = [.securityConcern, .notice, .connectivityProblem, .unavailable, .notChecked, .observation]
        for kind in kinds {
            for cancelled in [false, true] {
                let finding = AssessmentFinding(id: "x", step: .connection, kind: kind, title: "t", evidence: ["e"],
                                                observedAt: clock, limitations: "l", remediation: nil)
                let report = AssessmentReport(startedAt: clock, finishedAt: clock, findings: [finding], completedSteps: 1,
                                              totalSteps: 8, cancelled: cancelled)
                XCTAssertFalse(report.headline.lowercased().contains("safe"), report.headline)
            }
        }
    }

    // MARK: Offline and connectivity

    func testOfflineSkipsNetworkTestsWithoutClaimingThreats() {
        probe.connection = ConnectionFacts(isOnline: false, statusDescription: "No network connection", interfaceTypes: [])
        let report = runAssessment()
        XCTAssertEqual(finding(report, "connection.offline")?.kind, .connectivityProblem)
        for step in AssessmentStep.allCases where step.usesNetwork {
            XCTAssertEqual(finding(report, "\(step.rawValue).skipped")?.kind, .notChecked, step.rawValue)
        }
        XCTAssertEqual(report.count(.securityConcern), 0)
        XCTAssertTrue(probe.resolvedHosts.isEmpty, "nothing is sent while offline")
        XCTAssertTrue(probe.fetchedURLs.isEmpty)
        XCTAssertTrue(report.headline.contains("could not complete"))
    }

    func testConnectivityFailuresAreNotReportedAsThreats() {
        probe.resolveResults["example.com"] = .failed("No route to host")
        probe.nonexistentResult = .failed("No route to host")
        probe.fetchResults["http://captive.apple.com/hotspot-detect.html"] = .connectivityFailure(code: -1004, message: "Could not connect")
        probe.fetchResults["https://example.com/"] = .timedOut
        probe.fetchResults["https://www.apple.com/library/test/success.html"] = FetchErrorClassifier.classify(code: -1009, message: "Offline")
        let report = runAssessment()
        XCTAssertEqual(report.count(.securityConcern), 0)
        XCTAssertEqual(report.count(.notice), 0)
        XCTAssertEqual(report.count(.connectivityProblem), 5)
        for finding in report.findings where finding.kind == .connectivityProblem && finding.step.usesNetwork {
            XCTAssertFalse(finding.title.lowercased().contains("attack"), finding.title)
        }
    }

    func testConnectionStateUnavailable() {
        probe.connection = nil
        let report = runAssessment()
        XCTAssertEqual(finding(report, "connection.unavailable")?.kind, .unavailable)
        XCTAssertEqual(finding(report, "dnsResolution.skipped")?.evidence, ["The connection state could not be determined."])
    }

    func testNotOnWiFiIsANotice() {
        probe.connection = ConnectionFacts(isOnline: true, statusDescription: "Online", interfaceTypes: ["Cellular"])
        let report = runAssessment()
        XCTAssertEqual(finding(report, "connection.notwifi")?.kind, .notice)
        XCTAssertTrue(finding(report, "connection.notwifi")?.evidence.contains("Gateway: not reported by the system") ?? false)
    }

    // MARK: Security findings

    func testDnsRewritingIsAConcern() {
        probe.nonexistentResult = .addresses(["198.51.100.7"])
        let report = runAssessment()
        let rewrite = finding(report, "dnsIntegrity.rewrite")
        XCTAssertEqual(rewrite?.kind, .securityConcern)
        XCTAssertTrue(rewrite?.evidence.first?.contains("sentinel-check-0001.example.com") ?? false)
        XCTAssertNotNil(rewrite?.remediation)
        XCTAssertEqual(report.headline, "1 potential security concern found")
    }

    func testControlNameMissingIsNoticeAndIntegrityInconclusive() {
        probe.resolveResults["example.com"] = .notFound
        let report = runAssessment()
        XCTAssertEqual(finding(report, "dnsResolution.nxdomain")?.kind, .notice)
        XCTAssertEqual(finding(report, "dnsIntegrity.inconclusive")?.kind, .connectivityProblem)
        XCTAssertNil(finding(report, "dnsIntegrity.ok"), "'not found' only counts as correct when DNS demonstrably works")
    }

    func testUntrustedCertificateIsAConcernAndHandshakeFailureANotice() {
        probe.fetchResults["https://example.com/"] = FetchErrorClassifier.classify(code: -1202, message: "untrusted", certificates: ["example.com", "Evil CA"])
        probe.fetchResults["https://www.apple.com/library/test/success.html"] = FetchErrorClassifier.classify(code: -1200, message: "handshake failed")
        let report = runAssessment()
        let untrusted = finding(report, "httpsExample.untrusted")
        XCTAssertEqual(untrusted?.kind, .securityConcern)
        XCTAssertTrue(untrusted?.evidence.contains { $0.contains("Evil CA") } ?? false)
        XCTAssertEqual(finding(report, "httpsApple.tls")?.kind, .notice)
    }

    func testErrorClassifier() {
        XCTAssertEqual(FetchErrorClassifier.classify(code: -1001, message: ""), .timedOut)
        for code in [-1201, -1202, -1203, -1204] {
            guard case .trustFailure = FetchErrorClassifier.classify(code: code, message: "") else { return XCTFail("\(code)") }
        }
        for code in [-1200, -1205, -1206] {
            guard case .tlsFailure = FetchErrorClassifier.classify(code: code, message: "") else { return XCTFail("\(code)") }
        }
        for code in [-1003, -1004, -1005, -1009, -1020] {
            guard case .connectivityFailure = FetchErrorClassifier.classify(code: code, message: "") else { return XCTFail("\(code)") }
        }
    }

    func testCaptivePortalRedirectIsANotice() {
        probe.fetchResults["http://captive.apple.com/hotspot-detect.html"] = .response(status: 302, location: "http://portal.example/login", bodyPrefix: "", certificates: [])
        let report = runAssessment()
        let altered = finding(report, "captivePortal.altered")
        XCTAssertEqual(altered?.kind, .notice)
        XCTAssertTrue(altered?.evidence.contains("Redirected to: http://portal.example/login") ?? false)
    }

    func testWiFiSecurityAndUnavailableIdentity() {
        probe.wifi = WiFiFacts(ssid: "Cafe", bssid: nil, security: .open)
        var report = runAssessment()
        let open = finding(report, "wifiDetails.open")
        XCTAssertEqual(open?.kind, .securityConcern)
        XCTAssertTrue(open?.evidence.contains("BSSID: unavailable") ?? false, "missing values are shown as unavailable, never invented")

        probe.wifi = WiFiFacts(ssid: "Old", security: .wep)
        report = runAssessment()
        XCTAssertEqual(finding(report, "wifiDetails.wep")?.kind, .securityConcern)

        probe.wifi = WiFiFacts(unavailableReason: "Requires the Access Wi-Fi Information entitlement and location permission.")
        report = runAssessment()
        let unavailable = finding(report, "wifiDetails.identity")
        XCTAssertEqual(unavailable?.kind, .unavailable)
        XCTAssertEqual(unavailable?.evidence, ["Requires the Access Wi-Fi Information entitlement and location permission."])

        probe.wifi = WiFiFacts(ssid: "Home", bssid: "02:00:00:00:00:09", security: nil)
        report = runAssessment()
        XCTAssertEqual(finding(report, "wifiDetails.security")?.kind, .unavailable)
    }

    func testProxyAndTunnel() {
        probe.proxy = ProxyFacts(httpProxy: "10.0.0.5:8080", tunnelInterfaces: ["utun4"])
        var report = runAssessment()
        XCTAssertEqual(finding(report, "proxy.proxy")?.kind, .notice)
        XCTAssertEqual(finding(report, "proxy.proxy")?.evidence, ["HTTP proxy: 10.0.0.5:8080"])
        XCTAssertEqual(finding(report, "proxy.tunnel")?.kind, .notice)

        probe.proxy = ProxyFacts(unavailableReason: "The system returned no proxy settings.")
        report = runAssessment()
        XCTAssertEqual(finding(report, "proxy.unavailable")?.kind, .unavailable)
    }

    // MARK: Cancellation and limits

    func testCancelStopsInFlightRequestAndIgnoresLateResults() {
        probe.hang = ["example.com"]
        assessment.start()
        guard case .running(let step, let completed, let total) = assessment.state else { return XCTFail("should be running") }
        XCTAssertEqual(step, .dnsResolution)
        XCTAssertEqual(completed, 3)
        XCTAssertEqual(total, 8)

        assessment.cancel()
        XCTAssertTrue(probe.tasks.last?.cancelled ?? false, "the request in flight is cancelled")
        guard case .finished(let report) = assessment.state else { return XCTFail("should be finished") }
        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(report.headline.hasPrefix("Check cancelled"))
        XCTAssertEqual(finding(report, "dnsResolution.skipped")?.evidence, ["The check was cancelled before this step ran."])
        XCTAssertEqual(probe.fetchedURLs, [], "no further steps run after cancelling")

        probe.lateCompletions.forEach { $0() }
        scheduler.fireAll()
        guard case .finished(let after) = assessment.state else { return XCTFail("still finished") }
        XCTAssertEqual(after, report, "late results and timers do not change a cancelled report")
    }

    func testEngineEnforcesStepTimeLimit() {
        probe.hang = ["https://example.com/"]
        assessment.start()
        guard case .running(let step, _, _) = assessment.state else { return XCTFail("should be waiting on HTTPS") }
        XCTAssertEqual(step, .httpsExample)
        scheduler.fireAll() // all earlier steps already completed; only the HTTPS watchdog does anything
        guard case .finished(let report) = assessment.state else { return XCTFail("the watchdog finishes the step") }
        XCTAssertEqual(finding(report, "httpsExample.timeout")?.kind, .connectivityProblem)
        XCTAssertTrue(probe.tasks.first { $0.cancelled } != nil, "the hung request is cancelled")
        XCTAssertNotNil(finding(report, "httpsApple.trusted"), "the next step still runs")
        probe.lateCompletions.forEach { $0() }
        guard case .finished(let after) = assessment.state else { return XCTFail() }
        XCTAssertEqual(after, report)
    }

    func testHungConnectionProbeIsBounded() {
        probe.hang = ["connection"]
        assessment.start()
        scheduler.fireAll()
        guard case .finished(let report) = assessment.state else { return XCTFail() }
        XCTAssertEqual(finding(report, "connection.timeout")?.kind, .connectivityProblem)
        XCTAssertEqual(finding(report, "httpsApple.skipped")?.kind, .notChecked)
    }

    func testStartIsIgnoredWhileRunningAndRestartsAfterwards() {
        probe.hang = ["example.com"]
        assessment.start()
        assessment.start()
        XCTAssertEqual(probe.resolvedHosts, ["example.com"])
        assessment.cancel()
        probe.hang = []
        let report = runAssessment()
        XCTAssertFalse(report.cancelled)
        XCTAssertEqual(report.completedSteps, 8)
    }
}
