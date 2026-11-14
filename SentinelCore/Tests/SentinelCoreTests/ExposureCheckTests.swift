import XCTest
@testable import SentinelCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MockExposureTransport: ExposureTransport {
    var dns: [String: Result<[String], HTTPProbeFailure>] = [:]
    var routes: [String: HTTPProbeResult] = [:]
    private(set) var sent: [URL] = []
    private(set) var resolved: [String] = []
    var onSend: ((URL) -> Void)?

    func resolve(host: String, timeout: TimeInterval, control: AssessmentControl) -> Result<[String], HTTPProbeFailure> {
        resolved.append(host)
        if let answer = dns[host] { return answer }
        if AddressClassifier.classify(host) != nil { return .success([host]) }
        return .failure(HTTPProbeFailure(kind: .dns, code: -1003, message: "not found"))
    }

    func send(_ request: HTTPProbeRequest, control: AssessmentControl) -> HTTPProbeResult {
        sent.append(request.url)
        onSend?(request.url)
        return routes[request.url.absoluteString] ?? .failure(HTTPProbeFailure(kind: .refused, code: -1004, message: "Could not connect"))
    }
}

final class ExposureCheckTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let html = ["Content-Type": "text/html; charset=utf-8"]
    private let hardened = [
        "Content-Type": "text/html", "Content-Security-Policy": "default-src 'self'; frame-ancestors 'none'",
        "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Strict-Transport-Security": "max-age=31536000",
        "Server": "nginx"
    ]

    private func leaf(_ names: [String], validFor days: Double, startedDaysAgo: Double = 30) -> X509Summary {
        X509Summary(notBefore: now.addingTimeInterval(-startedDaysAgo * 86_400), notAfter: now.addingTimeInterval(days * 86_400),
                    commonName: names.first, dnsNames: names)
    }

    private func trusted(_ headers: [String: String], status: Int = 200, days: Double = 90, host: String = "shop.example.com") -> HTTPProbeResult {
        .response(HTTPProbeResponse(status: status, headers: headers, remoteAddress: "93.184.215.14",
                                    tls: TLSObservation(trustedForHost: true, trustedIgnoringHost: true,
                                                        chainSubjects: [host, "Example CA"], leaf: leaf([host], validFor: days))))
    }

    private func run(_ targets: [(String, Bool)], transport: MockExposureTransport, configure: (inout ExposureCheckConfiguration) -> Void = { _ in },
                     control: AssessmentControl = AssessmentControl(timeout: 60)) throws -> SecurityAssessmentRecord {
        var configuration = ExposureCheckConfiguration()
        configuration.minRequestInterval = 0
        configure(&configuration)
        let scope = try TargetScope.parse(targets.map { (text: $0.0, localNetwork: $0.1) })
        return ExposureCheck(transport: transport, configuration: configuration, now: { self.now }).run(scope: scope, control: control)
    }

    private func outcome(_ record: SecurityAssessmentRecord, _ check: String) -> CheckOutcome? {
        record.checks.first { $0.id.hasPrefix(check + "@") }?.outcome
    }

    // MARK: Results

    func testWellConfiguredServiceHasNoFindings() throws {
        let transport = MockExposureTransport()
        transport.dns["shop.example.com"] = .success(["93.184.215.14"])
        transport.routes["https://shop.example.com/"] = trusted(hardened)
        transport.routes["http://shop.example.com/"] = .response(HTTPProbeResponse(status: 301, headers: ["Location": "https://shop.example.com/"]))
        let record = try run([("https://shop.example.com", false)], transport: transport)
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.checks.count, 6)
        XCTAssertEqual(record.checks.map { $0.outcome }, Array(repeating: .passed, count: 6), "\(record.checks)")
        XCTAssertTrue(record.findings.isEmpty)
        XCTAssertEqual(record.headline, "No findings from these checks")
        XCTAssertEqual(transport.sent.map { $0.absoluteString }, ["https://shop.example.com/", "http://shop.example.com/"])
        XCTAssertEqual(record.workCompleted, record.workTotal)
        XCTAssertEqual(record.module, .exposureCheck)
    }

    func testObservationsAreKeptApartFromVerifiedFindings() throws {
        let transport = MockExposureTransport()
        transport.dns["shop.example.com"] = .success(["93.184.215.14"])
        transport.routes["https://shop.example.com/"] = trusted(html.merging(["Server": "Apache/2.4.58 (Unix)", "X-Powered-By": "PHP/8.1.2"]) { a, _ in a })
        transport.routes["http://shop.example.com/"] = .response(HTTPProbeResponse(status: 200, headers: html))
        let record = try run([("https://shop.example.com/", false)], transport: transport)

        let redirect = try XCTUnwrap(record.findings.first { $0.checkID == "https" })
        XCTAssertEqual(redirect.basis, .verified)
        XCTAssertEqual(redirect.severity, .medium)
        let observations = record.findings.filter { ["hsts", "headers", "disclosure"].contains($0.checkID) }
        XCTAssertEqual(observations.count, 6, "\(record.findings.map { $0.title })")
        XCTAssertTrue(observations.allSatisfy { $0.basis == .observation })
        let disclosure = try XCTUnwrap(record.findings.first { $0.checkID == "disclosure" })
        XCTAssertEqual(disclosure.severity, .info)
        XCTAssertTrue(disclosure.explanation.contains("does not confirm"))
        XCTAssertTrue(disclosure.evidence.contains { $0.contains("Apache/2.4.58") })
        XCTAssertFalse(record.findings.contains { $0.title.lowercased().contains("vulnerab") }, "a banner is never called a vulnerability")
        XCTAssertEqual(outcome(record, "tls"), .passed)
    }

    func testHeaderRelevanceDependsOnContentType() throws {
        let transport = MockExposureTransport()
        transport.dns["api.example.com"] = .success(["93.184.215.14"])
        transport.routes["https://api.example.com/v1"] = trusted(["Content-Type": "application/json", "Strict-Transport-Security": "max-age=600"], host: "api.example.com")
        let record = try run([("https://api.example.com/v1", false)], transport: transport)
        let csp = try XCTUnwrap(record.findings.first { $0.id.hasPrefix("header-csp") })
        XCTAssertEqual(csp.severity, .info)
        XCTAssertEqual(csp.confidence, .medium)
        XCTAssertTrue(csp.explanation.contains("matters less"))
        let nosniff = try XCTUnwrap(record.findings.first { $0.id.hasPrefix("header-nosniff") })
        XCTAssertEqual(nosniff.severity, .low)
        XCTAssertEqual(record.findings.first { $0.checkID == "hsts" }?.title, "Strict-Transport-Security max-age is short")
    }

    // MARK: TLS

    func testUntrustedAndMismatchedCertificatesAreVerifiedFindings() throws {
        let transport = MockExposureTransport()
        transport.dns["shop.example.com"] = .success(["93.184.215.14"])
        transport.routes["https://shop.example.com/"] = .failure(HTTPProbeFailure(
            kind: .tlsUntrusted, code: -1202, message: "The certificate for this server is invalid.",
            tls: TLSObservation(trustedForHost: false, trustedIgnoringHost: true, chainSubjects: ["other.example.net"],
                                leaf: leaf(["other.example.net"], validFor: 60))))
        let record = try run([("https://shop.example.com/", false)], transport: transport)
        let finding = try XCTUnwrap(record.findings.first { $0.checkID == "tls" })
        XCTAssertEqual(finding.title, "Certificate does not match the host name")
        XCTAssertEqual(finding.severity, .high)
        XCTAssertEqual(finding.basis, .verified)
        XCTAssertTrue(finding.evidence.contains { $0.contains("other.example.net") })
        XCTAssertEqual(outcome(record, "reachability"), .inconclusive, "a TLS refusal is not a connectivity failure")
        XCTAssertEqual(outcome(record, "headers"), .failedToExecute)

        transport.routes["https://shop.example.com/"] = .failure(HTTPProbeFailure(
            kind: .tlsUntrusted, code: -1201, message: "expired",
            tls: TLSObservation(trustedForHost: false, trustedIgnoringHost: false, leaf: leaf(["shop.example.com"], validFor: -2, startedDaysAgo: 400))))
        let expired = try run([("https://shop.example.com/", false)], transport: transport)
        XCTAssertEqual(expired.findings.first { $0.checkID == "tls" }?.title, "Certificate expired")

        transport.routes["https://shop.example.com/"] = .failure(HTTPProbeFailure(kind: .tlsUntrusted, code: -1202, message: "SSL peer certificate was not OK"))
        let bare = try run([("https://shop.example.com/", false)], transport: transport)
        XCTAssertEqual(bare.findings.first { $0.checkID == "tls" }?.title, "Certificate not trusted")
    }

    func testCertificateExpiringSoon() throws {
        let transport = MockExposureTransport()
        transport.dns["shop.example.com"] = .success(["93.184.215.14"])
        transport.routes["https://shop.example.com/"] = trusted(hardened, days: 3)
        transport.routes["http://shop.example.com/"] = .response(HTTPProbeResponse(status: 308, headers: ["Location": "https://shop.example.com/"]))
        let record = try run([("https://shop.example.com/", false)], transport: transport)
        let finding = try XCTUnwrap(record.findings.first)
        XCTAssertEqual(finding.title, "Certificate expires soon")
        XCTAssertEqual(finding.severity, .medium)
    }

    func testHTTPOnlyService() throws {
        let transport = MockExposureTransport()
        transport.routes["http://192.168.1.40:8080/"] = .response(HTTPProbeResponse(status: 200, headers: html))
        let record = try run([("http://192.168.1.40:8080/", false)], transport: transport)
        XCTAssertEqual(record.scope.first?.localNetwork, true)
        XCTAssertEqual(record.findings.first { $0.checkID == "https" }?.title, "Service is only available over unencrypted HTTP")
        XCTAssertEqual(outcome(record, "tls"), .unsupported)
        XCTAssertEqual(outcome(record, "hsts"), .unsupported)
        XCTAssertEqual(transport.sent.map { $0.absoluteString }, ["http://192.168.1.40:8080/", "https://192.168.1.40/"])
    }

    // MARK: Scope

    func testRedirectsOutsideScopeAreNeverFollowedOrResolved() throws {
        for location in ["http://169.254.169.254/latest/meta-data/", "https://evil.example.net/steal", "http://app.example.com.evil.net/"] {
            let transport = MockExposureTransport()
            transport.dns["app.example.com"] = .success(["93.184.215.14"])
            transport.routes["http://app.example.com/"] = .response(HTTPProbeResponse(status: 302, headers: ["Location": location]))
            let record = try run([("http://app.example.com/", false)], transport: transport)
            XCTAssertFalse(transport.sent.contains { $0.host != "app.example.com" }, "\(transport.sent)")
            XCTAssertEqual(transport.resolved, ["app.example.com"])
            let reachability = try XCTUnwrap(record.checks.first { $0.id.hasPrefix("reachability@") })
            XCTAssertTrue(reachability.detail.contains("not followed"), reachability.detail)
        }
    }

    func testRedirectsInsideScopeAreFollowedAndBounded() throws {
        let transport = MockExposureTransport()
        transport.dns["app.example.com"] = .success(["93.184.215.14"])
        transport.routes["https://app.example.com/"] = .response(HTTPProbeResponse(status: 302, headers: ["Location": "/login"], remoteAddress: "93.184.215.14"))
        transport.routes["https://app.example.com/login"] = trusted(hardened, host: "app.example.com")
        transport.routes["http://app.example.com/"] = .response(HTTPProbeResponse(status: 301, headers: ["Location": "https://app.example.com/"]))
        let record = try run([("https://app.example.com/", false)], transport: transport)
        XCTAssertTrue(record.findings.isEmpty, "\(record.findings.map { $0.title })")
        XCTAssertEqual(transport.sent.map { $0.path }, ["/", "/login", "/"])

        let loop = MockExposureTransport()
        loop.dns["app.example.com"] = .success(["93.184.215.14"])
        loop.routes["https://app.example.com/"] = .response(HTTPProbeResponse(status: 302, headers: ["Location": "/"]))
        let looped = try run([("https://app.example.com/", false)], transport: loop) { $0.maxRequestsPerTarget = 4; $0.maxRedirects = 10 }
        XCTAssertLessThanOrEqual(loop.sent.count, 4, "the per-target request cap holds even in a redirect loop")
        XCTAssertFalse(looped.errors.isEmpty)
    }

    func testNamesResolvingToLocalOrMetadataAddressesAreBlocked() throws {
        let rebinding = MockExposureTransport()
        rebinding.dns["intranet.example.com"] = .success(["10.0.0.7"])
        let blocked = try run([("https://intranet.example.com/", false)], transport: rebinding)
        XCTAssertTrue(rebinding.sent.isEmpty, "nothing is sent to an address the user did not select")
        XCTAssertEqual(blocked.status, .failedToExecute)
        XCTAssertTrue(blocked.checks.allSatisfy { $0.outcome == .unsupported })
        XCTAssertTrue(blocked.errors.contains { $0.contains("did not mark it as a local-network target") })
        XCTAssertTrue(blocked.findings.isEmpty, "a scope block is not a finding about the target")

        let allowed = MockExposureTransport()
        allowed.dns["intranet.example.com"] = .success(["10.0.0.7"])
        _ = try run([("https://intranet.example.com/", true)], transport: allowed)
        XCTAssertFalse(allowed.sent.isEmpty, "explicitly selected local targets are allowed")

        let metadata = MockExposureTransport()
        metadata.dns["nas.example.com"] = .success(["169.254.169.254"])
        _ = try run([("https://nas.example.com/", true)], transport: metadata)
        XCTAssertTrue(metadata.sent.isEmpty, "metadata addresses are blocked even for local targets")
    }

    func testResponseFromAnUnexpectedAddressIsDiscarded() throws {
        let transport = MockExposureTransport()
        transport.dns["shop.example.com"] = .success(["93.184.215.14"])
        transport.routes["https://shop.example.com/"] = .response(HTTPProbeResponse(status: 200, headers: html, remoteAddress: "10.9.9.9"))
        let record = try run([("https://shop.example.com/", false)], transport: transport)
        XCTAssertTrue(record.findings.isEmpty, "nothing from the discarded response is evaluated")
        XCTAssertTrue(record.errors.contains { $0.contains("reached 10.9.9.9") }, "\(record.errors)")
    }

    // MARK: Failures, limits, cancellation

    func testConnectivityFailuresAreNotFindings() throws {
        let transport = MockExposureTransport()
        transport.dns["down.example.com"] = .success(["93.184.215.14"])
        transport.routes["https://down.example.com/"] = .failure(HTTPProbeFailure(kind: .timeout, code: -1001, message: "timed out"))
        transport.routes["http://down.example.com/"] = .failure(HTTPProbeFailure(kind: .timeout, code: -1001, message: "timed out"))
        let record = try run([("https://down.example.com/", false)], transport: transport)
        XCTAssertTrue(record.findings.isEmpty)
        XCTAssertEqual(outcome(record, "reachability"), .failedToExecute)
        XCTAssertEqual(outcome(record, "https"), .inconclusive)
        XCTAssertTrue(record.headline.contains("did not reach a result"), record.headline)

        let missing = MockExposureTransport()
        let unresolved = try run([("https://nowhere.example.com/", false)], transport: missing)
        XCTAssertEqual(outcome(unresolved, "reachability"), .failedToExecute)
        XCTAssertTrue(missing.sent.isEmpty)
    }

    func testCancellationStopsTheRun() throws {
        let transport = MockExposureTransport()
        transport.dns["a.example.com"] = .success(["93.184.215.14"])
        transport.dns["b.example.com"] = .success(["93.184.215.15"])
        let control = AssessmentControl(timeout: 60)
        transport.onSend = { _ in control.cancel() }
        let record = try run([("https://a.example.com/", false), ("https://b.example.com/", false)], transport: transport, control: control)
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertTrue(record.notTested.contains { $0.contains("b.example.com") }, "\(record.notTested)")
        XCTAssertTrue(record.headline.hasPrefix("Cancelled"))
    }

    func testPacingBetweenRequests() throws {
        let transport = MockExposureTransport()
        transport.dns["shop.example.com"] = .success(["93.184.215.14"])
        transport.routes["https://shop.example.com/"] = trusted(hardened)
        let started = Date()
        _ = try run([("https://shop.example.com/", false)], transport: transport) { $0.minRequestInterval = 0.3 }
        XCTAssertEqual(transport.sent.count, 2)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
    }

    // MARK: Pieces

    func testCertificateParsingAndNameMatching() throws {
        let der = [UInt8](Data(base64Encoded: "MIIB8jCCAZigAwIBAgIUSn66+dLLmwzTvXaTdfOKPDpKcywwCgYIKoZIzj0EAwIwMjEZMBcGA1UECgwQU2VudGluZWwgRml4dHVyZTEVMBMGA1UEAwwMZXhhbXBsZS50ZXN0MB4XDTI2MTExNDAwNDQwMloXDTI2MTIxNDAwNDQwMlowMjEZMBcGA1UECgwQU2VudGluZWwgRml4dHVyZTEVMBMGA1UEAwwMZXhhbXBsZS50ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE4mvZB3fw99+gY+tpTFXT1kVSmcJx1T/kVrSQxsccPPLvabCn54vyLpeV4ldVy2SeqZmo1sb8R6URiLL8eDnwdaOBizCBiDAdBgNVHQ4EFgQUb6y4F2+9Jgbx7+qaDD3Sn3IExYYwHwYDVR0jBBgwFoAUb6y4F2+9Jgbx7+qaDD3Sn3IExYYwDwYDVR0TAQH/BAUwAwEB/zA1BgNVHREELjAsghB3d3cuZXhhbXBsZS50ZXN0ghIqLmFwaS5leGFtcGxlLnRlc3SHBMAAAgowCgYIKoZIzj0EAwIDSAAwRQIhAO5+YSWP4eKhxwW3u0qyBrNF+6Kk5OjgkI9gDA4vIjIdAiB9RAZII4I27/R4DlbJ1hL7TfCycgPCf34Qf/8tGqBKHA==")!)
        let summary = try XCTUnwrap(X509Summary.parse(der: der))
        XCTAssertEqual(summary.notBefore, Date(timeIntervalSince1970: 1_794_617_042))
        XCTAssertEqual(summary.notAfter, Date(timeIntervalSince1970: 1_797_209_042))
        XCTAssertEqual(summary.commonName, "example.test")
        XCTAssertEqual(summary.dnsNames, ["www.example.test", "*.api.example.test"])
        XCTAssertTrue(summary.matches(host: "www.example.test"))
        XCTAssertTrue(summary.matches(host: "WWW.Example.Test."))
        XCTAssertTrue(summary.matches(host: "v1.api.example.test"))
        XCTAssertFalse(summary.matches(host: "a.b.api.example.test"))
        XCTAssertFalse(summary.matches(host: "api.example.test"))
        XCTAssertFalse(summary.matches(host: "example.test"), "the common name is ignored when DNS names are present")

        let legacy = [UInt8](Data(base64Encoded: "MIIBkTCCATegAwIBAgIURiVy+PU1TobPLFSFftiQb2IKu8gwCgYIKoZIzj0EAwIwHjEcMBoGA1UEAwwTbGVnYWN5LmV4YW1wbGUudGVzdDAeFw0yNjExMTQwMDQ0MDJaFw0yNjExMTUwMDQ0MDJaMB4xHDAaBgNVBAMME2xlZ2FjeS5leGFtcGxlLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASdmxTc9Y1GjS73aD3uwZwbgKhmlWV9ktsd3zRb+drvM7uh/aRGapn2ebZE/tr2kwL73V6XS/W4+2EZyBE1aXVjo1MwUTAdBgNVHQ4EFgQUSGTuGGpTe7LyUbHVq5V/tkAtbKAwHwYDVR0jBBgwFoAUSGTuGGpTe7LyUbHVq5V/tkAtbKAwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiAxXi0KzwGk8SQMISIMG8njhvYYNnZeaWyga2KkEt3gvwIhAJaFMApki5BRF9KiaRrLxkuMp8mfTb+r5aPDYznRCnwL")!)
        let cnOnly = try XCTUnwrap(X509Summary.parse(der: legacy))
        XCTAssertTrue(cnOnly.dnsNames.isEmpty)
        XCTAssertTrue(cnOnly.matches(host: "legacy.example.test"))
        XCTAssertFalse(X509Summary.nameMatches(pattern: "*.com", host: "example.com"), "no wildcard on a single-label suffix")
        XCTAssertFalse(X509Summary.nameMatches(pattern: "*.example.test", host: "192.0.2.1"))

        XCTAssertNil(X509Summary.parse(der: []))
        XCTAssertNil(X509Summary.parse(der: Array(der.prefix(60))))
        for _ in 0..<200 {
            var mutated = der
            mutated[Int.random(in: 0..<mutated.count)] = UInt8.random(in: 0...255)
            _ = X509Summary.parse(der: mutated)
        }
    }

    func testFailureClassification() {
        XCTAssertEqual(HTTPProbeFailure.classify(code: -1202, message: "x").kind, .tlsUntrusted)
        XCTAssertEqual(HTTPProbeFailure.classify(code: -1001, message: "x").kind, .timeout)
        XCTAssertEqual(HTTPProbeFailure.classify(code: -1004, message: "Could not connect to the server.").kind, .refused)
        XCTAssertEqual(HTTPProbeFailure.classify(code: -1003, message: "x").kind, .dns)
        XCTAssertEqual(HTTPProbeFailure.classify(code: -1, message: "SSL peer certificate or SSH remote key was not OK").kind, .tlsUntrusted)
        XCTAssertEqual(HTTPProbeFailure.classify(code: -999, message: "cancelled").kind, .cancelled)
    }
}

/// Runs the real URLSession transport against Tools/exposure_test_service.py. CI provides the URLs:
///   SENTINEL_EXPOSURE_HTTP=http://127.0.0.1:8081  SENTINEL_EXPOSURE_HTTPS=https://127.0.0.1:8444
final class ExposureCheckLiveTests: XCTestCase {
    private var http = ""
    private var https = ""

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let http = environment["SENTINEL_EXPOSURE_HTTP"], let https = environment["SENTINEL_EXPOSURE_HTTPS"] else {
            throw XCTSkip("Start Tools/exposure_test_service.py and set SENTINEL_EXPOSURE_HTTP and SENTINEL_EXPOSURE_HTTPS.")
        }
        self.http = http
        self.https = https
    }

    final class SpyTransport: ExposureTransport {
        let inner = FoundationExposureTransport()
        private(set) var sent: [URL] = []
        func resolve(host: String, timeout: TimeInterval, control: AssessmentControl) -> Result<[String], HTTPProbeFailure> {
            inner.resolve(host: host, timeout: timeout, control: control)
        }
        func send(_ request: HTTPProbeRequest, control: AssessmentControl) -> HTTPProbeResult {
            sent.append(request.url)
            return inner.send(request, control: control)
        }
    }

    private func run(_ url: String, transport: ExposureTransport, timeout: TimeInterval = 5,
                     control: AssessmentControl = AssessmentControl(timeout: 60)) throws -> SecurityAssessmentRecord {
        var configuration = ExposureCheckConfiguration()
        configuration.minRequestInterval = 0.1
        configuration.requestTimeout = timeout
        let scope = try TargetScope.parse([(text: url, localNetwork: false)])
        let record = ExposureCheck(transport: transport, configuration: configuration).run(scope: scope, control: control)
        print("EXPOSURE-CHECK \(url): \(record.headline)")
        for check in record.checks { print("EXPOSURE-CHECK   [\(check.outcome.rawValue)] \(check.title): \(check.detail)") }
        for finding in record.findings { print("EXPOSURE-CHECK   finding (\(finding.severity.rawValue)/\(finding.confidence.rawValue)/\(finding.basis.rawValue)) \(finding.title)") }
        return record
    }

    private func outcome(_ record: SecurityAssessmentRecord, _ check: String) -> CheckOutcome? {
        record.checks.first { $0.id.hasPrefix(check + "@") }?.outcome
    }

    func testPlainHTTPServiceAgainstTheLocalService() throws {
        let record = try run("\(http)/plain", transport: FoundationExposureTransport())
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(outcome(record, "reachability"), .passed)
        XCTAssertEqual(outcome(record, "headers"), .finding)
        XCTAssertEqual(outcome(record, "disclosure"), .finding)
        XCTAssertTrue(record.findings.contains { $0.checkID == "disclosure" && $0.evidence.joined().contains("HCGTestServer/1.2.3") })
        XCTAssertEqual(outcome(record, "hsts"), .unsupported)
        XCTAssertEqual(record.findings.first { $0.checkID == "https" }?.title, "Service is only available over unencrypted HTTP")
    }

    func testSelfSignedCertificateIsReportedNotBypassed() throws {
        let record = try run("\(https)/hardened", transport: FoundationExposureTransport())
        let tls = try XCTUnwrap(record.findings.first { $0.checkID == "tls" }, "\(record.checks)")
        XCTAssertEqual(tls.severity, .high)
        XCTAssertEqual(tls.basis, .verified)
        XCTAssertTrue(tls.title.hasPrefix("Certificate not trusted"), tls.title)
        XCTAssertEqual(outcome(record, "headers"), .failedToExecute, "nothing is read over a connection that failed validation")
        #if canImport(Darwin)
        XCTAssertTrue(tls.evidence.joined().contains("sentinel-test.invalid"), "\(tls.evidence)")
        #endif
    }

    func testMetadataRedirectIsNeverRequested() throws {
        let spy = SpyTransport()
        let record = try run("\(http)/redirect-metadata", transport: spy)
        XCTAssertFalse(spy.sent.contains { $0.host == "169.254.169.254" })
        XCTAssertTrue(record.checks.contains { $0.detail.contains("not followed") })
    }

    func testTimeoutAndCancellation() throws {
        let started = Date()
        let slow = try run("\(http)/slow", transport: FoundationExposureTransport(), timeout: 1)
        XCTAssertEqual(outcome(slow, "reachability"), .failedToExecute)
        XCTAssertTrue(slow.findings.filter { $0.checkID != "https" }.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)

        let control = AssessmentControl(timeout: 60)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { control.cancel() }
        let cancelStarted = Date()
        let cancelled = try run("\(http)/slow", transport: FoundationExposureTransport(), timeout: 10, control: control)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(cancelStarted), 3, "cancel aborts the request in flight")
    }

    func testResponseBodyIsCapped() throws {
        let transport = FoundationExposureTransport()
        let result = transport.send(HTTPProbeRequest(url: URL(string: "\(http)/big")!, timeout: 5, maxBodyBytes: 4096),
                                    control: AssessmentControl(timeout: 30))
        guard case .response(let response) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.bodyPrefix.count, 4096)
        XCTAssertTrue(response.bodyTruncated)
    }
}
