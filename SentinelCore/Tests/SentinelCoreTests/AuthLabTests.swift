import XCTest
@testable import SentinelCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class AuthLabServiceTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func service(_ configure: (inout AuthLabConfiguration) -> Void = { _ in }) -> AuthLabService {
        var configuration = AuthLabConfiguration()
        configure(&configuration)
        return AuthLabService(configuration: configuration, now: { self.clock })
    }

    func testLockoutThenExpiry() {
        let lab = service { $0.rateLimitEnabled = false; $0.lockoutThreshold = 3; $0.lockoutDuration = 60 }
        XCTAssertEqual((1...3).map { _ in lab.login(account: "lab-alice", password: "wrong").status }, [401, 401, 401])
        XCTAssertEqual(lab.login(account: "lab-alice", password: "wrong").status, 423)
        clock = clock.addingTimeInterval(61)
        XCTAssertEqual(lab.login(account: "lab-alice", password: "wrong").status, 401, "lockout expires")
        XCTAssertEqual(lab.login(account: "lab-bob", password: "wrong").status, 401, "accounts are independent")
    }

    func testRateLimitWithRetryAfter() {
        let lab = service { $0.lockoutEnabled = false; $0.rateLimitAttempts = 2; $0.rateLimitWindow = 30 }
        XCTAssertEqual(lab.login(account: "lab-alice", password: "a").status, 401)
        XCTAssertEqual(lab.login(account: "lab-alice", password: "b").status, 401)
        let throttled = lab.login(account: "lab-alice", password: "c")
        XCTAssertEqual(throttled.status, 429)
        XCTAssertEqual(throttled.headers["Retry-After"], "30")
        clock = clock.addingTimeInterval(31)
        XCTAssertEqual(lab.login(account: "lab-alice", password: "d").status, 401)
    }

    func testGenericAndRevealingErrors() {
        let generic = service()
        XCTAssertEqual(generic.login(account: "nobody", password: "x"), generic.login(account: "lab-bob", password: "x"))
        let revealing = service { $0.errorMode = .revealing }
        XCTAssertEqual(revealing.login(account: "nobody", password: "x").status, 404)
        XCTAssertEqual(revealing.login(account: "lab-bob", password: "x").status, 401)
    }

    func testEventLogRequiresTokenAndCanBeOff() throws {
        let lab = service()
        _ = lab.login(account: "lab-alice", password: "x")
        XCTAssertEqual(lab.events.map { $0.outcome }, [.wrongPassword])
        XCTAssertEqual(lab.handle(LabHTTPRequest(method: "GET", path: "/lab/events")).status, 403)
        XCTAssertEqual(lab.handle(LabHTTPRequest(method: "GET", path: "/lab/events", headers: ["X-Lab-Token": "nope"])).status, 403)
        let ok = lab.handle(LabHTTPRequest(method: "GET", path: "/lab/events", headers: ["X-Lab-Token": lab.adminToken]))
        XCTAssertEqual(ok.status, 200)
        XCTAssertTrue(String(decoding: ok.body, as: UTF8.self).contains("wrongPassword"))

        let quiet = service { $0.loggingEnabled = false }
        _ = quiet.login(account: "lab-alice", password: "x")
        XCTAssertTrue(quiet.events.isEmpty)
    }

    func testInfoNeverExposesPasswordsAndBadRequestsAreRejected() {
        let lab = service()
        let info = String(decoding: lab.handle(LabHTTPRequest(method: "GET", path: "/lab/info")).body, as: UTF8.self)
        XCTAssertTrue(info.contains(lab.instanceID))
        XCTAssertTrue(info.contains("lab-alice"))
        XCTAssertFalse(info.lowercased().contains("password"))
        XCTAssertEqual(lab.handle(LabHTTPRequest(method: "POST", path: "/login", body: Array("not json".utf8))).status, 400)
        XCTAssertEqual(lab.handle(LabHTTPRequest(method: "GET", path: "/admin")).status, 404)
    }

    func testRequestParsing() {
        let raw = Array("POST /login HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nabcd".utf8)
        let request = LoopbackHTTPServer.parse(raw)
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.body, Array("abcd".utf8))
        XCTAssertNil(LoopbackHTTPServer.parse(Array(raw.dropLast(2))), "waits for the whole body")
        XCTAssertNil(LoopbackHTTPServer.parse(Array("GET / HTTP/1.1\r\n".utf8)))
        let bytes = String(decoding: LoopbackHTTPServer.serialize(.json(423, ["error": "x"])), as: UTF8.self)
        XCTAssertTrue(bytes.hasPrefix("HTTP/1.1 423 Locked\r\n"))
    }
}

/// End to end over real loopback HTTP: the bundled lab server and the URLSession transport.
final class AuthDefenseAssessmentTests: XCTestCase {
    private var server: AuthLabServer!
    private var target: AuthLabTarget!

    private func startLab(_ configure: (inout AuthLabConfiguration) -> Void = { _ in }) throws {
        var configuration = AuthLabConfiguration()
        configure(&configuration)
        server = AuthLabServer(configuration: configuration)
        target = try server.start()
    }

    override func tearDown() {
        server?.stop()
    }

    private func plan(cap: Int = 6, passwords: [String] = ["Summer2026!", "letmein-01", "hunter22"],
                      expectations: AuthDefenseExpectations? = nil) -> AuthDefensePlan {
        AuthDefensePlan(target: target, account: "lab-alice", wrongPasswords: passwords, attemptCap: cap, interval: 0.05,
                        requestTimeout: 3, expectations: expectations ?? AuthDefenseExpectations(lab: server.service.currentConfiguration))
    }

    private func run(_ plan: AuthDefensePlan, control: AssessmentControl = AssessmentControl(timeout: 60)) -> SecurityAssessmentRecord {
        let record = AuthDefenseAssessment(transport: FoundationAuthLabTransport(), minimumInterval: 0, now: Date.init).run(plan, control: control)
        print("AUTH-LAB \(record.headline)")
        for check in record.checks { print("AUTH-LAB   [\(check.outcome.rawValue)] \(check.title): \(check.detail)") }
        return record
    }

    private func outcome(_ record: SecurityAssessmentRecord, _ id: String) -> CheckOutcome? {
        record.checks.first { $0.id == id }?.outcome
    }

    func testDefaultLabDefencesAreObserved() throws {
        try startLab()
        let record = run(plan())
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(outcome(record, "lockout"), .passed)
        XCTAssertEqual(outcome(record, "throttle"), .inconclusive, "locked before throttling could be measured")
        XCTAssertEqual(outcome(record, "errors"), .passed)
        XCTAssertEqual(outcome(record, "logging"), .passed)
        XCTAssertTrue(record.findings.isEmpty, "\(record.findings.map { $0.title })")
        let loginEvents = server.service.events
        XCTAssertEqual(loginEvents.count, 5, "probe + 3 failures + the locked attempt, then it stopped")
        XCTAssertEqual(loginEvents.last?.outcome, .lockedOut)
    }

    func testMissingDefencesAreVerifiedFindings() throws {
        try startLab { $0.lockoutEnabled = false; $0.rateLimitEnabled = false; $0.errorMode = .revealing; $0.loggingEnabled = false }
        let record = run(plan(cap: 6))
        XCTAssertEqual(Set(record.findings.map { $0.checkID }), ["lockout", "throttle", "errors", "logging"])
        XCTAssertTrue(record.findings.allSatisfy { $0.basis == .verified })
        XCTAssertEqual(record.findings.first { $0.checkID == "lockout" }?.severity, .high)
        XCTAssertTrue(record.workCompleted <= 6)
    }

    func testThrottlingIsDetectedWithoutRetrying() throws {
        try startLab { $0.lockoutEnabled = false; $0.rateLimitAttempts = 3 }
        let record = run(plan(cap: 10))
        XCTAssertEqual(outcome(record, "throttle"), .passed)
        let rateLimited = server.service.events.filter { $0.outcome == .rateLimited }
        XCTAssertEqual(rateLimited.count, 1, "the test stops at the first 429 and never retries")
        XCTAssertEqual(server.service.events.filter { $0.account == "lab-alice" }.count, 4)
    }

    func testExpectationMismatchAndTooLowCap() throws {
        try startLab()
        let mismatch = run(plan(expectations: AuthDefenseExpectations(lockoutAfter: 5, throttleAfter: nil, genericErrors: true, eventsLogged: true)))
        XCTAssertEqual(mismatch.findings.first?.id, "lockout-mismatch")

        server.service.reset(configuration: AuthLabConfiguration())
        let low = run(plan(cap: 3))
        XCTAssertEqual(outcome(low, "lockout"), .inconclusive)
        XCTAssertTrue(low.findings.isEmpty)
    }

    func testAttemptCapIsHard() throws {
        try startLab { $0.lockoutEnabled = false; $0.rateLimitEnabled = false }
        _ = run(plan(cap: 4, passwords: ["a1", "b2"]))
        XCTAssertEqual(server.service.events.count, 4, "exactly the cap, including the unknown-account probe")
    }

    func testPlanValidationAndScope() throws {
        try startLab()
        let assessment = AuthDefenseAssessment()
        var bad = plan()
        bad.interval = 0.1
        XCTAssertThrowsError(try assessment.validate(bad)) { XCTAssertEqual($0 as? AuthPlanError, .intervalTooShort) }
        bad = plan(); bad.interval = 1; bad.account = "lab-bob"
        XCTAssertThrowsError(try assessment.validate(bad))
        bad = plan(); bad.interval = 1; bad.attemptCap = 50
        XCTAssertThrowsError(try assessment.validate(bad)) { XCTAssertEqual($0 as? AuthPlanError, .capOutOfRange) }
        bad = plan(passwords: []); bad.interval = 1
        XCTAssertThrowsError(try assessment.validate(bad))
        bad = plan(passwords: Array(repeating: "x", count: 11)); bad.interval = 1
        XCTAssertThrowsError(try assessment.validate(bad))

        var external = plan()
        external.target = AuthLabTarget(baseURL: URL(string: "http://login.example.com")!, instanceID: target.instanceID, adminToken: "")
        let refused = run(external)
        XCTAssertEqual(refused.status, .unsupported)

        var impostor = plan()
        impostor.target = AuthLabTarget(baseURL: target.baseURL, instanceID: UUID().uuidString, adminToken: "")
        let unconfirmed = run(impostor)
        XCTAssertEqual(unconfirmed.status, .failedToExecute)
        XCTAssertTrue(server.service.events.isEmpty, "no password is sent before the lab identity is confirmed")
    }

    func testCancellationAndTimeLimit() throws {
        try startLab { $0.lockoutEnabled = false; $0.rateLimitEnabled = false }
        var slow = plan(cap: 10)
        slow.interval = 0.5
        let control = AssessmentControl(timeout: 60)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { control.cancel() }
        let started = Date()
        let cancelled = run(slow, control: control)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertLessThan(server.service.events.count, 10)

        server.service.reset(configuration: server.service.currentConfiguration)
        let expired = run(slow, control: AssessmentControl(timeout: 0.7))
        XCTAssertEqual(expired.status, .timedOut)
    }

    func testPasswordsNeverReachTheRecord() throws {
        try startLab { $0.lockoutEnabled = false; $0.rateLimitEnabled = false }
        let record = run(plan(passwords: ["Correct-Horse-Battery-77", "Tr0ub4dor&3"]))
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self) + SecurityReportRenderer.text(record)
        XCTAssertFalse(json.contains("Correct-Horse-Battery-77"))
        XCTAssertFalse(json.contains("Tr0ub4dor&3"))
        XCTAssertTrue(json.contains("24 characters"))
    }
}
