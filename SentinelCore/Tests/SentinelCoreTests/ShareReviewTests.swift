import Foundation
import XCTest
@testable import SentinelCore

/// Sharing with a paired device: preview = payload, strict check, verified
/// destination, share history and withdraw. A routing stub stands in for HCG Server.
final class ShareReviewTests: XCTestCase {
    let serverKey = String(repeating: "ab", count: 32)
    let selfId = "0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a"
    let terminalId = "11111111-2222-4333-8444-555555555555"
    let terminalKey = String(repeating: "c1", count: 32)
    let otherKey = String(repeating: "d2", count: 32)
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: fixtures

    func installation(_ id: String, name: String, app: String = "hcg.terminal", key: String, receive: Bool = true,
                      state: String = "online", revoked: Bool = false) -> String {
        let caps = receive ? #"[{"id":"report.receive","state":"available"}]"# : #"[{"id":"report.send","state":"available"}]"#
        return """
        {"installationId":"\(id)","name":"\(name)","platform":"macOS 15","app":"\(app)","appVersion":"2.0.0","keyFingerprint":"\(key)",\
        "protocolVersions":[1],"capabilities":\(caps),"account":{"subject":"s1"},"pairedAt":"2026-11-20T10:00:00Z","state":"\(state)",\
        "authority":"local-development"\(revoked ? #","revokedAt":"2026-11-24T10:00:00Z""# : "")}
        """
    }

    func devicesJSON(terminalKey: String? = nil, hostKey: String? = nil, extra: [String] = []) -> String {
        let list = [installation(selfId, name: "iPhone", app: "hcg.sentinel", key: otherKey, receive: false),
                    installation(terminalId, name: "Studio Terminal", key: terminalKey ?? self.terminalKey)] + extra
        return """
        {"protocol":"hcg.devicelink/1","host":{"deviceId":"d1","name":"Dev Mac","fingerprint":"\(hostKey ?? serverKey)"},"self":"\(selfId)",\
        "installations":[\(list.joined(separator: ","))],"onlineWindowSeconds":45}
        """
    }

    func devices(_ json: String) throws -> LinkDevices {
        try LinkJSON.decoder().decode(LinkDevices.self, from: Data(json.utf8))
    }

    func receipt(_ messageId: String) -> String {
        #"{"messageId":"\#(messageId)","status":"queued","duplicate":false,"recipientState":"offline","queuedAt":"2026-11-25T10:00:00Z","expiresAt":"2026-12-02T10:00:00Z"}"#
    }

    func header(_ messageId: String, status: String) -> String {
        """
        {"messageId":"\(messageId)","type":"report.share","from":{"installationId":"\(selfId)","name":"iPhone","app":"hcg.sentinel"},\
        "to":{"installationId":"\(terminalId)","name":"Studio Terminal","app":"hcg.terminal"},"title":"t","createdAt":"2026-11-25T10:00:00Z",\
        "queuedAt":"2026-11-25T10:00:00Z","expiresAt":"2026-12-02T10:00:00Z","status":"\(status)","size":100}
        """
    }

    func error(_ code: String, _ message: String) -> String { #"{"error":"\#(message)","code":"\#(code)"}"# }

    func client(_ transport: RoutingTransport) throws -> DeviceLinkClient {
        DeviceLinkClient(configuration: DeviceLinkConfiguration(baseURL: try XCTUnwrap(URL(string: "https://dev-mac.local:7610")),
                                                                serverFingerprint: serverKey, installationId: selfId),
                         signer: SoftwareSigner(), transport: transport, tokens: LocalDevelopmentTokens())
    }

    func service(_ transport: RoutingTransport) throws -> ReportShareService {
        ReportShareService(client: try client(transport), pinnedServerFingerprint: serverKey, audit: audit())
    }

    func audit() -> ShareAuditLog { ShareAuditLog(url: dir.appendingPathComponent("share-audit.json")) }

    let context = ShareRedaction.Context(allowedNames: ["Dev Mac"], sensitiveNames: ["Ana's iPhone", "dev-mac.local"])

    func securityRecord() -> SecurityAssessmentRecord {
        var record = SecurityAssessmentRecord(module: .exposureCheck,
                                              scope: [ScopeItem(kind: .url, value: "https://admin:hunter2@nas.example.com/login?token=abc123")],
                                              location: .thisDevice, permissions: ["network"], startedAt: Date(timeIntervalSince1970: 1_794_650_000),
                                              limits: AssessmentLimits(overallTimeout: 60), limitations: ["Checked from one network."])
        record.status = .completed
        record.endedAt = Date(timeIntervalSince1970: 1_794_650_060)
        record.findings = [SecurityFinding(id: "f1", checkID: "banner", title: "Version banner exposed", severity: .medium, confidence: .high,
                                           basis: .verified, location: "https://nas.example.com/",
                                           evidence: ["Server: nginx/1.18.0", "Reached 192.168.1.20 (aa:bb:cc:dd:ee:ff) from Ana's iPhone",
                                                      "Config at /Users/ana/Library/app.conf, user: ana", "Serial number: C02XK0ABJGH5",
                                                      "Host printer.local answered", "Key AKIAABCDEFGHIJKLMNOP in a file",
                                                      "Authorization: Bearer abcdefghijklmnop123456"],
                                           explanation: "The banner reveals the version.", remediation: "Hide the version.")]
        return record
    }

    func payload(deviceName: String = "iPhone") -> SharePayload {
        SharePayload.prepare(context: context) { r in
            SentinelReportSharing.report(from: securityRecord(), installationId: selfId, appVersion: "1.4.0", deviceName: deviceName, redaction: r)
        }
    }

    func destination() throws -> ShareDestination {
        try XCTUnwrap(ShareDestinationCheck.eligible(try devices(devicesJSON()), pinnedServerFingerprint: serverKey).first)
    }

    // MARK: redaction and strict check

    func testRedactionRemovesSensitiveHostInformationAndCountsEachRule() throws {
        let p = payload()
        XCTAssertTrue(p.isSendable, "blockers: \(p.blockers)")
        let text = p.text
        for leaked in ["hunter2", "abc123", "abcdefghijklmnop123456", "nas.example.com", "192.168.1.20", "aa:bb:cc:dd:ee:ff", "Ana's iPhone", "/Users/ana", "user: ana",
                       "C02XK0ABJGH5", "printer.local", "AKIAABCDEFGHIJKLMNOP"] {
            XCTAssertFalse(text.contains(leaked), "\(leaked) must not be in the payload")
        }
        XCTAssertTrue(text.contains("nginx/1.18.0"), "non-sensitive evidence is kept")
        let rules = Dictionary(uniqueKeysWithValues: p.redactions.map { ($0.rule, $0.count) })
        XCTAssertEqual(rules[ShareRedaction.Rule.ipAddresses.rawValue], 1)
        XCTAssertEqual(rules[ShareRedaction.Rule.macAddresses.rawValue], 1)
        XCTAssertEqual(rules[ShareRedaction.Rule.knownNames.rawValue], 1)
        XCTAssertEqual(rules[ShareRedaction.Rule.homePaths.rawValue], 1)
        XCTAssertEqual(rules[ShareRedaction.Rule.serialNumbers.rawValue], 1)
        XCTAssertEqual(rules[ShareRedaction.Rule.tokens.rawValue], 1)
        XCTAssertGreaterThanOrEqual(rules[ShareRedaction.Rule.hostNames.rawValue] ?? 0, 3)
        XCTAssertGreaterThanOrEqual(rules[ShareRedaction.Rule.userNames.rawValue] ?? 0, 1)
        XCTAssertGreaterThanOrEqual(rules[ShareRedaction.Rule.sentinelCredentials.rawValue] ?? 0, 1)
        XCTAssertEqual(p.sha256, LinkCrypto.sha256Hex(p.bytes))
        XCTAssertEqual(p.size, p.bytes.count)
    }

    func testServerDisplayNameIsTheOnlyHostNameAllowed() throws {
        let json = """
        {"generatedAt":"2026-11-25T10:00:00Z","server":{"available":true,"agentVersion":"0.9.0","startedAt":"2026-11-24T08:00:00Z","uptimeSeconds":93600,"authority":"local-development"},\
        "tls":{"deviceApi":"TLS 1.3, server key pinned by the app","serverKeySha256":"\(serverKey)","gatewayRunning":true,"gatewayExposure":"loopback","gatewayCaSha256":"\(otherKey)"},\
        "services":[{"id":"system-tester","productId":"hcg.system-tester","name":"HCG System Tester","version":"0.1.0","runtime":"native-process","status":"unhealthy","health":"failing","detail":"health check http://127.0.0.1:7700/health on dev-mac.example.com failed","restarts":3,"capabilities":[],"gatewayPublished":true,"openable":false}],\
        "securityEvents":[{"time":"2026-11-25T09:59:00Z","severity":"warning","message":"Rejected a request from [address]"}],"failedAuthentications24h":2,\
        "summary":["HCG Server 0.9.0 is available (up 26h0m0s)."]}
        """
        let d = try LinkJSON.decoder().decode(LinkDiagnostics.self, from: Data(json.utf8))
        let p = SharePayload.prepare(context: ShareRedaction.Context(allowedNames: ["dev-mac.example.com"], sensitiveNames: [])) { r in
            SentinelReportSharing.report(from: d, serverName: "dev-mac.example.com", installationId: selfId, appVersion: "1.4.0", deviceName: "iPhone",
                                         redaction: r)
        }
        XCTAssertTrue(p.isSendable, "blockers: \(p.blockers)")
        XCTAssertTrue(p.text.contains("HCG Server health — dev-mac.example.com"))
    }

    func testSensitiveContentLeftInThePayloadBlocksSending() async throws {
        // The origin's device name is not a redacted field: a personal name there must block the share.
        let p = payload(deviceName: "Ana's iPhone")
        XCTAssertFalse(p.isSendable)
        XCTAssertTrue(p.blockers.contains { $0.contains("Personal device name") }, "\(p.blockers)")
        XCTAssertTrue(p.blockers.contains { $0.contains("This device's name") }, "\(p.blockers)")

        let transport = RoutingTransport()
        let s = try service(transport)
        let result = await s.send(p, to: try destination())
        guard case .refused(let why) = result else { return XCTFail("expected refusal, got \(result)") }
        XCTAssertTrue(why.contains("sensitive content"))
        XCTAssertTrue(transport.requests.isEmpty, "nothing may reach the network")
        XCTAssertEqual(s.audit.entries().first?.outcome, .failed)
    }

    func testStrictCheckFindsWhatRedactionDidNot() {
        let bytes = Data(#"{"a":"Logged in from 10.0.0.7, key ghp_abcdefghijklmnopqrstuvwxyz0123456789, path C:\\Users\\bob\\x, -----BEGIN RSA PRIVATE KEY-----"}"#.utf8)
        let found = Set(SensitiveContentCheck.findings(in: bytes, context: .init()).map(\.category))
        XCTAssertTrue(found.isSuperset(of: ["IP address", "API key or access token", "Home folder path or user name", "Private key"]), "\(found)")
        XCTAssertEqual(SensitiveContentCheck.findings(in: Data(#"{"a":"HCG Server 0.9.0 on Dev Mac, nginx/1.18.0, created 2026-11-25T10:00:00Z"}"#.utf8),
                                                      context: .init(allowedNames: ["Dev Mac"])), [])
    }

    // MARK: preview = payload

    func testTheSentBytesAreExactlyThePreviewedBytes() async throws {
        let p = payload()
        let transport = RoutingTransport()
        transport.route("GET", "/devices", 200, devicesJSON())
        let messageId = LinkCrypto.uuid()
        transport.route("POST", "/messages", 200, receipt(messageId))
        let s = try service(transport)
        let result = await s.send(p, to: try destination(), messageId: messageId)
        XCTAssertEqual(result, .sent(messageId: messageId, recipientState: "offline", expiresAt: try XCTUnwrap(LinkJSON.parseDate("2026-12-02T10:00:00Z"))))

        let post = try XCTUnwrap(transport.requests.first { $0.method == "POST" && $0.url.path.hasSuffix("/messages") })
        XCTAssertNotNil(post.body.range(of: p.bytes), "the previewed bytes are sent verbatim inside the envelope")
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: post.body) as? [String: Any])
        XCTAssertEqual(Set(envelope.keys), ["messageId", "type", "to", "createdAt", "expiresAt", "report"])
        XCTAssertEqual(envelope["to"] as? String, terminalId)
        let sentReport = try JSONSerialization.data(withJSONObject: try XCTUnwrap(envelope["report"]), options: [.sortedKeys])
        let previewReport = try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: p.bytes), options: [.sortedKeys])
        XCTAssertEqual(sentReport, previewReport)
        // The destination was re-checked right before sending.
        XCTAssertEqual(transport.requests.map { $0.method + " " + ($0.url.path.components(separatedBy: "/link").last ?? "") },
                       ["GET /devices", "POST /messages"])
    }

    func testAChangedPayloadIsRefused() async throws {
        let p = payload()
        var tampered = p.report
        tampered.title = "Something else"
        let changed = SharePayload(report: tampered, redactions: p.redactions, context: context)
        XCTAssertNotEqual(changed.sha256, p.sha256)
        XCTAssertTrue(p.isIntact)
    }

    // MARK: destination

    func testOnlyApprovedNonRevokedReceiversOfThePinnedServerAreEligible() throws {
        let extra = [installation("22222222-2222-4333-8444-555555555555", name: "Old Nexus", app: "hcg.nexus", key: otherKey, state: "revoked", revoked: true),
                     installation("33333333-2222-4333-8444-555555555555", name: "Sender only", key: otherKey, receive: false)]
        let list = try devices(devicesJSON(extra: extra))
        let eligible = ShareDestinationCheck.eligible(list, pinnedServerFingerprint: serverKey)
        XCTAssertEqual(eligible.map(\.name), ["Studio Terminal"])
        XCTAssertEqual(eligible.first?.keyFingerprint, terminalKey)
        XCTAssertEqual(eligible.first?.serverName, "Dev Mac")
        XCTAssertEqual(eligible.first?.serverFingerprint, serverKey)
        // A list from another server: nobody.
        XCTAssertEqual(ShareDestinationCheck.eligible(try devices(devicesJSON(hostKey: otherKey)), pinnedServerFingerprint: serverKey), [])
    }

    func testAChangedDestinationKeyIsRefusedBeforeSending() async throws {
        let selected = try destination()
        let transport = RoutingTransport()
        transport.route("GET", "/devices", 200, devicesJSON(terminalKey: otherKey))
        transport.route("POST", "/messages", 200, receipt(LinkCrypto.uuid()))
        let s = try service(transport)
        let result = await s.send(payload(), to: selected)
        guard case .refused(let why) = result else { return XCTFail("expected refusal, got \(result)") }
        XCTAssertTrue(why.contains("key changed"), why)
        XCTAssertFalse(transport.requests.contains { $0.method == "POST" }, "nothing may be sent")
        let entry = try XCTUnwrap(s.audit.entries().first)
        XCTAssertEqual(entry.outcome, .failed)
        XCTAssertEqual(entry.destinationFingerprint, terminalKey)
        XCTAssertTrue(entry.detail?.contains("key changed") ?? false)

        XCTAssertEqual(ShareDestinationCheck.verify(selected, against: try devices(devicesJSON()), pinnedServerFingerprint: serverKey).map(\.keyFingerprint),
                       .success(terminalKey))
        let revoked = try devices(devicesJSON().replacingOccurrences(of: "\"Studio Terminal\"", with: "\"Studio Terminal\",\"revokedAt\":\"2026-11-25T09:00:00Z\""))
        XCTAssertEqual(ShareDestinationCheck.verify(selected, against: revoked, pinnedServerFingerprint: serverKey).map(\.name), .failure(.revoked))
        let gone = try devices(devicesJSON().replacingOccurrences(of: terminalId, with: "44444444-2222-4333-8444-555555555555"))
        XCTAssertEqual(ShareDestinationCheck.verify(selected, against: gone, pinnedServerFingerprint: serverKey).map(\.name), .failure(.notListed))
    }

    // MARK: audit and cancel

    func testCancelSendsNothingAndTheHistoryHoldsNoReportContent() async throws {
        let p = payload()
        let transport = RoutingTransport()
        transport.route("GET", "/devices", 200, devicesJSON())
        let messageId = LinkCrypto.uuid()
        transport.route("POST", "/messages", 200, receipt(messageId))
        let s = try service(transport)

        ReportShareService.cancel(p, destination: try destination(), audit: s.audit)
        XCTAssertTrue(transport.requests.isEmpty, "cancelling makes no network call")
        _ = await s.send(p, to: try destination(), messageId: messageId)

        let entries = s.audit.entries()
        XCTAssertEqual(entries.map(\.outcome), [.sent, .cancelledBeforeSend])
        let sent = entries[0]
        XCTAssertEqual(sent.payloadSha256, p.sha256)
        XCTAssertEqual(sent.payloadSize, p.size)
        XCTAssertEqual(sent.reportTitle, p.title)
        XCTAssertEqual(sent.reportKind, "security-lab.exposure-check")
        XCTAssertEqual(sent.destinationName, "Studio Terminal")
        XCTAssertEqual(sent.destinationFingerprint, terminalKey)
        XCTAssertEqual(sent.messageId, messageId)
        XCTAssertNil(entries[1].messageId)

        let stored = String(decoding: try Data(contentsOf: dir.appendingPathComponent("share-audit.json")), as: UTF8.self)
        for content in ["nginx", "Version banner exposed", "The banner reveals", "Hide the version", "REDACTED", "Checked from one network"] {
            XCTAssertFalse(stored.contains(content), "the history must not hold report content (\(content))")
        }
        // A new log on the same file reads the same history (persistent).
        XCTAssertEqual(audit().entries(), entries)
    }

    // MARK: withdraw

    func testWithdrawWhileQueued() async throws {
        let messageId = LinkCrypto.uuid()
        let transport = RoutingTransport()
        transport.route("GET", "/devices", 200, devicesJSON())
        transport.route("POST", "/messages", 200, receipt(messageId))
        transport.route("POST", "/withdraw", 200, header(messageId, status: "withdrawn"))
        let s = try service(transport)
        let p = payload()
        _ = await s.send(p, to: try destination(), messageId: messageId)
        let result = await s.withdraw(messageId: messageId)
        XCTAssertEqual(result, .withdrawn)
        let w = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(w.method, "POST")
        XCTAssertTrue(w.url.path.hasSuffix("/messages/\(messageId)/withdraw"))
        let entry = try XCTUnwrap(s.audit.entries().first)
        XCTAssertEqual(entry.action, .withdraw)
        XCTAssertEqual(entry.outcome, .withdrawn)
        XCTAssertEqual(entry.payloadSha256, p.sha256)
        XCTAssertEqual(entry.destinationFingerprint, terminalKey)
    }

    func testWithdrawAfterDownloadSaysAlreadyDelivered() async throws {
        let messageId = LinkCrypto.uuid()
        let transport = RoutingTransport()
        transport.route("POST", "/withdraw", 409, error("already_delivered", "the recipient already downloaded this report; it can no longer be withdrawn"))
        let s = try service(transport)
        let result = await s.withdraw(messageId: messageId, header: try LinkJSON.decoder().decode(LinkMessageHeader.self, from: Data(header(messageId, status: "queued").utf8)))
        XCTAssertEqual(result, .alreadyDelivered)
        let entry = try XCTUnwrap(s.audit.entries().first)
        XCTAssertEqual(entry.outcome, .failed)
        XCTAssertEqual(entry.detail, "already_delivered")
        XCTAssertEqual(entry.destinationName, "Studio Terminal")
    }

    func testWithdrawOfAnUnknownMessageFails() async throws {
        let transport = RoutingTransport()
        transport.route("POST", "/withdraw", 404, error("not_found", "no report with this ID was sent by this installation"))
        let s = try service(transport)
        let result = await s.withdraw(messageId: LinkCrypto.uuid())
        guard case .failed(let why, let e) = result else { return XCTFail("expected failure, got \(result)") }
        XCTAssertEqual(e?.code, "not_found")
        XCTAssertTrue(why.contains("no report"))
    }

    func testAnUnreachableServerIsNotRetriedAutomatically() async throws {
        let transport = RoutingTransport()
        transport.route("GET", "/devices", 200, devicesJSON())
        transport.route("POST", "/messages", 503, #"{"error":"busy","code":"unavailable","retryable":true}"#)
        transport.route("GET", "/outbox", 200, #"{"messages":[]}"#)
        let s = try service(transport)
        let result = await s.send(payload(), to: try destination())
        guard case .failed(let why, _) = result else { return XCTFail("expected failure, got \(result)") }
        XCTAssertTrue(why.contains("Nothing is resent automatically"))
        XCTAssertEqual(transport.requests.filter { $0.method == "POST" }.count, 1)
        XCTAssertEqual(s.audit.entries().first?.outcome, .failed)
    }

    func testRealSecretScanAndNetworkCheckReportsPassTheStrictCheck() throws {
        let project = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("""
        let token = "\(FakeSecrets.github)"
        aws_access_key_id = \(FakeSecrets.awsKeyID)
        DATABASE_URL=postgres://admin:\(FakeSecrets.urlPassword)@db.internal:5432/app
        api_key: "\(FakeSecrets.assigned)"
        \(FakeSecrets.privateKey)
        """.utf8).write(to: project.appendingPathComponent("config.swift"))
        let record = SecretScanner(configuration: SecretScanConfiguration(fingerprintKey: [UInt8](repeating: 7, count: 32)))
            .scan([project], control: AssessmentControl(timeout: 60))
        XCTAssertFalse(record.findings.isEmpty)
        let scan = SharePayload.prepare(context: context) { r in
            SentinelReportSharing.report(from: record, installationId: selfId, appVersion: "1.4.0", deviceName: "iPhone", redaction: r)
        }
        XCTAssertTrue(scan.isSendable, "blockers: \(scan.blockers)")
        for secret in FakeSecrets.all + ["db.internal", "admin"] { XCTAssertFalse(scan.text.contains(secret), "leaked \(secret)") }

        let now = Date(timeIntervalSince1970: 1_794_650_000)
        let net = AssessmentReport(startedAt: now, finishedAt: now.addingTimeInterval(20), findings: [
            AssessmentFinding(id: "dns", step: .dnsResolution, kind: .observation, title: "DNS answered",
                              evidence: ["Resolver answered with 93.184.216.34 via gateway 192.168.1.1 for www.example.com"], observedAt: now,
                              limitations: "", remediation: nil),
        ], completedSteps: 8, totalSteps: 8, cancelled: false)
        let check = SharePayload.prepare(context: context) { r in
            SentinelReportSharing.report(from: net, installationId: selfId, appVersion: "1.4.0", deviceName: "iPhone", redaction: r)
        }
        XCTAssertTrue(check.isSendable, "blockers: \(check.blockers)")
        XCTAssertFalse(check.text.contains("www.example.com"))
    }

    func testAGenericDeviceNameIsNotTreatedAsPersonal() {
        // iOS 16+ reports "iPhone" as the device name; that must not block every share.
        let p = SharePayload.prepare(context: .init(allowedNames: [], sensitiveNames: ["iPhone"])) { r in
            SentinelReportSharing.report(from: securityRecord(), installationId: selfId, appVersion: "1.4.0", deviceName: "iPhone", redaction: r)
        }
        XCTAssertTrue(p.isSendable, "blockers: \(p.blockers)")
        XCTAssertTrue(p.text.contains(#""deviceName":"iPhone""#))
    }

    func testNeutralDeviceName() {
        XCTAssertEqual(SentinelReportSharing.neutralDeviceName(model: "iPhone"), "iPhone")
        XCTAssertEqual(SentinelReportSharing.neutralDeviceName(model: "iPad"), "iPad")
        XCTAssertEqual(SentinelReportSharing.neutralDeviceName(model: "Ana's phone"), "iOS device")
    }
}

/// Answers by method and path suffix and records every request.
final class RoutingTransport: LinkTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [(method: String, suffix: String, status: Int, body: String)] = []
    private var recorded: [LinkHTTPRequest] = []

    func route(_ method: String, _ suffix: String, _ status: Int, _ body: String) {
        lock.lock(); defer { lock.unlock() }
        routes.append((method, suffix, status, body))
    }

    var requests: [LinkHTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func send(_ request: LinkHTTPRequest) async throws -> LinkHTTPResponse { answer(request) }

    private func answer(_ request: LinkHTTPRequest) -> LinkHTTPResponse {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        guard let r = routes.first(where: { $0.method == request.method && request.url.path.hasSuffix($0.suffix) }) else {
            return LinkHTTPResponse(status: 404, headers: [:], body: Data(#"{"error":"no route","code":"not_found"}"#.utf8))
        }
        return LinkHTTPResponse(status: r.status, headers: [:], body: Data(r.body.utf8))
    }
}
