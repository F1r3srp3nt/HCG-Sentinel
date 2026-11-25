import Foundation
import XCTest
@testable import SentinelCore

/// Local development pairing, `authority_changed` and the read-only HCG Server
/// health view (Device Link 1.1). No network: a stub transport answers.
final class ServerHealthTests: XCTestCase {
    let serverKey = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    let caKey = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

    func invitation(authMode: String?) throws -> Invitation {
        var payload: [String: Any] = ["v": 1, "id": "inv1", "s": "sec", "hd": "d1", "hn": "Dev Mac", "ha": "dev-mac.local:7610",
                                      "fp": serverKey, "exp": "2099-01-01T00:00:00Z"]
        if let am = authMode { payload["am"] = am }
        let json = try JSONSerialization.data(withJSONObject: payload)
        let b64 = json.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return try Invitation.parse("hcg1-" + b64)
    }

    func diagnosticsJSON(authority: String = "local-development", serverKey: String? = nil, services: String? = nil,
                         events: String? = nil, leafExpires: String = "2027-02-01T00:00:00Z") -> String {
        let svc = services ?? #"[{"id":"system-tester","productId":"hcg.system-tester","name":"HCG System Tester","version":"0.1.0","runtime":"native-process","status":"running","health":"ok","uptimeSeconds":3725,"restarts":1,"lastHealthAt":"2026-11-25T10:00:00Z","capabilities":["dashboard","health"],"gatewayPublished":true,"openable":false}]"#
        let ev = events ?? #"[{"time":"2026-11-25T09:59:00Z","severity":"warning","message":"Rejected a request with a wrong signature from [address]"}]"#
        return """
        {"generatedAt":"2026-11-25T10:00:00Z","server":{"available":true,"agentVersion":"0.9.0","startedAt":"2026-11-24T08:00:00Z","uptimeSeconds":93600,"authority":"\(authority)"},\
        "tls":{"deviceApi":"TLS 1.3, server key pinned by the app; requests signed by the installation key","serverKeySha256":"\(serverKey ?? self.serverKey)","gatewayRunning":true,"gatewayExposure":"loopback","gatewayCaSha256":"\(caKey)","gatewayLeafExpires":"\(leafExpires)"},\
        "services":\(svc),"securityEvents":\(ev),"failedAuthentications24h":2,\
        "summary":["HCG Server 0.9.0 is available (up 26h0m0s).","1 of 1 hosted service(s) healthy; 0 failing health checks.","Gateway listening (loopback)."]}
        """
    }

    func diagnostics(_ json: String? = nil) throws -> LinkDiagnostics {
        try LinkJSON.decoder().decode(LinkDiagnostics.self, from: Data((json ?? diagnosticsJSON()).utf8))
    }

    // MARK: authority

    func testLocalDevelopmentInvitationUsesEmptyTokensAndPersistsAuthMode() async throws {
        let dev = try invitation(authMode: "local-development")
        XCTAssertTrue(dev.isLocalDevelopment)
        let tokens = SentinelLinkAuthority.tokens(for: dev, hcgConnect: FailingTokens())
        XCTAssertTrue(tokens is LocalDevelopmentTokens)
        let token = try await tokens.accessToken(forceRefresh: false)
        XCTAssertEqual(token, "")

        let record = PairingRecord(invitation: dev, requestId: "r1", status: .approved)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = PairingRecordFile(url: dir.appendingPathComponent("pairing.json"))
        try file.save(record)
        let back = try XCTUnwrap(file.load())
        XCTAssertEqual(back.authMode, DeviceLinkProtocol.Authority.localDevelopment)
        XCTAssertTrue(back.isLocalDevelopment)
        XCTAssertTrue(SentinelLinkAuthority.tokens(for: back, hcgConnect: FailingTokens()) is LocalDevelopmentTokens)
    }

    func testHCGConnectInvitationKeepsTheHCGConnectSession() throws {
        let prod = try invitation(authMode: nil)
        XCTAssertFalse(prod.isLocalDevelopment)
        XCTAssertTrue(SentinelLinkAuthority.tokens(for: prod, hcgConnect: FailingTokens()) is FailingTokens)
        let record = PairingRecord(invitation: prod, requestId: "r1", status: .approved)
        XCTAssertNil(record.authMode)
        XCTAssertTrue(SentinelLinkAuthority.tokens(for: record, hcgConnect: FailingTokens()) is FailingTokens)
        // An unknown mode is never treated as local development.
        XCTAssertTrue(SentinelLinkAuthority.tokens(for: try invitation(authMode: "something-else"), hcgConnect: FailingTokens()) is FailingTokens)
    }

    func testLocalDevelopmentRequestsCarryNoAuthorizationHeader() async throws {
        let transport = StubTransport(status: 200, body: diagnosticsJSON())
        let dev = try invitation(authMode: "local-development")
        let client = DeviceLinkClient(configuration: DeviceLinkConfiguration(baseURL: try XCTUnwrap(dev.baseURL), serverFingerprint: dev.fingerprint,
                                                                             installationId: "0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a"),
                                      signer: SoftwareSigner(), transport: transport,
                                      tokens: SentinelLinkAuthority.tokens(for: dev, hcgConnect: FailingTokens()))
        let d = try await client.diagnostics()
        XCTAssertEqual(d.server.authority, "local-development")
        let req = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(req.method, "GET")
        XCTAssertTrue(req.url.path.hasSuffix("/diagnostics"))
        XCTAssertNil(req.headers["Authorization"])
        XCTAssertNotNil(req.headers[DeviceLinkProtocol.Header.signature])
    }

    func testAuthorityChangedEndsTheLinkAndAsksToPairAgain() async throws {
        let transport = StubTransport(status: 403, body: #"{"error":"this installation was paired in local development mode, which is now off","code":"authority_changed","retryable":false,"protocol":"hcg.devicelink/1"}"#)
        let dev = try invitation(authMode: "local-development")
        let client = DeviceLinkClient(configuration: DeviceLinkConfiguration(baseURL: try XCTUnwrap(dev.baseURL), serverFingerprint: dev.fingerprint,
                                                                             installationId: "0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a"),
                                      signer: SoftwareSigner(), transport: transport, tokens: LocalDevelopmentTokens())
        do {
            _ = try await client.diagnostics()
            XCTFail("expected authority_changed")
        } catch let e as DeviceLinkError {
            XCTAssertEqual(e.code, "authority_changed")
            XCTAssertTrue(e.endsLink)
            XCTAssertFalse(e.isRetryable)
            XCTAssertTrue(SentinelLinkAuthority.needsNewPairing(e))
            let message = SentinelLinkAuthority.endedMessage(e)
            XCTAssertTrue(message.contains("Pair again"))
            XCTAssertTrue(message.contains("changed how it authorizes"))
        }
        XCTAssertEqual(transport.requests.count, 1, "authority_changed is never retried")
    }

    func testOtherEndingsKeepTheirOwnMessage() throws {
        let body = try LinkJSON.decoder().decode(LinkErrorBody.self, from: Data(#"{"error":"denied","code":"permission_denied","retryable":false}"#.utf8))
        let e = DeviceLinkError.server(status: 403, body: body)
        XCTAssertEqual(SentinelLinkAuthority.endedMessage(e), e.description)
        XCTAssertFalse(SentinelLinkAuthority.needsNewPairing(e))
    }

    func testAuthorityLabels() {
        XCTAssertEqual(SentinelLinkAuthority.localDevelopmentLabel, "LOCAL DEVELOPMENT — not an HCG account")
        XCTAssertEqual(SentinelLinkAuthority.label(forAuthority: "local-development"), SentinelLinkAuthority.localDevelopmentLabel)
        XCTAssertEqual(SentinelLinkAuthority.label(forAuthority: "hcg-connect"), "HCG Connect")
        XCTAssertEqual(SentinelLinkAuthority.label(forAuthority: "not-configured"), "Not configured")
    }

    // MARK: health view

    func row(_ sections: [ServerHealthPresenter.Section], _ title: String, _ label: String) -> ServerHealthPresenter.Row? {
        sections.first { $0.title == title }?.rows.first { $0.label == label }
    }

    func testSectionsShowOnlyWhatTheServerReturned() throws {
        let s = ServerHealthPresenter.sections(try diagnostics(), pinnedFingerprint: serverKey, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(s.map(\.title), ["Server", "TLS", "Hosted services", "Security events", "Failed authentications (24 h)", "Summary"])
        XCTAssertEqual(row(s, "Server", "Availability")?.value, "Available")
        XCTAssertEqual(row(s, "Server", "Agent version")?.value, "0.9.0")
        XCTAssertEqual(row(s, "Server", "Uptime")?.value, "1 d 2 h")
        XCTAssertEqual(row(s, "Server", "Authority")?.value, "LOCAL DEVELOPMENT — not an HCG account")
        XCTAssertEqual(row(s, "TLS", "Server key SHA-256")?.value, LinkCrypto.displayFingerprint(serverKey))
        XCTAssertEqual(row(s, "TLS", "Pinned key")?.tone, .ok)
        XCTAssertEqual(row(s, "TLS", "Gateway")?.value, "Running")
        XCTAssertEqual(row(s, "TLS", "Gateway exposure")?.value, "This Mac only (loopback)")
        XCTAssertEqual(row(s, "TLS", "Gateway CA SHA-256")?.value, LinkCrypto.displayFingerprint(caKey))
        XCTAssertEqual(row(s, "TLS", "Certificate expires")?.value, "2027-02-01 00:00:00")
        let service = try XCTUnwrap(s.first { $0.title == "Hosted services" }?.rows.first)
        XCTAssertEqual(service.label, "HCG System Tester 0.1.0")
        XCTAssertEqual(service.value, "running · health ok · up 1 h 2 min · 1 restart · checked 2026-11-25 10:00:00")
        XCTAssertEqual(service.tone, .ok)
        let event = try XCTUnwrap(s.first { $0.title == "Security events" }?.rows.first)
        XCTAssertEqual(event.value, "Rejected a request with a wrong signature from [address]")
        XCTAssertEqual(event.tone, .warning)
        XCTAssertEqual(row(s, "Failed authentications (24 h)", "Count")?.value, "2")
        XCTAssertEqual(s.last?.rows.count, 3)
    }

    func testMissingAndMismatchedValuesAreNotInvented() throws {
        let d = try diagnostics(diagnosticsJSON(authority: "hcg-connect", serverKey: caKey, services: "[]", events: "[]",
                                                leafExpires: "2026-11-01T00:00:00Z"))
        let s = ServerHealthPresenter.sections(d, pinnedFingerprint: serverKey, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(row(s, "Server", "Authority")?.value, "HCG Connect")
        XCTAssertEqual(row(s, "TLS", "Pinned key")?.tone, .danger)
        XCTAssertEqual(row(s, "TLS", "Certificate expires")?.tone, .danger)
        XCTAssertTrue(row(s, "TLS", "Certificate expires")?.value.hasSuffix("(expired)") ?? false)
        XCTAssertEqual(s.first { $0.title == "Hosted services" }?.rows, [])
        XCTAssertEqual(s.first { $0.title == "Hosted services" }?.empty, "The server reports no hosted services.")
        XCTAssertEqual(s.first { $0.title == "Security events" }?.rows, [])

        let noGateway = try diagnostics(diagnosticsJSON().replacingOccurrences(of: "\"gatewayCaSha256\":\"\(caKey)\"", with: "\"gatewayCaSha256\":\"\"")
            .replacingOccurrences(of: ",\"gatewayLeafExpires\":\"2027-02-01T00:00:00Z\"", with: ""))
        let s2 = ServerHealthPresenter.sections(noGateway, pinnedFingerprint: nil, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(row(s2, "TLS", "Gateway CA SHA-256")?.value, "Not reported")
        XCTAssertEqual(row(s2, "TLS", "Certificate expires")?.value, "Not reported")
        XCTAssertNil(row(s2, "TLS", "Pinned key"), "no comparison without a pinned key")
    }

    func testDuration() {
        XCTAssertEqual(ServerHealthPresenter.duration(42), "42 s")
        XCTAssertEqual(ServerHealthPresenter.duration(125), "2 min")
        XCTAssertEqual(ServerHealthPresenter.duration(7_500), "2 h 5 min")
        XCTAssertEqual(ServerHealthPresenter.duration(-5), "0 s")
    }

    // MARK: report

    func testHealthReportIsRedactedAndValid() throws {
        let events = #"[{"time":"2026-11-25T09:59:00Z","severity":"warning","message":"Login refused for 192.168.1.20 token=abcdef123456 Authorization: Bearer abcdefghijklmnop123456"}]"#
        let services = #"[{"id":"system-tester","productId":"hcg.system-tester","name":"HCG System Tester","version":"0.1.0","runtime":"native-process","status":"unhealthy","health":"failing","detail":"health check https://admin:hunter2@127.0.0.1:7700/health failed","restarts":3,"capabilities":[],"gatewayPublished":true,"openable":false}]"#
        let d = try diagnostics(diagnosticsJSON(services: services, events: events))
        let report = SentinelReportSharing.report(from: d, serverName: "Dev Mac", installationId: "0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a",
                                                  appVersion: "1.4.0", deviceName: "Ana's iPhone")
        XCTAssertEqual(report.kind, "hcg-server.health")
        XCTAssertEqual(report.summary.findingCount, 2)
        XCTAssertEqual(report.summary.highestSeverity, "medium")
        let text = String(decoding: try report.encoded(), as: UTF8.self)
        for secret in ["hunter2", "abcdef123456", "abcdefghijklmnop123456", "192.168.1.20", "127.0.0.1"] {
            XCTAssertFalse(text.contains(secret), "leaked \(secret)")
        }
        XCTAssertTrue(text.contains("HCG System Tester"))
        XCTAssertTrue(text.contains("LOCAL DEVELOPMENT"))
        XCTAssertEqual(ReportValidator.problems(report, encoded: try report.encoded()), [])
    }
}

private struct FailingTokens: AccessTokenProvider {
    struct NotSignedIn: Error {}
    func accessToken(forceRefresh: Bool) async throws -> String { throw NotSignedIn() }
}

private final class StubTransport: LinkTransport, @unchecked Sendable {
    let status: Int
    let body: String
    private let lock = NSLock()
    private var recorded: [LinkHTTPRequest] = []

    init(status: Int, body: String) {
        self.status = status
        self.body = body
    }

    var requests: [LinkHTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private func record(_ request: LinkHTTPRequest) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
    }

    func send(_ request: LinkHTTPRequest) async throws -> LinkHTTPResponse {
        record(request)
        return LinkHTTPResponse(status: status, headers: [:], body: Data(body.utf8))
    }
}
