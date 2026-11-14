import Foundation

/// Settings of the bundled Authentication Defense Lab. Every account in the lab is synthetic.
public struct AuthLabConfiguration: Codable, Equatable {
    public enum ErrorMode: String, Codable, CaseIterable {
        /// The same message whether the account exists or not.
        case generic
        /// Different messages for unknown accounts and wrong passwords (a deliberate weakness).
        case revealing
    }

    public var rateLimitEnabled = true
    /// Attempts allowed per account within the window before HTTP 429.
    public var rateLimitAttempts = 5
    public var rateLimitWindow: TimeInterval = 60
    public var lockoutEnabled = true
    /// Consecutive failures that lock the account.
    public var lockoutThreshold = 3
    public var lockoutDuration: TimeInterval = 300
    public var errorMode: ErrorMode = .generic
    public var loggingEnabled = true

    public init() {}

    /// Clamps values to sensible lab ranges.
    public var normalized: AuthLabConfiguration {
        var copy = self
        copy.rateLimitAttempts = min(max(copy.rateLimitAttempts, 1), 20)
        copy.rateLimitWindow = min(max(copy.rateLimitWindow, 5), 3600)
        copy.lockoutThreshold = min(max(copy.lockoutThreshold, 1), 20)
        copy.lockoutDuration = min(max(copy.lockoutDuration, 5), 3600)
        return copy
    }

    public var summary: [String] {
        [
            rateLimitEnabled ? "Rate limit: \(rateLimitAttempts) attempts per \(Int(rateLimitWindow)) s per account" : "Rate limit: off",
            lockoutEnabled ? "Lockout: after \(lockoutThreshold) consecutive failures, for \(Int(lockoutDuration)) s" : "Lockout: off",
            errorMode == .generic ? "Errors: generic" : "Errors: revealing (deliberately weak)",
            loggingEnabled ? "Event logging: on" : "Event logging: off"
        ]
    }
}

public struct AuthLabEvent: Codable, Equatable {
    public enum Outcome: String, Codable {
        case success, wrongPassword, unknownAccount, rateLimited, lockedOut
    }

    public var time: Date
    public var account: String
    public var outcome: Outcome
}

public struct LabHTTPRequest: Equatable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: [UInt8]

    public init(method: String, path: String, headers: [String: String] = [:], body: [UInt8] = []) {
        self.method = method
        self.path = path
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.body = body
    }
}

public struct LabHTTPResponse: Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: [UInt8]

    public static func json(_ status: Int, _ object: [String: Any], headers: [String: String] = [:]) -> LabHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        var all = headers
        all["Content-Type"] = "application/json"
        return LabHTTPResponse(status: status, headers: all, body: [UInt8](data))
    }
}

/// The lab's authentication logic. Thread-safe; the clock is injectable for tests.
public final class AuthLabService {
    public static let serviceName = "HCG Sentinel Authentication Defense Lab"
    /// Only these synthetic accounts may be targeted by an assessment.
    public static let designatedTestAccounts = ["lab-alice"]
    public static let allAccounts = ["lab-alice", "lab-bob"]

    public let instanceID = UUID().uuidString
    /// Required to read the event log; known only to the process that started the lab.
    public let adminToken = SecureRandom.bytes(24).map { String(format: "%02x", $0) }.joined()

    private let lock = NSLock()
    private var configuration: AuthLabConfiguration
    private let now: () -> Date
    /// Random per-lab passwords. They are never shown, logged or returned; the assessment only sends wrong ones.
    private let passwords: [String: String]
    private var attemptTimes: [String: [Date]] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private var lockedUntil: [String: Date] = [:]
    private var log: [AuthLabEvent] = []

    public init(configuration: AuthLabConfiguration = AuthLabConfiguration(), now: @escaping () -> Date = Date.init) {
        self.configuration = configuration.normalized
        self.now = now
        var passwords: [String: String] = [:]
        for account in AuthLabService.allAccounts {
            passwords[account] = SecureRandom.bytes(18).map { String(format: "%02x", $0) }.joined()
        }
        self.passwords = passwords
    }

    public var currentConfiguration: AuthLabConfiguration {
        lock.lock(); defer { lock.unlock() }
        return configuration
    }

    /// Applies new settings and clears counters, lockouts and the event log.
    public func reset(configuration: AuthLabConfiguration) {
        lock.lock(); defer { lock.unlock() }
        self.configuration = configuration.normalized
        attemptTimes = [:]
        consecutiveFailures = [:]
        lockedUntil = [:]
        log = []
    }

    public var events: [AuthLabEvent] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    private func record(_ account: String, _ outcome: AuthLabEvent.Outcome, at time: Date) {
        guard configuration.loggingEnabled else { return }
        log.append(AuthLabEvent(time: time, account: String(account.prefix(64)), outcome: outcome))
        if log.count > 1000 { log.removeFirst(log.count - 1000) }
    }

    public func login(account rawAccount: String, password: String) -> LabHTTPResponse {
        lock.lock(); defer { lock.unlock() }
        let account = String(rawAccount.prefix(64))
        let time = now()
        let generic: [String: Any] = ["error": "Invalid username or password"]

        if configuration.rateLimitEnabled {
            let recent = (attemptTimes[account] ?? []).filter { time.timeIntervalSince($0) < configuration.rateLimitWindow }
            if recent.count >= configuration.rateLimitAttempts {
                attemptTimes[account] = recent
                record(account, .rateLimited, at: time)
                let retry = Int(ceil(configuration.rateLimitWindow - time.timeIntervalSince(recent[0])))
                return .json(429, ["error": "Too many attempts. Try again later."], headers: ["Retry-After": "\(max(1, retry))"])
            }
            attemptTimes[account] = recent + [time]
        }
        if configuration.lockoutEnabled, let until = lockedUntil[account] {
            if until > time {
                record(account, .lockedOut, at: time)
                return .json(423, ["error": "Account temporarily locked"])
            }
            lockedUntil[account] = nil
            consecutiveFailures[account] = 0
        }
        guard let expected = passwords[account] else {
            record(account, .unknownAccount, at: time)
            return configuration.errorMode == .generic ? .json(401, generic) : .json(404, ["error": "No account with that username"])
        }
        let matches = HMACSHA256.constantTimeEquals(Array(expected.utf8), Array(password.utf8))
        if matches {
            consecutiveFailures[account] = 0
            record(account, .success, at: time)
            return .json(200, ["result": "signed in"])
        }
        let failures = (consecutiveFailures[account] ?? 0) + 1
        consecutiveFailures[account] = failures
        record(account, .wrongPassword, at: time)
        if configuration.lockoutEnabled && failures >= configuration.lockoutThreshold {
            lockedUntil[account] = time.addingTimeInterval(configuration.lockoutDuration)
        }
        return configuration.errorMode == .generic ? .json(401, generic) : .json(401, ["error": "Incorrect password"])
    }

    /// HTTP routing for the loopback server.
    ///   POST /login        {"username": "...", "password": "..."}
    ///   GET  /lab/info     service identity, designated test accounts, configuration
    ///   GET  /lab/events   event log (needs X-Lab-Token)
    public func handle(_ request: LabHTTPRequest) -> LabHTTPResponse {
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        switch (request.method, path) {
        case ("POST", "/login"):
            guard let object = try? JSONSerialization.jsonObject(with: Data(request.body)) as? [String: Any],
                  let account = object["username"] as? String, let password = object["password"] as? String else {
                return .json(400, ["error": "Expected JSON with username and password"])
            }
            return login(account: account, password: password)
        case ("GET", "/lab/info"):
            let config = currentConfiguration
            return .json(200, [
                "service": AuthLabService.serviceName,
                "instance": instanceID,
                "designatedTestAccounts": AuthLabService.designatedTestAccounts,
                "configuration": [
                    "rateLimitEnabled": config.rateLimitEnabled, "rateLimitAttempts": config.rateLimitAttempts,
                    "lockoutEnabled": config.lockoutEnabled, "lockoutThreshold": config.lockoutThreshold,
                    "errorMode": config.errorMode.rawValue, "loggingEnabled": config.loggingEnabled
                ]
            ])
        case ("GET", "/lab/events"):
            guard let token = request.headers["x-lab-token"],
                  HMACSHA256.constantTimeEquals(Array(token.utf8), Array(adminToken.utf8)) else {
                return .json(403, ["error": "A valid X-Lab-Token is required"])
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return .json(200, ["events": events.map {
                ["time": formatter.string(from: $0.time), "account": $0.account, "outcome": $0.outcome.rawValue]
            }])
        default:
            return .json(404, ["error": "Not found"])
        }
    }
}
