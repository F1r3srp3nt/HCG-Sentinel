import Foundation

/// How a Sentinel pairing is authorized, and how that is shown.
///
/// Production pairings use HCG Connect (unchanged). A server in local
/// development pairing mode says so in its invitation (`am`); only then does
/// Sentinel pair without an HCG sign-in, using `LocalDevelopmentTokens`, and
/// every place that shows such a connection carries `localDevelopmentLabel`.
public enum SentinelLinkAuthority {
    /// Shown wherever a local-development connection appears.
    public static let localDevelopmentLabel = "LOCAL DEVELOPMENT — not an HCG account"
    public static let localDevelopmentExplanation =
        "Paired with the server owner's approval only, without HCG Connect. It reaches this one HCG Server and nothing on HCG services; the server refuses remote actions."

    /// `LocalDevelopmentTokens` only when the server said it is in local
    /// development mode; otherwise the HCG Connect session, as before.
    public static func tokens(isLocalDevelopment: Bool, hcgConnect: AccessTokenProvider) -> AccessTokenProvider {
        isLocalDevelopment ? LocalDevelopmentTokens() : hcgConnect
    }

    public static func tokens(for invitation: Invitation, hcgConnect: AccessTokenProvider) -> AccessTokenProvider {
        tokens(isLocalDevelopment: invitation.isLocalDevelopment, hcgConnect: hcgConnect)
    }

    public static func tokens(for record: PairingRecord, hcgConnect: AccessTokenProvider) -> AccessTokenProvider {
        tokens(isLocalDevelopment: record.isLocalDevelopment, hcgConnect: hcgConnect)
    }

    /// Whether an installation listed by the server was paired in local development mode.
    public static func isLocalDevelopment(_ installation: LinkInstallation) -> Bool {
        installation.authority == DeviceLinkProtocol.Authority.localDevelopment
    }

    /// A readable name for an authority value reported by the server.
    public static func label(forAuthority authority: String) -> String {
        switch authority {
        case DeviceLinkProtocol.Authority.hcgConnect: return "HCG Connect"
        case DeviceLinkProtocol.Authority.localDevelopment: return localDevelopmentLabel
        case "not-configured": return "Not configured"
        default: return authority
        }
    }

    /// What to show when the server ends the link. `authority_changed` gets its
    /// own explanation and asks the user to pair again.
    public static func endedMessage(_ error: DeviceLinkError) -> String {
        guard error.code == "authority_changed" else { return error.description }
        return "HCG Server changed how it authorizes apps (local development pairing was switched off, or HCG Connect was set up), so this pairing no longer works. Pair again with a new invitation from the server. (\(error.description))"
    }

    /// The link ended in a way that needs a new pairing (the record is marked removed).
    public static func needsNewPairing(_ error: DeviceLinkError) -> Bool {
        ["device_revoked", "unknown_installation", "authority_changed"].contains(error.code)
    }
}

/// What the HCG Server health screen shows: only what the server returned,
/// or why nothing could be read.
public enum ServerHealthState: Equatable, Sendable {
    /// Not paired, not approved yet, or remote connections are off.
    case notConnected(String)
    case loading
    /// The diagnostics call failed; the real error.
    case failed(String)
    case loaded(LinkDiagnostics, fetchedAt: Date)
}

/// Read-only presentation of `LinkDiagnostics` as labelled rows. Every value
/// comes from the server's answer; missing values say "Not reported".
public enum ServerHealthPresenter {
    public enum Tone: String, Equatable, Sendable { case ok, warning, danger, neutral }

    public struct Row: Equatable, Sendable {
        public var label: String
        public var value: String
        public var tone: Tone
        public var mono: Bool

        public init(_ label: String, _ value: String, tone: Tone = .neutral, mono: Bool = false) {
            self.label = label
            self.value = value
            self.tone = tone
            self.mono = mono
        }
    }

    public struct Section: Equatable, Sendable {
        public var title: String
        public var rows: [Row]
        /// Shown when there are no rows.
        public var empty: String?
    }

    static let notReported = "Not reported"

    public static func sections(_ d: LinkDiagnostics, pinnedFingerprint: String?, timeZone: TimeZone = .current) -> [Section] {
        let df = dateFormatter(timeZone)
        func date(_ x: Date?) -> String { x.map { df.string(from: $0) } ?? notReported }
        func text(_ s: String) -> String { s.isEmpty ? notReported : s }

        let server = Section(title: "Server", rows: [
            Row("Availability", d.server.available ? "Available" : "Not available", tone: d.server.available ? .ok : .danger),
            Row("Agent version", text(d.server.agentVersion), mono: true),
            Row("Uptime", duration(d.server.uptimeSeconds)),
            Row("Started", date(d.server.startedAt)),
            Row("Authority", SentinelLinkAuthority.label(forAuthority: d.server.authority),
                tone: d.server.authority == DeviceLinkProtocol.Authority.localDevelopment ? .warning : .neutral),
            Row("Report generated", date(d.generatedAt)),
        ], empty: nil)

        var tls: [Row] = [
            Row("Device API", text(d.tls.deviceApi)),
            Row("Server key SHA-256", fingerprint(d.tls.serverKeySha256), mono: true),
        ]
        if let pinned = pinnedFingerprint, !d.tls.serverKeySha256.isEmpty {
            let same = normalizedHex(pinned) == normalizedHex(d.tls.serverKeySha256)
            tls.append(Row("Pinned key", same ? "Matches the key pinned at pairing" : "Does not match the key pinned at pairing",
                           tone: same ? .ok : .danger))
        }
        tls += [
            Row("Gateway", d.tls.gatewayRunning ? "Running" : "Not running", tone: d.tls.gatewayRunning ? .ok : .warning),
            Row("Gateway exposure", exposure(d.tls.gatewayExposure)),
            Row("Gateway CA SHA-256", fingerprint(d.tls.gatewayCaSha256), mono: true),
            Row("Certificate expires", expiry(d.tls.gatewayLeafExpires, now: d.generatedAt, formatter: df),
                tone: expiryTone(d.tls.gatewayLeafExpires, now: d.generatedAt)),
        ]

        let services = Section(title: "Hosted services", rows: d.services.map { s in
            var parts = ["\(s.status)", "health \(s.health)"]
            if let up = s.uptimeSeconds { parts.append("up \(duration(up))") }
            parts.append("\(s.restarts) restart\(s.restarts == 1 ? "" : "s")")
            if let h = s.lastHealthAt { parts.append("checked \(df.string(from: h))") }
            if let detail = s.detail, !detail.isEmpty { parts.append(detail) }
            return Row("\(s.name) \(s.version)", parts.joined(separator: " · "), tone: serviceTone(s.health))
        }, empty: "The server reports no hosted services.")

        let events = Section(title: "Security events", rows: d.securityEvents.map { e in
            Row("\(df.string(from: e.time)) · \(e.severity)", e.message, tone: eventTone(e.severity))
        }, empty: "The server reports no security events.")

        let auth = Section(title: "Failed authentications (24 h)", rows: [
            Row("Count", String(d.failedAuthentications24h), tone: d.failedAuthentications24h > 0 ? .warning : .ok),
        ], empty: nil)

        let summary = Section(title: "Summary", rows: d.summary.map { Row("", $0) }, empty: "The server sent no summary.")

        return [server, Section(title: "TLS", rows: tls, empty: nil), services, events, auth, summary]
    }

    /// "3 d 4 h", "2 h 5 min", "42 s".
    public static func duration(_ seconds: Int64) -> String {
        let s = max(0, seconds)
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return "\(d) d \(h) h" }
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return "\(m) min" }
        return "\(s) s"
    }

    static func fingerprint(_ hex: String) -> String {
        hex.isEmpty ? notReported : LinkCrypto.displayFingerprint(normalizedHex(hex))
    }

    static func normalizedHex(_ s: String) -> String {
        String(s.lowercased().filter { $0.isHexDigit })
    }

    static func exposure(_ e: String) -> String {
        switch e {
        case "loopback": return "This Mac only (loopback)"
        case "lan": return "Local network (approved by the owner)"
        case "": return notReported
        default: return e
        }
    }

    static func expiry(_ x: Date?, now: Date, formatter: DateFormatter) -> String {
        guard let x = x else { return notReported }
        return formatter.string(from: x) + (x < now ? " (expired)" : "")
    }

    static func expiryTone(_ x: Date?, now: Date) -> Tone {
        guard let x = x else { return .neutral }
        if x < now { return .danger }
        return x.timeIntervalSince(now) < 14 * 86_400 ? .warning : .ok
    }

    static func serviceTone(_ health: String) -> Tone {
        switch health {
        case "ok": return .ok
        case "failing": return .danger
        default: return .warning
        }
    }

    static func eventTone(_ severity: String) -> Tone {
        switch severity.lowercased() {
        case "critical", "error", "high": return .danger
        case "warning", "warn", "medium": return .warning
        default: return .neutral
        }
    }

    static func dateFormatter(_ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }
}

extension SentinelReportSharing {
    /// HCG Server health as a shareable report. Strict redaction: the server
    /// already redacts its security events; Sentinel's redactor and the shared
    /// rules run again, and IP addresses are masked (the device API address is
    /// not included).
    /// `redaction` should allow `serverName` (the server's display name is the
    /// only host name a shared report may carry); by default it does.
    public static func report(from d: LinkDiagnostics, serverName: String, reportId: String = UUID().uuidString, installationId: String,
                              appVersion: String, deviceName: String, sharedAt: Date = Date(),
                              redaction: ShareRedaction? = nil) -> DiagnosticReport {
        let r = (redaction ?? ShareRedaction(context: .init(allowedNames: [serverName]))).redact
        let failing = d.services.filter { $0.health == "failing" }
        let findings = failing.map { s in
            DiagnosticReport.Finding(title: "\(r(s.name)) is failing its health check", severity: "medium", confidence: nil, basis: "observation",
                                     location: "Hosted service \(r(s.id))", evidence: [r("Status: \(s.status)")] + (s.detail.map { [r($0)] } ?? []),
                                     explanation: nil, remediation: nil)
        } + d.securityEvents.filter { ServerHealthPresenter.eventTone($0.severity) != .neutral }.map { e in
            DiagnosticReport.Finding(title: r(e.message), severity: ServerHealthPresenter.eventTone(e.severity) == .danger ? "high" : "low",
                                     confidence: nil, basis: "observation", location: "Security event", evidence: ["Severity: \(r(e.severity))"],
                                     explanation: nil, remediation: nil)
        }
        var checks = [
            DiagnosticReport.Check(title: "Server availability", outcome: d.server.available ? "passed" : "finding",
                                   detail: "HCG Server \(r(d.server.agentVersion)), up \(ServerHealthPresenter.duration(d.server.uptimeSeconds))"),
            DiagnosticReport.Check(title: "Authority", outcome: "passed", detail: SentinelLinkAuthority.label(forAuthority: d.server.authority)),
            DiagnosticReport.Check(title: "Device API transport", outcome: "passed", detail: r(d.tls.deviceApi)),
            DiagnosticReport.Check(title: "Gateway", outcome: d.tls.gatewayRunning ? "passed" : "notice",
                                   detail: (d.tls.gatewayRunning ? "running, " : "not running, ") + ServerHealthPresenter.exposure(d.tls.gatewayExposure)),
            DiagnosticReport.Check(title: "Failed authentications (24 h)", outcome: d.failedAuthentications24h > 0 ? "notice" : "passed",
                                   detail: String(d.failedAuthentications24h)),
        ]
        checks += d.services.map { s in
            DiagnosticReport.Check(title: "Service \(r(s.name)) \(r(s.version))", outcome: s.health == "ok" ? "passed" : s.health == "failing" ? "finding" : "notChecked",
                                   detail: "\(s.status), health \(s.health)")
        }
        let highest = findings.contains { $0.severity == "high" } ? "high" : findings.contains { $0.severity == "medium" } ? "medium" : findings.isEmpty ? nil : "low"
        return DiagnosticReport.make(
            reportId: reportId, kind: "hcg-server.health", title: "HCG Server health — \(r(serverName))",
            origin: .init(app: app, appVersion: appVersion, installationId: installationId, deviceName: deviceName, module: "serverHealth", moduleVersion: nil),
            createdAt: d.generatedAt, completedAt: d.generatedAt,
            summary: .init(status: "completed", highestSeverity: highest, findingCount: findings.count),
            scope: ["HCG Server \(r(serverName)) (read-only diagnostics)"],
            findings: findings, checks: checks,
            limitations: d.summary.map(r) + ["Read from HCG Server's own diagnostics; security events were redacted by the server and again by Sentinel. Addresses are withheld."],
            notTested: [], redactor: .strict, sharedAt: sharedAt)
    }
}
