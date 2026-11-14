import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the service is expected to do. For the bundled lab these come from its configuration; the user can edit
/// them to see how a mismatch is reported.
public struct AuthDefenseExpectations: Codable, Equatable {
    /// Lockout expected once this many consecutive failures have happened.
    public var lockoutAfter: Int?
    /// HTTP 429 expected once this many attempts have been made within the window.
    public var throttleAfter: Int?
    public var genericErrors: Bool
    public var eventsLogged: Bool

    public init(lockoutAfter: Int?, throttleAfter: Int?, genericErrors: Bool, eventsLogged: Bool) {
        self.lockoutAfter = lockoutAfter
        self.throttleAfter = throttleAfter
        self.genericErrors = genericErrors
        self.eventsLogged = eventsLogged
    }

    public init(lab configuration: AuthLabConfiguration) {
        let config = configuration.normalized
        self.init(lockoutAfter: config.lockoutEnabled ? config.lockoutThreshold : nil,
                  throttleAfter: config.rateLimitEnabled ? config.rateLimitAttempts : nil,
                  genericErrors: config.errorMode == .generic, eventsLogged: config.loggingEnabled)
    }
}

public struct AuthDefensePlan: Equatable {
    public static let maxAttemptCap = 10
    public static let maxPasswords = 10
    public static let minimumInterval: TimeInterval = 1.0

    public var target: AuthLabTarget
    public var account: String
    /// Incorrect passwords chosen by the user. Used in order, repeated if shorter than the cap. Never stored.
    public var wrongPasswords: [String]
    /// Total login requests, including the one for a non-existent account.
    public var attemptCap: Int
    public var interval: TimeInterval
    public var requestTimeout: TimeInterval
    public var expectations: AuthDefenseExpectations

    /// Upper bound for the whole run: every attempt at its pace and timeout, plus reading the event log.
    public var overallTimeout: TimeInterval { Double(attemptCap) * (interval + requestTimeout) + 30 }

    public init(target: AuthLabTarget, account: String, wrongPasswords: [String], attemptCap: Int = 6,
                interval: TimeInterval = 1.5, requestTimeout: TimeInterval = 5, expectations: AuthDefenseExpectations) {
        self.target = target
        self.account = account
        self.wrongPasswords = wrongPasswords
        self.attemptCap = attemptCap
        self.interval = interval
        self.requestTimeout = requestTimeout
        self.expectations = expectations
    }
}

public enum AuthPlanError: Error, Equatable, CustomStringConvertible {
    case notTheBundledLab
    case accountNotDesignated(String)
    case noPasswords
    case tooManyPasswords
    case passwordTooLong
    case capOutOfRange
    case intervalTooShort

    public var description: String {
        switch self {
        case .notTheBundledLab: return "The target is not Sentinel's bundled lab. This module only tests the bundled lab."
        case .accountNotDesignated(let account): return "\(account) is not a designated test account of the lab."
        case .noPasswords: return "Enter at least one incorrect password."
        case .tooManyPasswords: return "Enter at most \(AuthDefensePlan.maxPasswords) passwords."
        case .passwordTooLong: return "Passwords may be at most 64 characters."
        case .capOutOfRange: return "The attempt cap must be between 2 and \(AuthDefensePlan.maxAttemptCap)."
        case .intervalTooShort: return "Wait at least \(Int(AuthDefensePlan.minimumInterval)) second between attempts."
        }
    }
}

/// Blocking HTTP for the lab. Tests can substitute an in-process transport.
public protocol AuthLabTransport: AnyObject {
    func request(_ method: String, url: URL, headers: [String: String], body: [UInt8], timeout: TimeInterval,
                 control: AssessmentControl) -> HTTPProbeResult
}

public final class FoundationAuthLabTransport: NSObject, AuthLabTransport, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public override init() { super.init() }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    public func request(_ method: String, url: URL, headers: [String: String], body: [UInt8], timeout: TimeInterval,
                        control: AssessmentControl) -> HTTPProbeResult {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if !body.isEmpty { request.httpBody = Data(body) }
        let done = DispatchSemaphore(value: 0)
        var result: HTTPProbeResult = .failure(HTTPProbeFailure(kind: .other, code: 0, message: "No response"))
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error as NSError? {
                result = .failure(HTTPProbeFailure.classify(code: error.code, message: error.localizedDescription))
            } else if let http = response as? HTTPURLResponse {
                var fields: [String: String] = [:]
                for (key, value) in http.allHeaderFields { if let name = key as? String { fields[name] = "\(value)" } }
                result = .response(HTTPProbeResponse(status: http.statusCode, headers: fields, bodyPrefix: [UInt8]((data ?? Data()).prefix(16_384))))
            }
            done.signal()
        }
        control.whenCancelled { [weak task] in task?.cancel() }
        task.resume()
        if done.wait(timeout: .now() + timeout + 2) == .timedOut {
            task.cancel()
            return .failure(HTTPProbeFailure(kind: .timeout, code: -1001, message: "The request timed out"))
        }
        return result
    }
}

/// Measures how the bundled lab defends against repeated wrong passwords and compares it with expectations.
/// No credential stuffing, no distributed or parallel guessing, no proxy rotation, no retries after throttling.
public final class AuthDefenseAssessment {
    public static let limitations = [
        "Runs only against Sentinel's bundled lab on this device, with its synthetic accounts.",
        "Only incorrect passwords you entered are sent, one at a time, at a fixed low rate, up to the hard cap. The test stops at the first lockout, throttling response or server error and never retries.",
        "A single source and a single account are tested. Defences based on IP reputation, device fingerprinting, CAPTCHA or MFA are outside this test.",
        "Event logging is checked through the lab's own event log; a real service's logging pipeline would need its own verification."
    ]

    private let transport: AuthLabTransport
    private let minimumInterval: TimeInterval
    private let now: () -> Date

    public convenience init(transport: AuthLabTransport = FoundationAuthLabTransport()) {
        self.init(transport: transport, minimumInterval: AuthDefensePlan.minimumInterval, now: Date.init)
    }

    /// Tests may lower the pacing floor; the app always uses the public initialiser.
    init(transport: AuthLabTransport, minimumInterval: TimeInterval, now: @escaping () -> Date) {
        self.transport = transport
        self.minimumInterval = minimumInterval
        self.now = now
    }

    public func validate(_ plan: AuthDefensePlan) throws {
        guard plan.target.baseURL.scheme == "http", let host = plan.target.baseURL.host,
              AddressClassifier.classify(host) == .loopback else { throw AuthPlanError.notTheBundledLab }
        guard AuthLabService.designatedTestAccounts.contains(plan.account) else { throw AuthPlanError.accountNotDesignated(plan.account) }
        let passwords = plan.wrongPasswords.filter { !$0.isEmpty }
        guard !passwords.isEmpty else { throw AuthPlanError.noPasswords }
        guard passwords.count <= AuthDefensePlan.maxPasswords else { throw AuthPlanError.tooManyPasswords }
        guard passwords.allSatisfy({ $0.count <= 64 }) else { throw AuthPlanError.passwordTooLong }
        guard (2...AuthDefensePlan.maxAttemptCap).contains(plan.attemptCap) else { throw AuthPlanError.capOutOfRange }
        guard plan.interval >= minimumInterval else { throw AuthPlanError.intervalTooShort }
    }

    private struct Attempt {
        let index: Int
        let account: String
        let label: String
        let status: Int?
        let message: String
        let retryAfter: String?
        let milliseconds: Int

        var line: String {
            let outcome = status.map { "HTTP \($0)" } ?? "no response"
            return "Attempt \(index) (\(label)): \(outcome) “\(message)”" + (retryAfter.map { ", Retry-After \($0) s" } ?? "") + " — \(milliseconds) ms"
        }
    }

    private enum StopReason: Equatable {
        case capReached, lockout(Int), throttled(Int), serverError(Int), unexpectedSuccess(Int), transport(String)
    }

    public func run(_ plan: AuthDefensePlan, control: AssessmentControl, progress: (AssessmentProgress) -> Void = { _ in }) -> SecurityAssessmentRecord {
        let passwords = plan.wrongPasswords.filter { !$0.isEmpty }
        var record = SecurityAssessmentRecord(
            module: .authDefenseLab,
            scope: [ScopeItem(kind: .url, value: plan.target.baseURL.absoluteString + " (bundled lab)", localNetwork: true),
                    ScopeItem(kind: .testAccount, value: "\(plan.account) (synthetic)")],
            location: .thisDevice,
            permissions: ["Bundled Authentication Defense Lab on this device only",
                          "\(passwords.count) incorrect password(s) you entered for the designated synthetic test account",
                          "One request for a non-existent synthetic account, to compare error messages",
                          "Read the lab's authentication event log"],
            startedAt: now(),
            limits: AssessmentLimits(maxAttempts: plan.attemptCap, minRequestInterval: plan.interval, requestTimeout: plan.requestTimeout,
                                     overallTimeout: plan.overallTimeout),
            limitations: AuthDefenseAssessment.limitations)
        record.workTotal = plan.attemptCap + 1

        do {
            try validate(plan)
        } catch {
            record.status = .unsupported
            record.errors.append("\(error)")
            record.notTested.append("Nothing was sent: \(error)")
            record.endedAt = now()
            return record
        }

        // Confirm this really is the bundled lab instance before sending any password.
        let info = transport.request("GET", url: plan.target.baseURL.appendingPathComponent("lab/info"), headers: [:], body: [],
                                     timeout: plan.requestTimeout, control: control)
        guard case .response(let infoResponse) = info, infoResponse.status == 200,
              let infoObject = try? JSONSerialization.jsonObject(with: Data(infoResponse.bodyPrefix)) as? [String: Any],
              infoObject["instance"] as? String == plan.target.instanceID else {
            record.status = control.isCancelled ? .cancelled : .failedToExecute
            record.errors.append("The bundled lab did not answer with the expected identity, so no login attempt was sent.")
            record.notTested.append("All checks: the lab could not be confirmed")
            record.endedAt = now()
            return record
        }

        var attempts: [Attempt] = []
        var stopReason: StopReason = .capReached
        var stop: AssessmentControl.Stop?
        let unknownAccount = "lab-nonexistent-\(SecureRandom.bytes(4).map { String(format: "%02x", $0) }.joined())"
        let windowStart = now()

        for index in 1...plan.attemptCap {
            let isProbe = index == 1
            let account = isProbe ? unknownAccount : plan.account
            let password = isProbe ? passwords[0] : passwords[(index - 2) % passwords.count]
            let label = isProbe ? "non-existent account" : "\(plan.account), password #\(((index - 2) % passwords.count) + 1) of \(passwords.count), \(password.count) characters"
            do {
                if index > 1 {
                    guard control.pause(plan.interval) else { throw AssessmentControl.Stop.cancelled }
                }
                try control.check()
            } catch let error as AssessmentControl.Stop {
                stop = error
                break
            } catch {
                break
            }
            progress(AssessmentProgress(completed: index - 1, total: record.workTotal, current: "Attempt \(index) of \(plan.attemptCap)"))
            let body = (try? JSONSerialization.data(withJSONObject: ["username": account, "password": password])) ?? Data()
            let started = Date()
            let result = transport.request("POST", url: plan.target.baseURL.appendingPathComponent("login"),
                                           headers: ["Content-Type": "application/json"], body: [UInt8](body),
                                           timeout: plan.requestTimeout, control: control)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            record.workCompleted = index
            if control.isCancelled { stop = .cancelled; break }
            switch result {
            case .failure(let failure):
                stopReason = .transport(failure.message)
                attempts.append(Attempt(index: index, account: account, label: label, status: nil, message: failure.message, retryAfter: nil, milliseconds: elapsed))
            case .response(let response):
                let object = try? JSONSerialization.jsonObject(with: Data(response.bodyPrefix)) as? [String: Any]
                let message = Redactor.standard.text((object?["error"] as? String) ?? (object?["result"] as? String) ?? "")
                attempts.append(Attempt(index: index, account: account, label: label, status: response.status, message: message,
                                        retryAfter: response.header("retry-after"), milliseconds: elapsed))
                switch response.status {
                case 423: stopReason = .lockout(index)
                case 429: stopReason = .throttled(index)
                case 500...599: stopReason = .serverError(index)
                case 200...299: stopReason = .unexpectedSuccess(index)
                default: continue
                }
            }
            break
        }
        let events = fetchEvents(plan, control: control, since: windowStart)
        evaluate(plan, attempts: attempts, stopReason: stopReason, events: events, unknownAccount: unknownAccount, record: &record)
        if case .serverError(let index) = stopReason { record.errors.append("The lab returned a server error at attempt \(index); the test stopped.") }
        if case .transport(let message) = stopReason { record.errors.append("The lab stopped answering: \(message)") }
        if case .unexpectedSuccess(let index) = stopReason {
            record.errors.append("Attempt \(index) was accepted as a correct password. The test only sends incorrect passwords, so it stopped; choose different passwords.")
        }
        if let stop = stop {
            record.status = AssessmentRunStatus(stop: stop)
            record.notTested.append("Attempts after \(attempts.count) were not sent because the assessment was \(stop == .cancelled ? "cancelled" : "stopped at its time limit")")
        } else if case .transport = stopReason, attempts.count <= 1 {
            record.status = .failedToExecute
        } else {
            record.status = .completed
        }
        record.endedAt = now()
        progress(AssessmentProgress(completed: record.workCompleted, total: record.workTotal, current: record.status.label))
        return record
    }

    private func fetchEvents(_ plan: AuthDefensePlan, control: AssessmentControl, since: Date) -> [AuthLabEvent]? {
        let result = transport.request("GET", url: plan.target.baseURL.appendingPathComponent("lab/events"),
                                       headers: ["X-Lab-Token": plan.target.adminToken], body: [], timeout: plan.requestTimeout,
                                       control: AssessmentControl(timeout: plan.requestTimeout + 1))
        guard case .response(let response) = result, response.status == 200,
              let object = try? JSONSerialization.jsonObject(with: Data(response.bodyPrefix)) as? [String: Any],
              let list = object["events"] as? [[String: String]] else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return list.compactMap { item in
            guard let time = item["time"].flatMap(formatter.date(from:)), let account = item["account"],
                  let outcome = item["outcome"].flatMap(AuthLabEvent.Outcome.init(rawValue:)), time >= since.addingTimeInterval(-1) else { return nil }
            return AuthLabEvent(time: time, account: account, outcome: outcome)
        }
    }

    // MARK: Expected versus observed

    private func evaluate(_ plan: AuthDefensePlan, attempts: [Attempt], stopReason: StopReason, events: [AuthLabEvent]?,
                          unknownAccount: String, record: inout SecurityAssessmentRecord) {
        let evidence = attempts.map { $0.line }
        let location = "\(plan.target.baseURL.absoluteString)/login · \(plan.account)"
        let accountAttempts = attempts.filter { $0.account == plan.account }
        let failuresBeforeStop = accountAttempts.filter { $0.status == 401 }.count
        let expected = plan.expectations
        func add(_ id: String, _ title: String, _ outcome: CheckOutcome, _ detail: String) {
            record.checks.append(CheckResult(id: id, title: title, target: plan.account, outcome: outcome, detail: detail))
        }
        let stoppedByError: Bool
        switch stopReason {
        case .serverError, .transport, .unexpectedSuccess: stoppedByError = true
        default: stoppedByError = false
        }

        // Lockout.
        let lockoutTitle = "Temporary lockout"
        let expectedLockout = expected.lockoutAfter.map { "Expected: lockout after \($0) failures." } ?? "Expected: no lockout configured."
        if case .lockout(let index) = stopReason {
            let observedAfter = accountAttempts.filter { $0.index < index && $0.status == 401 }.count
            if let want = expected.lockoutAfter, want != observedAfter {
                add("lockout", lockoutTitle, .finding, "\(expectedLockout) Observed: locked after \(observedAfter) failures.")
                record.findings.append(SecurityFinding(
                    id: "lockout-mismatch", checkID: "lockout", title: "Lockout threshold differs from what was expected",
                    severity: observedAfter > want ? .medium : .low, confidence: .high, basis: .verified, location: location,
                    evidence: evidence, explanation: "The account locked after \(observedAfter) failures, not \(want).",
                    remediation: "Check the lockout configuration matches your policy."))
            } else {
                add("lockout", lockoutTitle, .passed, "\(expectedLockout) Observed: HTTP 423 at attempt \(index), after \(observedAfter) failures.")
            }
        } else if stoppedByError {
            add("lockout", lockoutTitle, .inconclusive, "\(expectedLockout) The test stopped early (see errors), so lockout could not be measured.")
        } else if case .throttled = stopReason {
            add("lockout", lockoutTitle, .inconclusive, "\(expectedLockout) Throttling stopped the test after \(failuresBeforeStop) failures, before lockout could be judged. Turn rate limiting off in the lab to measure lockout.")
        } else if let want = expected.lockoutAfter, failuresBeforeStop <= want {
            add("lockout", lockoutTitle, .inconclusive, "\(expectedLockout) Only \(failuresBeforeStop) failures fit within the cap, so the threshold could not be crossed. Raise the cap to verify it.")
        } else if failuresBeforeStop < 3 {
            add("lockout", lockoutTitle, .inconclusive, "\(expectedLockout) Only \(failuresBeforeStop) failures were sent; too few to judge.")
        } else {
            let mismatch = expected.lockoutAfter != nil
            add("lockout", lockoutTitle, .finding, "\(expectedLockout) Observed: no lockout after \(failuresBeforeStop) consecutive failures.")
            record.findings.append(SecurityFinding(
                id: "lockout-missing", checkID: "lockout", title: mismatch ? "Expected lockout did not happen" : "No account lockout",
                severity: .high, confidence: .high, basis: .verified, location: location, evidence: evidence,
                explanation: "The account kept accepting password attempts after \(failuresBeforeStop) consecutive failures." +
                    (mismatch ? " This contradicts the expected configuration." : " This matches the lab's settings (lockout off), which is a deliberate weakness."),
                remediation: "Lock or progressively delay an account after a small number of consecutive failures, and alert on it."))
        }

        // Throttling.
        let throttleTitle = "Rate limiting"
        let expectedThrottle = expected.throttleAfter.map { "Expected: HTTP 429 after \($0) attempts per account." } ?? "Expected: no rate limit configured."
        if case .throttled(let index) = stopReason {
            let before = accountAttempts.filter { $0.index < index }.count
            let retry = attempts.last?.retryAfter.map { " with Retry-After \($0) s" } ?? " without Retry-After"
            if let want = expected.throttleAfter, want != before {
                add("throttle", throttleTitle, .finding, "\(expectedThrottle) Observed: throttled after \(before) attempts\(retry).")
                record.findings.append(SecurityFinding(
                    id: "throttle-mismatch", checkID: "throttle", title: "Rate limit differs from what was expected",
                    severity: before > want ? .medium : .low, confidence: .high, basis: .verified, location: location,
                    evidence: evidence, explanation: "Throttling started after \(before) attempts, not \(want).",
                    remediation: "Check the rate-limit configuration matches your policy."))
            } else {
                add("throttle", throttleTitle, .passed, "\(expectedThrottle) Observed: HTTP 429 at attempt \(index)\(retry). The test did not retry.")
            }
        } else if case .lockout = stopReason {
            add("throttle", throttleTitle, .inconclusive, "\(expectedThrottle) The account locked first, so throttling could not be measured. Turn lockout off in the lab to measure it.")
        } else if stoppedByError {
            add("throttle", throttleTitle, .inconclusive, "\(expectedThrottle) The test stopped early (see errors).")
        } else if let want = expected.throttleAfter, accountAttempts.count <= want {
            add("throttle", throttleTitle, .inconclusive, "\(expectedThrottle) Only \(accountAttempts.count) attempts fit within the cap. Raise the cap to verify it.")
        } else if accountAttempts.count < 3 {
            add("throttle", throttleTitle, .inconclusive, "\(expectedThrottle) Too few attempts to judge.")
        } else {
            add("throttle", throttleTitle, .finding, "\(expectedThrottle) Observed: no throttling after \(accountAttempts.count) attempts.")
            record.findings.append(SecurityFinding(
                id: "throttle-missing", checkID: "throttle", title: expected.throttleAfter == nil ? "No rate limiting" : "Expected rate limit did not apply",
                severity: .medium, confidence: .high, basis: .verified, location: location, evidence: evidence,
                explanation: "Every attempt was processed at the test's pace. Without throttling, automated guessing is only limited by lockout.",
                remediation: "Limit login attempts per account and per source, and return HTTP 429 with Retry-After."))
        }

        // Error messages.
        let errorTitle = "Generic login errors"
        let expectedErrors = expected.genericErrors ? "Expected: identical errors for unknown accounts and wrong passwords." : "Expected: revealing errors (lab setting)."
        if let probe = attempts.first(where: { $0.account == unknownAccount }), let wrong = accountAttempts.first(where: { $0.status == 401 || $0.status == 404 }),
           let probeStatus = probe.status, let wrongStatus = wrong.status {
            if probeStatus == wrongStatus && probe.message == wrong.message {
                add("errors", errorTitle, .passed, "\(expectedErrors) Observed: both answered HTTP \(probeStatus) “\(probe.message)”.")
            } else {
                add("errors", errorTitle, .finding, "\(expectedErrors) Observed: HTTP \(probeStatus) “\(probe.message)” for an unknown account, HTTP \(wrongStatus) “\(wrong.message)” for a wrong password.")
                record.findings.append(SecurityFinding(
                    id: "errors-revealing", checkID: "errors", title: "Login errors reveal whether an account exists",
                    severity: .medium, confidence: .high, basis: .verified, location: location, evidence: [probe.line, wrong.line],
                    explanation: "Different answers let anyone check which usernames exist, which makes targeted guessing and phishing easier." +
                        (expected.genericErrors ? " This contradicts the expected configuration." : " This matches the lab's settings (revealing errors)."),
                    remediation: "Return the same status code and message for unknown accounts and wrong passwords."))
            }
        } else {
            add("errors", errorTitle, .inconclusive, "\(expectedErrors) The test did not get a wrong-password and an unknown-account answer to compare.")
        }

        // Event logging.
        let loggingTitle = "Authentication event logging"
        let expectedLogging = expected.eventsLogged ? "Expected: every attempt recorded." : "Expected: logging off (lab setting)."
        let sentAttempts = attempts.filter { $0.status != nil }
        if let events = events {
            let recorded = events.filter { $0.account == plan.account || $0.account == unknownAccount }.count
            if recorded >= sentAttempts.count && !sentAttempts.isEmpty {
                add("logging", loggingTitle, .passed, "\(expectedLogging) Observed: \(recorded) event(s) recorded for \(sentAttempts.count) attempt(s).")
            } else if sentAttempts.isEmpty {
                add("logging", loggingTitle, .inconclusive, "\(expectedLogging) No attempts were answered.")
            } else {
                add("logging", loggingTitle, .finding, "\(expectedLogging) Observed: \(recorded) event(s) recorded for \(sentAttempts.count) attempt(s).")
                record.findings.append(SecurityFinding(
                    id: "logging-missing", checkID: "logging", title: recorded == 0 ? "Failed logins were not recorded" : "Some failed logins were not recorded",
                    severity: .medium, confidence: .high, basis: .verified, location: "\(plan.target.baseURL.absoluteString)/lab/events",
                    evidence: ["\(sentAttempts.count) attempt(s) answered, \(recorded) event(s) in the lab's log for the tested accounts"],
                    explanation: "Without a record of failed logins, guessing attacks go unnoticed and cannot be investigated." +
                        (expected.eventsLogged ? " This contradicts the expected configuration." : " This matches the lab's settings (logging off)."),
                    remediation: "Record every authentication attempt with time, account and outcome, and alert on bursts of failures."))
            }
        } else {
            add("logging", loggingTitle, .inconclusive, "\(expectedLogging) The lab's event log could not be read.")
        }
    }
}
