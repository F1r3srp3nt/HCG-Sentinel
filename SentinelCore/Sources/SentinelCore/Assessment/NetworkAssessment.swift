import Foundation

// MARK: - Facts gathered by a probe

/// The current network path as reported by the operating system.
public struct ConnectionFacts: Equatable {
    public var isOnline: Bool
    public var statusDescription: String
    /// "Wi-Fi", "Cellular", "Wired", "Other".
    public var interfaceTypes: [String]
    public var isExpensive: Bool
    public var isConstrained: Bool
    public var supportsIPv4: Bool
    public var supportsIPv6: Bool
    public var supportsDNS: Bool
    /// Gateway addresses the system reports for this path. Empty when none are reported.
    public var gateways: [String]

    public init(isOnline: Bool, statusDescription: String, interfaceTypes: [String], isExpensive: Bool = false,
                isConstrained: Bool = false, supportsIPv4: Bool = true, supportsIPv6: Bool = false, supportsDNS: Bool = true,
                gateways: [String] = []) {
        self.isOnline = isOnline
        self.statusDescription = statusDescription
        self.interfaceTypes = interfaceTypes
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.supportsDNS = supportsDNS
        self.gateways = gateways
    }

    public var usesWiFi: Bool { interfaceTypes.contains("Wi-Fi") }
}

public enum WiFiSecurity: String, Equatable {
    case open, wep, personal, enterprise, unknown
}

/// Identity of the joined Wi-Fi network. Every field is optional because the system only provides it under specific
/// conditions; `unavailableReason` says why it is missing.
public struct WiFiFacts: Equatable {
    public var ssid: String?
    public var bssid: String?
    public var security: WiFiSecurity?
    public var unavailableReason: String?

    public init(ssid: String? = nil, bssid: String? = nil, security: WiFiSecurity? = nil, unavailableReason: String? = nil) {
        self.ssid = ssid
        self.bssid = bssid
        self.security = security
        self.unavailableReason = unavailableReason
    }
}

public struct ProxyFacts: Equatable {
    public var httpProxy: String?
    public var httpsProxy: String?
    public var pacURL: String?
    public var autoDiscovery: Bool
    /// Interface names the system lists for scoped (tunnel) routing, e.g. "utun3", "ipsec0".
    public var tunnelInterfaces: [String]
    public var unavailableReason: String?

    public init(httpProxy: String? = nil, httpsProxy: String? = nil, pacURL: String? = nil, autoDiscovery: Bool = false,
                tunnelInterfaces: [String] = [], unavailableReason: String? = nil) {
        self.httpProxy = httpProxy
        self.httpsProxy = httpsProxy
        self.pacURL = pacURL
        self.autoDiscovery = autoDiscovery
        self.tunnelInterfaces = tunnelInterfaces
        self.unavailableReason = unavailableReason
    }

    public var hasProxy: Bool { httpProxy != nil || httpsProxy != nil || pacURL != nil || autoDiscovery }
}

public enum ResolveOutcome: Equatable {
    case addresses([String])
    /// The resolver answered that the name does not exist.
    case notFound
    case failed(String)
    case timedOut
}

public enum FetchOutcome: Equatable {
    /// An HTTP response arrived (for HTTPS: over a connection the system trusted). Redirects are not followed.
    case response(status: Int, location: String?, bodyPrefix: String, certificates: [String])
    /// The TLS certificate was presented but not trusted by the system.
    case trustFailure(code: Int, message: String, certificates: [String])
    /// The TLS handshake failed for another reason.
    case tlsFailure(code: Int, message: String)
    case connectivityFailure(code: Int, message: String)
    case timedOut
}

/// Maps URL-loading error codes (NSURLError values) to fetch outcomes. Codes are listed numerically so the
/// mapping is identical on every platform.
public enum FetchErrorClassifier {
    public static let trustCodes: Set<Int> = [-1201, -1202, -1203, -1204]   // bad date, untrusted, unknown root, not yet valid
    public static let tlsCodes: Set<Int> = [-1200, -1205, -1206]            // secure connection failed, client cert rejected/required

    public static func classify(code: Int, message: String, certificates: [String] = []) -> FetchOutcome {
        if code == -1001 { return .timedOut }
        if trustCodes.contains(code) { return .trustFailure(code: code, message: message, certificates: certificates) }
        if tlsCodes.contains(code) { return .tlsFailure(code: code, message: message) }
        return .connectivityFailure(code: code, message: message)
    }
}

public protocol AssessmentCancellable: AnyObject {
    func cancel()
}

/// Supplies real information about the current connection. Every completion must be delivered on the main queue.
/// The engine enforces its own time limits, so a probe that never completes cannot stall an assessment.
public protocol NetworkAssessmentProbe: AnyObject {
    func connectionFacts(completion: @escaping (ConnectionFacts?) -> Void)
    func wifiFacts(completion: @escaping (WiFiFacts) -> Void)
    func proxyFacts(completion: @escaping (ProxyFacts) -> Void)
    func resolve(host: String, timeout: TimeInterval, completion: @escaping (ResolveOutcome) -> Void) -> AssessmentCancellable?
    func fetch(url: URL, timeout: TimeInterval, completion: @escaping (FetchOutcome) -> Void) -> AssessmentCancellable?
}

public protocol AssessmentScheduler: AnyObject {
    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void)
}

public final class MainQueueScheduler: AssessmentScheduler {
    public init() {}
    public func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }
}

// MARK: - Steps and endpoints

public enum AssessmentStep: String, CaseIterable, Equatable {
    case connection, wifiDetails, proxy, dnsResolution, dnsIntegrity, captivePortal, httpsExample, httpsApple

    public var title: String {
        switch self {
        case .connection: return "Connection"
        case .wifiDetails: return "Wi-Fi network details"
        case .proxy: return "Proxy and VPN settings"
        case .dnsResolution: return "DNS resolution"
        case .dnsIntegrity: return "DNS answers for non-existent names"
        case .captivePortal: return "Captive portal / HTTP interception"
        case .httpsExample: return "HTTPS to example.com"
        case .httpsApple: return "HTTPS to www.apple.com"
        }
    }

    /// Whether the step sends anything over the network.
    public var usesNetwork: Bool {
        switch self {
        case .connection, .wifiDetails, .proxy: return false
        default: return true
        }
    }

    public var timeout: TimeInterval {
        switch self {
        case .connection, .wifiDetails: return 5
        case .proxy: return 3
        case .dnsResolution, .dnsIntegrity: return 5
        case .captivePortal, .httpsExample, .httpsApple: return 10
        }
    }
}

/// Public endpoints the check contacts, chosen because their expected behaviour is documented.
public enum AssessmentEndpoints {
    /// RFC 2606 / IANA documentation domain: resolves, and serves HTTPS.
    public static let dnsControlHost = "example.com"
    /// A random label under example.com, which has no wildcard records, so a correct resolver answers "does not exist".
    public static func nonexistentHost(label: String) -> String { "\(label).example.com" }
    /// Apple's captive-network detection page. Plain HTTP on purpose: it detects rewriting of unencrypted traffic.
    public static let captivePortalURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    public static let captivePortalExpected = "Success"
    public static let httpsExampleURL = URL(string: "https://example.com/")!
    public static let httpsAppleURL = URL(string: "https://www.apple.com/library/test/success.html")!
}

// MARK: - Results

public struct AssessmentFinding: Identifiable, Equatable {
    public enum Kind: String, Equatable {
        /// Something observed that can expose traffic or credentials.
        case securityConcern
        /// Worth knowing; may or may not be a problem.
        case notice
        /// A check could not complete because of connectivity. Not evidence of an attack.
        case connectivityProblem
        /// The system does not provide this information to the app.
        case unavailable
        /// The check was not run.
        case notChecked
        /// What was observed, with nothing wrong found.
        case observation
    }

    public let id: String
    public let step: AssessmentStep
    public let kind: Kind
    public let title: String
    public let evidence: [String]
    public let observedAt: Date
    public let limitations: String
    public let remediation: String?
}

public struct AssessmentReport: Equatable {
    public let startedAt: Date
    public let finishedAt: Date
    public let findings: [AssessmentFinding]
    public let completedSteps: Int
    public let totalSteps: Int
    public let cancelled: Bool

    public static let disclaimer = "These checks look for specific, observable problems. Finding none does not mean the network is safe: they cannot see other devices on the network, inspect the router, or detect attacks that leave no trace in these tests."

    public func count(_ kind: AssessmentFinding.Kind) -> Int { findings.filter { $0.kind == kind }.count }

    /// Never says "safe": the absence of findings is reported as exactly that.
    public var headline: String {
        let concerns = count(.securityConcern)
        let incomplete = count(.connectivityProblem) + count(.notChecked)
        if cancelled { return "Check cancelled after \(completedSteps) of \(totalSteps) steps — results are incomplete" }
        if concerns > 0 { return "\(concerns) potential security concern\(concerns == 1 ? "" : "s") found" }
        if incomplete > 0 { return "No security concerns found in the checks that completed; \(incomplete) could not complete" }
        return "No security concerns found by these checks"
    }

    public var disclaimer: String { AssessmentReport.disclaimer }
}

// MARK: - Engine

/// Runs the network checks in order. Start and cancel are explicit; nothing runs on its own.
/// Every step is bounded by its own time limit. Confine to the main queue.
public final class NetworkAssessment {
    public enum State: Equatable {
        case idle
        case running(step: AssessmentStep, completed: Int, total: Int)
        case finished(AssessmentReport)

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    public private(set) var state: State = .idle {
        didSet { onChange?() }
    }
    public var onChange: (() -> Void)?

    private let probe: NetworkAssessmentProbe
    private let scheduler: AssessmentScheduler
    private let now: () -> Date
    private let randomLabel: () -> String
    private var generation = 0
    private var stepIndex = 0
    private var currentTask: AssessmentCancellable?
    private var observations = AssessmentObservations()
    private var startedAt = Date()

    public init(probe: NetworkAssessmentProbe, scheduler: AssessmentScheduler = MainQueueScheduler(),
                now: @escaping () -> Date = Date.init,
                randomLabel: @escaping () -> String = { "sentinel-check-" + Hex.string(SecureRandom.bytes(8)) }) {
        self.probe = probe
        self.scheduler = scheduler
        self.now = now
        self.randomLabel = randomLabel
    }

    public var isRunning: Bool { state.isRunning }

    public func start() {
        guard !isRunning else { return }
        generation += 1
        stepIndex = 0
        observations = AssessmentObservations()
        startedAt = now()
        runCurrentStep()
    }

    /// Stops the assessment, cancels any request in flight and reports what was found so far.
    public func cancel() {
        guard isRunning else { return }
        generation += 1
        currentTask?.cancel()
        currentTask = nil
        finish(cancelled: true)
    }

    private var steps: [AssessmentStep] { AssessmentStep.allCases }

    private func runCurrentStep() {
        guard stepIndex < steps.count else { return finish(cancelled: false) }
        let step = steps[stepIndex]
        if step.usesNetwork, observations.connection?.isOnline != true {
            observations.skipped[step] = observations.connection == nil
                ? "The connection state could not be determined."
                : "There is no network connection."
            return advance()
        }
        state = .running(step: step, completed: stepIndex, total: steps.count)
        let token = generation
        var done = false
        // Every completion and the watchdog funnel through this, so a step finishes exactly once.
        let complete: (@escaping () -> Void) -> Void = { [weak self] record in
            guard let self = self, self.generation == token, !done else { return }
            done = true
            record()
            self.currentTask = nil
            self.observations.completedAt[step] = self.now()
            self.advance()
        }
        scheduler.schedule(after: step.timeout + 1) { [weak self] in
            complete {
                self?.currentTask?.cancel()
                self?.observations.timedOut.insert(step)
            }
        }
        // A probe may complete synchronously; only keep its handle while the step is still running.
        let keep: (AssessmentCancellable?) -> Void = { [weak self] task in
            if !done { self?.currentTask = task }
        }
        switch step {
        case .connection:
            probe.connectionFacts { facts in complete { [weak self] in self?.observations.connection = facts } }
        case .wifiDetails:
            probe.wifiFacts { facts in complete { [weak self] in self?.observations.wifi = facts } }
        case .proxy:
            probe.proxyFacts { facts in complete { [weak self] in self?.observations.proxy = facts } }
        case .dnsResolution:
            keep(probe.resolve(host: AssessmentEndpoints.dnsControlHost, timeout: step.timeout) { outcome in
                complete { [weak self] in self?.observations.dnsControl = outcome }
            })
        case .dnsIntegrity:
            let host = AssessmentEndpoints.nonexistentHost(label: randomLabel())
            observations.nonexistentHost = host
            keep(probe.resolve(host: host, timeout: step.timeout) { outcome in
                complete { [weak self] in self?.observations.dnsNonexistent = outcome }
            })
        case .captivePortal:
            keep(probe.fetch(url: AssessmentEndpoints.captivePortalURL, timeout: step.timeout) { outcome in
                complete { [weak self] in self?.observations.captive = outcome }
            })
        case .httpsExample:
            keep(probe.fetch(url: AssessmentEndpoints.httpsExampleURL, timeout: step.timeout) { outcome in
                complete { [weak self] in self?.observations.httpsExample = outcome }
            })
        case .httpsApple:
            keep(probe.fetch(url: AssessmentEndpoints.httpsAppleURL, timeout: step.timeout) { outcome in
                complete { [weak self] in self?.observations.httpsApple = outcome }
            })
        }
    }

    private func advance() {
        stepIndex += 1
        runCurrentStep()
    }

    private func finish(cancelled: Bool) {
        if cancelled {
            for step in steps[min(stepIndex, steps.count)...] where observations.skipped[step] == nil {
                observations.skipped[step] = "The check was cancelled before this step ran."
            }
        }
        let finishedAt = now()
        let findings = AssessmentAnalyzer.findings(from: observations, defaultTime: finishedAt)
        state = .finished(AssessmentReport(startedAt: startedAt, finishedAt: finishedAt, findings: findings,
                                           completedSteps: min(stepIndex, steps.count), totalSteps: steps.count,
                                           cancelled: cancelled))
    }
}

/// Everything recorded during one run. Missing values mean the step did not produce a result.
public struct AssessmentObservations: Equatable {
    public var connection: ConnectionFacts?
    public var wifi: WiFiFacts?
    public var proxy: ProxyFacts?
    public var dnsControl: ResolveOutcome?
    public var nonexistentHost: String?
    public var dnsNonexistent: ResolveOutcome?
    public var captive: FetchOutcome?
    public var httpsExample: FetchOutcome?
    public var httpsApple: FetchOutcome?
    public var timedOut: Set<AssessmentStep> = []
    public var skipped: [AssessmentStep: String] = [:]
    public var completedAt: [AssessmentStep: Date] = [:]

    public init() {}
}
