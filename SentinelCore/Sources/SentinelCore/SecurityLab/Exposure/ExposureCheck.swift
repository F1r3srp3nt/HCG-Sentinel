import Foundation

public struct ExposureCheckConfiguration: Equatable {
    public var requestTimeout: TimeInterval = 10
    public var overallTimeout: TimeInterval = 120
    public var maxRequestsPerTarget = 6
    public var maxRedirects = 3
    public var minRequestInterval: TimeInterval = 0.5
    public var maxBodyBytes = 65_536
    public var expiryWarningDays = 21

    public init() {}

    public func limits(targets: Int) -> AssessmentLimits {
        AssessmentLimits(maxRequests: maxRequestsPerTarget * max(1, targets), minRequestInterval: minRequestInterval,
                         requestTimeout: requestTimeout, overallTimeout: overallTimeout)
    }
}

/// Assesses HTTP/HTTPS services the user entered and is authorised to test. Observations (banners, missing
/// headers) are kept apart from verified behaviour (certificate refused, plain HTTP served). Nothing is
/// exploited, guessed or scanned beyond the entered hosts.
public final class ExposureCheck {
    public static let checkIDs = ["reachability", "tls", "https", "hsts", "headers", "disclosure"]

    public static let limitations = [
        "Only the URLs you entered were contacted, with plain GET requests and no credentials. Other paths, ports and services on the same host were not examined.",
        "Missing headers and version banners are observations. They do not confirm a vulnerability on their own.",
        "Exposure Check does not test for exploitable flaws, guess credentials, or scan for other hosts.",
        "Names are resolved and every address is checked before connecting. The system resolves again when it connects; on Apple platforms the address actually reached is checked afterwards, and responses from anywhere else are discarded.",
        "Results describe what this device could see over its current network path. Other networks may get different answers."
    ]

    private let transport: ExposureTransport
    private let configuration: ExposureCheckConfiguration
    private let now: () -> Date

    public init(transport: ExposureTransport, configuration: ExposureCheckConfiguration = ExposureCheckConfiguration(),
                now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.configuration = configuration
        self.now = now
    }

    // MARK: Run

    private struct Fetch {
        var url: URL
        var result: HTTPProbeResult
        var chain: [String]
        var redirectNote: String?
        var finalURL: URL
    }

    private enum Blocked: Error {
        case scope(ScopeError)
        case budget
    }

    private final class TargetContext {
        let target: ScopedTarget
        var requests = 0
        var resolved: [String: [String]] = [:]
        init(target: ScopedTarget) { self.target = target }
    }

    public func run(scope: TargetScope, control: AssessmentControl, progress: (AssessmentProgress) -> Void = { _ in }) -> SecurityAssessmentRecord {
        var record = SecurityAssessmentRecord(
            module: .exposureCheck,
            scope: scope.targets.map { ScopeItem(kind: .url, value: $0.url.absoluteString, localNetwork: $0.localNetwork) },
            location: .thisDevice,
            permissions: ["You confirmed you own or are authorised to test these targets",
                          "Plain GET requests to the entered hosts only (no credentials, cookies or request bodies)",
                          scope.targets.contains { $0.localNetwork } ? "Local-network addresses allowed for the targets you marked local" : "Public addresses only"],
            startedAt: now(), limits: configuration.limits(targets: scope.targets.count), limitations: ExposureCheck.limitations)
        record.workTotal = scope.targets.count * 3
        var stop: AssessmentControl.Stop?

        for target in scope.targets {
            if stop == nil {
                do {
                    try control.check()
                    progress(AssessmentProgress(completed: record.workCompleted, total: record.workTotal, current: target.host))
                    try assess(target, scope: scope, control: control, record: &record, progress: progress)
                } catch let error as AssessmentControl.Stop {
                    stop = error
                } catch {
                    record.errors.append("\(target.host): \(error)")
                }
            }
            if stop != nil, !record.checks.contains(where: { $0.target == target.url.absoluteString }) {
                record.notTested.append("\(target.url.absoluteString): not reached before the assessment stopped")
            }
        }

        record.endedAt = now()
        if let stop = stop {
            record.status = AssessmentRunStatus(stop: stop)
        } else if !record.checks.isEmpty && record.checks.allSatisfy({ $0.outcome == .unsupported || $0.outcome == .failedToExecute }) {
            record.status = .failedToExecute
        } else {
            record.status = .completed
        }
        progress(AssessmentProgress(completed: record.workCompleted, total: record.workTotal, current: record.status.label))
        return record
    }

    // MARK: Requests within scope

    /// Resolves and validates a host for this target, then sends one request. Throws `Blocked` when scope or the budget forbids it.
    private func send(_ url: URL, context: TargetContext, scope: TargetScope, control: AssessmentControl,
                      record: inout SecurityAssessmentRecord) throws -> HTTPProbeResult {
        guard let inScope = scope.target(for: url) else {
            throw Blocked.scope(.notInScope(url.host ?? url.absoluteString))
        }
        guard context.requests < configuration.maxRequestsPerTarget else { throw Blocked.budget }
        try control.check()
        let host = inScope.host
        let addresses: [String]
        if let cached = context.resolved[host] {
            addresses = cached
        } else {
            switch transport.resolve(host: host, timeout: configuration.requestTimeout, control: control) {
            case .success(let list):
                addresses = list
                context.resolved[host] = list
            case .failure(let failure):
                try control.check()
                return .failure(failure)
            }
        }
        do {
            try scope.validate(resolved: addresses, for: inScope)
        } catch let error as ScopeError {
            throw Blocked.scope(error)
        }
        if context.requests > 0 && configuration.minRequestInterval > 0 {
            control.pause(configuration.minRequestInterval)
            try control.check()
        }
        context.requests += 1
        let result = transport.send(HTTPProbeRequest(url: url, timeout: configuration.requestTimeout, maxBodyBytes: configuration.maxBodyBytes),
                                    control: control)
        try control.check()
        if case .response(let response) = result, let address = response.remoteAddress {
            do {
                try scope.validate(connectedAddress: address, for: inScope)
            } catch let error as ScopeError {
                throw Blocked.scope(error)
            }
        }
        return result
    }

    /// GET with redirects followed only inside the scope.
    private func fetch(_ start: URL, context: TargetContext, scope: TargetScope, control: AssessmentControl,
                       record: inout SecurityAssessmentRecord) throws -> Fetch {
        var url = start
        var chain: [String] = []
        var redirects = 0
        while true {
            let result = try send(url, context: context, scope: scope, control: control, record: &record)
            guard case .response(let response) = result, (300...399).contains(response.status),
                  let location = response.header("location"), let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                chain.append("GET \(Redactor.standard.url(url.absoluteString)) → \(describe(result))")
                return Fetch(url: start, result: result, chain: chain, redirectNote: nil, finalURL: url)
            }
            chain.append("GET \(Redactor.standard.url(url.absoluteString)) → HTTP \(response.status), Location: \(Redactor.standard.url(next.absoluteString))")
            if scope.target(for: next) == nil {
                return Fetch(url: start, result: result, chain: chain,
                             redirectNote: "Redirect to \(Redactor.standard.url(origin(next))) was not followed: it is outside the scope you entered.",
                             finalURL: url)
            }
            redirects += 1
            if redirects > configuration.maxRedirects {
                return Fetch(url: start, result: result, chain: chain, redirectNote: "Stopped after \(configuration.maxRedirects) redirects.", finalURL: url)
            }
            url = next
        }
    }

    private func origin(_ url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        return components.string ?? url.absoluteString
    }

    private func describe(_ result: HTTPProbeResult) -> String {
        switch result {
        case .response(let response):
            return "HTTP \(response.status)" + (response.remoteAddress.map { " from \($0)" } ?? "")
        case .failure(let failure):
            return "no response (\(failure.kind.rawValue): \(failure.message))"
        }
    }

    // MARK: One target

    private func assess(_ target: ScopedTarget, scope: TargetScope, control: AssessmentControl,
                        record: inout SecurityAssessmentRecord, progress: (AssessmentProgress) -> Void) throws {
        let context = TargetContext(target: target)
        let label = target.url.absoluteString
        var checks: [String: CheckResult] = [:]
        func set(_ id: String, _ title: String, _ outcome: CheckOutcome, _ detail: String) {
            checks[id] = CheckResult(id: "\(id)@\(target.host):\(target.port)", title: title, target: label, outcome: outcome, detail: detail)
        }
        func finish() {
            for id in ExposureCheck.checkIDs { if let check = checks[id] { record.checks.append(check) } }
        }

        // 1. Primary request (with in-scope redirects).
        let primary: Fetch
        do {
            primary = try fetch(target.url, context: context, scope: scope, control: control, record: &record)
        } catch Blocked.scope(let error) {
            record.errors.append(error.description)
            for id in ExposureCheck.checkIDs {
                set(id, title(id), .unsupported, "Not contacted: \(error.description)")
            }
            record.workCompleted += 3
            finish()
            return
        } catch Blocked.budget {
            record.errors.append("\(target.host): request limit reached")
            finish()
            return
        }
        record.workCompleted += 1
        progress(AssessmentProgress(completed: record.workCompleted, total: record.workTotal, current: "\(target.host): response received"))

        var final: HTTPProbeResponse?
        switch primary.result {
        case .response(let response):
            final = response
            var detail = "HTTP \(response.status) — " + primary.chain.joined(separator: " ; ")
            if let note = primary.redirectNote { detail += " " + note }
            set("reachability", title("reachability"), response.status >= 500 ? .inconclusive : .passed, detail)
            if response.status >= 500 {
                checks["reachability"]?.detail += " The service answered with a server error, so header checks describe an error page."
            }
        case .failure(let failure):
            if failure.isTLS {
                set("reachability", title("reachability"), .inconclusive, "The TLS handshake failed, so no HTTP response was received. See the TLS check.")
            } else if failure.kind == .blockedByPlatform {
                set("reachability", title("reachability"), .unsupported, "Not tested on this platform: \(failureText(failure)). Enter the https:// address instead.")
            } else {
                set("reachability", title("reachability"), .failedToExecute, "No response: \(failureText(failure))")
                record.errors.append("\(target.host): \(failureText(failure))")
            }
        }

        // 2. TLS, from the HTTPS leg (the primary request, or a separate HTTPS attempt for http targets).
        var httpsResult: HTTPProbeResult? = target.isHTTPS ? primary.result : nil
        var httpsURL = target.url
        if !target.isHTTPS {
            var components = URLComponents(url: target.url, resolvingAgainstBaseURL: false)!
            components.scheme = "https"
            components.port = nil
            components.path = "/"
            components.query = nil
            httpsURL = components.url!
            do {
                httpsResult = try send(httpsURL, context: context, scope: scope, control: control, record: &record)
            } catch Blocked.scope(let error) {
                record.notTested.append("HTTPS on \(target.host): \(error.description)")
            } catch Blocked.budget {
                record.notTested.append("HTTPS on \(target.host): request limit reached")
            }
        }
        evaluateTLS(httpsResult, url: httpsURL, target: target, record: &record, set: set)

        // 3. HTTP → HTTPS behaviour.
        if target.isHTTPS {
            if target.port != 443 {
                set("https", title("https"), .unsupported, "The target uses port \(target.port), so the matching plain-HTTP port is unknown. Not tested.")
            } else {
                var components = URLComponents(url: target.url, resolvingAgainstBaseURL: false)!
                components.scheme = "http"
                components.port = nil
                let httpURL = components.url!
                do {
                    let plain = try send(httpURL, context: context, scope: scope, control: control, record: &record)
                    evaluateRedirect(plain, from: httpURL, target: target, httpsAvailable: true, record: &record, set: set)
                } catch Blocked.scope(let error) {
                    set("https", title("https"), .unsupported, "Not tested: \(error.description)")
                } catch Blocked.budget {
                    set("https", title("https"), .inconclusive, "Not tested: request limit reached.")
                }
            }
        } else {
            let httpsWorks: Bool
            if case .response? = httpsResult { httpsWorks = true } else { httpsWorks = false }
            evaluateRedirect(primary.result, from: target.url, target: target, httpsAvailable: httpsWorks, record: &record, set: set)
        }
        record.workCompleted += 1

        // 4. Headers and disclosure, on the final response of the primary request.
        if let response = final, !(300...399).contains(response.status) || primary.redirectNote != nil {
            evaluateHeaders(response, url: primary.finalURL, target: target, record: &record, set: set)
            evaluateDisclosure(response, url: primary.finalURL, target: target, record: &record, set: set)
        } else if final == nil {
            for id in ["hsts", "headers", "disclosure"] {
                set(id, title(id), .failedToExecute, "No HTTP response to examine.")
            }
        } else {
            for id in ["hsts", "headers", "disclosure"] {
                set(id, title(id), .inconclusive, "The response was a redirect that could not be followed to a final page.")
            }
        }
        record.workCompleted += 1
        finish()
    }

    private func title(_ id: String) -> String {
        switch id {
        case "reachability": return "Reachability and HTTP status"
        case "tls": return "TLS certificate validity and host name"
        case "https": return "HTTP to HTTPS behaviour"
        case "hsts": return "Strict-Transport-Security"
        case "headers": return "Security headers"
        case "disclosure": return "Server and version disclosure"
        default: return id
        }
    }

    private func failureText(_ failure: HTTPProbeFailure) -> String {
        switch failure.kind {
        case .dns: return "the name could not be resolved (\(failure.message))"
        case .timeout: return "the request timed out"
        case .refused: return "the connection was refused"
        case .network: return "the network was unavailable (\(failure.message))"
        case .cancelled: return "cancelled"
        case .blockedByPlatform: return "iOS App Transport Security does not let apps send plain-HTTP requests to public hosts"
        case .tlsUntrusted, .tlsOther: return "the TLS handshake failed (\(failure.message))"
        case .other: return failure.message
        }
    }

    // MARK: Evaluations

    private func evaluateTLS(_ result: HTTPProbeResult?, url: URL, target: ScopedTarget, record: inout SecurityAssessmentRecord,
                             set: (String, String, CheckOutcome, String) -> Void) {
        let location = Redactor.standard.url(url.absoluteString)
        guard let result = result else {
            set("tls", title("tls"), .unsupported, "No HTTPS request was made.")
            return
        }
        switch result {
        case .response(let response):
            var evidence = ["GET \(location) → HTTP \(response.status) over a connection the system trusted"]
            if let tls = response.tls {
                if !tls.chainSubjects.isEmpty { evidence.append("Certificate chain: " + tls.chainSubjects.joined(separator: " ← ")) }
                if let leaf = tls.leaf { evidence.append("Valid until \(ISO8601DateFormatter().string(from: leaf.notAfter))") }
            }
            if let leaf = response.tls?.leaf {
                let days = Int(leaf.notAfter.timeIntervalSince(now()) / 86_400)
                if days < configuration.expiryWarningDays {
                    set("tls", title("tls"), .finding, "Trusted, but the certificate expires in \(max(0, days)) day(s).")
                    record.findings.append(SecurityFinding(
                        id: "tls-expiring:\(target.host)", checkID: "tls", title: "Certificate expires soon",
                        severity: days < 7 ? .medium : .low, confidence: .high, basis: .verified, location: location,
                        evidence: evidence, explanation: "Once it expires, browsers and apps will refuse the connection.",
                        remediation: "Renew the certificate and check that automatic renewal works."))
                    return
                }
            }
            let detail = response.tls == nil
                ? "The system accepted the certificate for \(target.host). Certificate details are not available on this platform."
                : "The system accepted the certificate for \(target.host)."
            set("tls", title("tls"), .passed, detail + (evidence.count > 1 ? " " + evidence.dropFirst().joined(separator: "; ") : ""))
        case .failure(let failure):
            guard failure.isTLS else {
                if case .refused = failure.kind, !target.isHTTPS {
                    set("tls", title("tls"), .unsupported, "No HTTPS service answered on \(target.host):443, so there is no certificate to check.")
                } else {
                    set("tls", title("tls"), .failedToExecute, "The HTTPS request did not complete: \(failureText(failure)).")
                }
                return
            }
            var evidence = ["GET \(location) → refused by the system's TLS validation: \(failure.message)"]
            var headline = "Certificate not trusted"
            var explanation = "The system refused the certificate, so apps and browsers will show errors or refuse to connect. This can be a self-signed or private-CA certificate, a missing intermediate, or interception."
            var remediation = "Install a certificate from a publicly trusted CA (or deploy your private CA to the clients that use this service), including the full intermediate chain."
            if let tls = failure.tls {
                if !tls.chainSubjects.isEmpty { evidence.append("Presented chain: " + tls.chainSubjects.joined(separator: " ← ")) }
                if let leaf = tls.leaf {
                    let names = leaf.dnsNames.isEmpty ? (leaf.commonName.map { "CN=\($0)" } ?? "none") : leaf.dnsNames.prefix(10).joined(separator: ", ")
                    evidence.append("Certificate names: \(names)")
                    evidence.append("Valid \(ISO8601DateFormatter().string(from: leaf.notBefore)) to \(ISO8601DateFormatter().string(from: leaf.notAfter))")
                    if leaf.notAfter < now() {
                        headline = "Certificate expired"
                        explanation = "The certificate's validity period has ended, so clients refuse the connection."
                        remediation = "Renew the certificate and check that automatic renewal works."
                    } else if leaf.notBefore > now() {
                        headline = "Certificate not yet valid"
                        explanation = "The certificate's validity period has not started. Check the server's clock and the certificate."
                        remediation = "Install a currently valid certificate and check the server's clock."
                    } else if tls.trustedIgnoringHost == true {
                        headline = "Certificate does not match the host name"
                        explanation = "The certificate was issued for other names, so clients cannot confirm they reached \(target.host)."
                        remediation = "Install a certificate whose names include \(target.host)."
                    } else if !leaf.matches(host: target.host) {
                        headline = "Certificate not trusted and issued for other names"
                        explanation = "The certificate was issued for other names, so clients cannot confirm they reached \(target.host)."
                        remediation = "Install a certificate whose names include \(target.host)."
                    }
                }
            }
            set("tls", title("tls"), .finding, "\(headline): \(failure.message)")
            record.findings.append(SecurityFinding(
                id: "tls-untrusted:\(target.host)", checkID: "tls", title: headline, severity: .high, confidence: .high,
                basis: .verified, location: location, evidence: evidence, explanation: explanation, remediation: remediation))
        }
    }

    private func evaluateRedirect(_ result: HTTPProbeResult, from url: URL, target: ScopedTarget, httpsAvailable: Bool,
                                  record: inout SecurityAssessmentRecord, set: (String, String, CheckOutcome, String) -> Void) {
        let location = Redactor.standard.url(url.absoluteString)
        switch result {
        case .response(let response):
            if (300...399).contains(response.status), let header = response.header("location"),
               let next = URL(string: header, relativeTo: url)?.absoluteURL {
                if next.scheme?.lowercased() == "https" && scope(next, sameHostAs: target) {
                    set("https", title("https"), .passed, "GET \(location) → HTTP \(response.status) to \(Redactor.standard.url(next.absoluteString))")
                } else if next.scheme?.lowercased() == "https" {
                    set("https", title("https"), .inconclusive, "Plain HTTP redirects to HTTPS on another host (\(Redactor.standard.url(origin(next)))), which was not followed.")
                } else {
                    set("https", title("https"), .inconclusive, "Plain HTTP redirects to another plain-HTTP address (\(Redactor.standard.url(origin(next)))).")
                }
                return
            }
            let evidence = ["GET \(location) → HTTP \(response.status) with no redirect to HTTPS"]
            if httpsAvailable {
                set("https", title("https"), .finding, "Plain HTTP answers with HTTP \(response.status) instead of redirecting to HTTPS.")
                record.findings.append(SecurityFinding(
                    id: "http-no-redirect:\(target.host)", checkID: "https", title: "Plain HTTP does not redirect to HTTPS",
                    severity: .medium, confidence: .high, basis: .verified, location: location, evidence: evidence,
                    explanation: "Visitors who type the address or follow an http:// link use an unencrypted connection that can be read or altered on the network.",
                    remediation: "Redirect every plain-HTTP request to the HTTPS address (301 or 308), then add Strict-Transport-Security."))
            } else {
                set("https", title("https"), .finding, "The service answers only over plain HTTP.")
                record.findings.append(SecurityFinding(
                    id: "http-only:\(target.host)", checkID: "https", title: "Service is only available over unencrypted HTTP",
                    severity: .medium, confidence: .medium, basis: .verified, location: location,
                    evidence: evidence + ["No HTTPS service answered on \(target.host):443"],
                    explanation: "Everything sent to and from this service, including any login, can be read or altered on the network. HTTPS may be offered on another port that was not tested.",
                    remediation: "Serve the service over HTTPS with a trusted certificate and redirect plain HTTP to it."))
            }
        case .failure(let failure):
            switch failure.kind {
            case .refused:
                set("https", title("https"), .passed, "Nothing answered plain HTTP on \(target.host):\(url.port ?? 80), so there is no unencrypted version to redirect.")
            case .blockedByPlatform:
                set("https", title("https"), .unsupported, "Not tested on this platform: \(failureText(failure)).")
            case .timeout:
                set("https", title("https"), .inconclusive, "Plain HTTP on \(target.host):\(url.port ?? 80) timed out; it may be filtered or slow.")
            default:
                set("https", title("https"), .failedToExecute, "The plain-HTTP request failed: \(failureText(failure)).")
            }
        }
    }

    private func scope(_ url: URL, sameHostAs target: ScopedTarget) -> Bool {
        url.host.map { AddressClassifier.normalizedHost($0) == target.host } ?? false
    }

    private struct HeaderRule {
        let id: String
        let name: String
        let present: (HTTPProbeResponse) -> Bool
        let htmlOnly: Bool
        let explanation: String
        let remediation: String
    }

    private static let headerRules: [HeaderRule] = [
        HeaderRule(id: "csp", name: "Content-Security-Policy", present: { $0.header("content-security-policy") != nil }, htmlOnly: true,
                   explanation: "Without a Content-Security-Policy, a browser has no restrictions on where a page may load scripts from, which makes injected content more damaging.",
                   remediation: "Add a Content-Security-Policy suited to the page, starting with a report-only policy if needed."),
        HeaderRule(id: "nosniff", name: "X-Content-Type-Options", present: { $0.header("x-content-type-options")?.lowercased().contains("nosniff") == true }, htmlOnly: false,
                   explanation: "Without “nosniff”, some browsers guess content types, which can turn an uploaded file into executable content.",
                   remediation: "Send X-Content-Type-Options: nosniff on every response."),
        HeaderRule(id: "framing", name: "Frame protection (X-Frame-Options or CSP frame-ancestors)", present: {
                       $0.header("x-frame-options") != nil || ($0.header("content-security-policy")?.lowercased().contains("frame-ancestors") ?? false)
                   }, htmlOnly: true,
                   explanation: "Without frame protection, another site can embed this page invisibly and trick users into clicking (clickjacking).",
                   remediation: "Send Content-Security-Policy: frame-ancestors 'self' (or X-Frame-Options: DENY/SAMEORIGIN)."),
        HeaderRule(id: "referrer", name: "Referrer-Policy", present: { $0.header("referrer-policy") != nil }, htmlOnly: true,
                   explanation: "Without a Referrer-Policy, full URLs (which can contain identifiers) may be sent to other sites in the Referer header.",
                   remediation: "Send Referrer-Policy: strict-origin-when-cross-origin or stricter.")
    ]

    private func evaluateHeaders(_ response: HTTPProbeResponse, url: URL, target: ScopedTarget, record: inout SecurityAssessmentRecord,
                                 set: (String, String, CheckOutcome, String) -> Void) {
        let location = Redactor.standard.url(url.absoluteString)
        let contentType = response.header("content-type") ?? "not stated"
        let isHTML = contentType.lowercased().contains("text/html")
        let context = isHTML ? "an HTML page" : (response.header("content-type") == nil ? "a response without a Content-Type" : "a \(contentType) response")
        let statusNote = (200...299).contains(response.status) ? "" : " (HTTP \(response.status))"

        // HSTS only means something over HTTPS.
        if url.scheme?.lowercased() == "https" {
            if let hsts = response.header("strict-transport-security") {
                let maxAge = hsts.lowercased().components(separatedBy: ";").compactMap { part -> Int? in
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    return trimmed.hasPrefix("max-age=") ? Int(trimmed.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "\""))) : nil
                }.first ?? 0
                if maxAge < 15_552_000 {
                    set("hsts", title("hsts"), .finding, "Present, but max-age is \(maxAge) seconds.")
                    record.findings.append(SecurityFinding(
                        id: "hsts-short:\(target.host)", checkID: "hsts", title: "Strict-Transport-Security max-age is short",
                        severity: .info, confidence: .high, basis: .observation, location: location,
                        evidence: ["Strict-Transport-Security: \(Redactor.standard.text(hsts))"],
                        explanation: "Browsers forget the HTTPS-only rule after max-age seconds; a short value gives little protection on later visits.",
                        remediation: "Use max-age=31536000 (one year) once HTTPS works everywhere on this host."))
                } else {
                    set("hsts", title("hsts"), .passed, "Strict-Transport-Security: \(Redactor.standard.text(hsts))")
                }
            } else {
                set("hsts", title("hsts"), .finding, "Not sent\(statusNote).")
                record.findings.append(SecurityFinding(
                    id: "hsts-missing:\(target.host)", checkID: "hsts", title: "Strict-Transport-Security is not set",
                    severity: .low, confidence: .high, basis: .observation, location: location,
                    evidence: ["GET \(location) → HTTP \(response.status) without Strict-Transport-Security"],
                    explanation: "Without HSTS, a browser may still try plain HTTP first on later visits, where the connection can be intercepted. This is an observation, not a demonstrated attack.",
                    remediation: "After HTTPS works everywhere on this host, send Strict-Transport-Security: max-age=31536000."))
            }
        } else {
            set("hsts", title("hsts"), .unsupported, "The final response was plain HTTP, where Strict-Transport-Security has no effect.")
        }

        if (300...399).contains(response.status) {
            set("headers", title("headers"), .inconclusive,
                "The final response was an HTTP \(response.status) redirect that was not followed, so the destination page's headers were not examined.")
            return
        }
        var missing: [String] = []
        for rule in ExposureCheck.headerRules where !rule.present(response) {
            missing.append(rule.name)
            let relevant = isHTML || !rule.htmlOnly
            record.findings.append(SecurityFinding(
                id: "header-\(rule.id):\(target.host)", checkID: "headers", title: "\(rule.name) is not set",
                severity: relevant ? .low : .info, confidence: relevant ? .high : .medium, basis: .observation, location: location,
                evidence: ["GET \(location) → HTTP \(response.status), Content-Type: \(Redactor.standard.text(contentType)), no \(rule.name)"],
                explanation: rule.explanation + (relevant ? "" : " This response is \(context), where the header matters less."),
                remediation: rule.remediation))
        }
        if missing.isEmpty {
            set("headers", title("headers"), .passed, "All checked headers are present on \(context)\(statusNote).")
        } else {
            set("headers", title("headers"), .finding, "Missing on \(context)\(statusNote): " + missing.joined(separator: ", "))
        }
    }

    private static let versionPattern = try! NSRegularExpression(pattern: "\\d+\\.\\d+")
    private static let disclosureHeaders = ["server", "x-powered-by", "x-aspnet-version", "x-aspnetmvc-version", "x-generator", "x-runtime", "via"]

    private func evaluateDisclosure(_ response: HTTPProbeResponse, url: URL, target: ScopedTarget, record: inout SecurityAssessmentRecord,
                                    set: (String, String, CheckOutcome, String) -> Void) {
        let location = Redactor.standard.url(url.absoluteString)
        var versioned: [String] = []
        var banners: [String] = []
        for name in ExposureCheck.disclosureHeaders {
            guard let raw = response.header(name) else { continue }
            let value = Redactor.standard.text(String(raw.prefix(120)))
            let line = "\(name): \(value)"
            banners.append(line)
            if ExposureCheck.versionPattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil {
                versioned.append(line)
            }
        }
        if versioned.isEmpty {
            set("disclosure", title("disclosure"), .passed,
                banners.isEmpty ? "No server or framework banner headers were sent." : "Banners without version numbers: " + banners.joined(separator: "; "))
            return
        }
        set("disclosure", title("disclosure"), .finding, "Version numbers in: " + versioned.joined(separator: "; "))
        record.findings.append(SecurityFinding(
            id: "version-disclosure:\(target.host)", checkID: "disclosure", title: "Server reveals software versions",
            severity: .info, confidence: .medium, basis: .observation, location: location, evidence: versioned,
            explanation: "Version banners help an attacker pick known issues to try. A banner can be inaccurate, and a version number alone does not confirm the software is vulnerable.",
            remediation: "Remove or generalise version details in these headers, and keep the software patched regardless."))
    }
}
