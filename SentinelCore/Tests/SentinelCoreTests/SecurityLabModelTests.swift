import XCTest
@testable import SentinelCore

final class SecurityLabModelTests: XCTestCase {
    private func sampleRecord(status: AssessmentRunStatus = .completed) -> SecurityAssessmentRecord {
        var record = SecurityAssessmentRecord(module: .exposureCheck,
                                              scope: [ScopeItem(kind: .url, value: "https://user:hunter2@example.test/login?token=abc123")],
                                              location: .thisDevice, permissions: ["Contact the entered URL"],
                                              startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                              limits: AssessmentLimits(maxRequests: 5, requestTimeout: 10, overallTimeout: 60),
                                              limitations: ["Example limitation"])
        record.status = status
        record.endedAt = record.startedAt.addingTimeInterval(3)
        return record
    }

    // MARK: Outcomes and headlines

    func testHeadlineNeverCallsAnythingSafeOrSecure() {
        let statuses: [AssessmentRunStatus] = [.running, .completed, .cancelled, .timedOut, .failedToExecute, .unsupported]
        for status in statuses {
            for checks in [[], [CheckResult(id: "a", title: "A", outcome: .passed, detail: "")],
                           [CheckResult(id: "b", title: "B", outcome: .unsupported, detail: "")]] {
                var record = sampleRecord(status: status)
                record.checks = checks
                let headline = record.headline.lowercased()
                XCTAssertFalse(headline.contains("safe"), headline)
                XCTAssertFalse(headline.contains("secure"), headline)
            }
        }
    }

    func testUnavailableChecksAreNotReportedAsClean() {
        var record = sampleRecord()
        record.checks = [CheckResult(id: "tls", title: "TLS", outcome: .unsupported, detail: "No HTTPS"),
                         CheckResult(id: "status", title: "Status", outcome: .failedToExecute, detail: "Timed out")]
        XCTAssertEqual(record.headline, "No findings, but 2 checks did not reach a result")
        XCTAssertEqual(record.count(.passed), 0)
        record.status = .unsupported
        XCTAssertTrue(record.headline.hasPrefix("Not run"))
    }

    func testSeverityAndConfidenceAreIndependent() {
        let finding = SecurityFinding(id: "x", checkID: "x", title: "X", severity: .critical, confidence: .low, basis: .observation,
                                      evidence: ["e"], explanation: "e", remediation: "r")
        XCTAssertEqual(finding.severity, .critical)
        XCTAssertEqual(finding.confidence, .low)
        XCTAssertTrue(FindingSeverity.high > FindingSeverity.medium)
    }

    // MARK: Redaction and export

    func testScopeAndExportAreRedacted() throws {
        var record = sampleRecord()
        record.findings = [SecurityFinding(id: "f", checkID: "c", title: "Header", severity: .low, confidence: .high, basis: .observation,
                                           evidence: ["Authorization: Bearer abcdef123456", "password=hunter2"],
                                           explanation: "x", remediation: "Fix it.")]
        XCTAssertFalse(record.scope[0].value.contains("hunter2"))
        XCTAssertFalse(record.scope[0].value.contains("abc123"))
        let text = SecurityReportRenderer.text(record)
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("abcdef123456"))
        XCTAssertTrue(text.contains("[REDACTED]"))
        XCTAssertTrue(text.contains("## Scope"))
        XCTAssertTrue(text.contains("## Not tested"))
        XCTAssertTrue(text.contains("## Limitations"))
        XCTAssertTrue(text.contains("Fix it."))
        XCTAssertTrue(text.contains("Severity: Low · Confidence: High · Observation"))
    }

    func testReportStoreRoundTripListDeleteAndPrune() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SecurityReportStore(directory: directory, maxReports: 3)
        var records: [SecurityAssessmentRecord] = []
        for offset in 0..<5 {
            var record = sampleRecord()
            record.startedAt = Date(timeIntervalSince1970: 1_800_000_000 + Double(offset))
            records.append(record)
            try store.save(record)
        }
        let listed = store.list()
        XCTAssertEqual(listed.count, 3, "oldest reports are pruned")
        XCTAssertEqual(listed.first?.id, records[4].id, "newest first")
        XCTAssertEqual(store.load(records[4].id), records[4])
        XCTAssertNil(store.load(records[0].id))
        store.delete(records[4].id)
        XCTAssertNil(store.load(records[4].id))
        store.deleteAll()
        XCTAssertTrue(store.list().isEmpty)
    }

    // MARK: Integration surfaces

    func testReportDeepLinksOpenReviewOnly() {
        let id = UUID()
        let link = DeepLink.url(forReport: id)
        XCTAssertEqual(DeepLink.target(from: link), .report(id))
        XCTAssertEqual(DeepLink.target(from: URL(string: "hcgsentinel://open/securityLab")!), .section(.securityLab))
        for bad in ["hcgsentinel://report/\(id.uuidString)?run=1", "hcgsentinel://report/not-a-uuid",
                    "hcgsentinel://report/\(id.uuidString)/extra", "hcgsentinel://run/\(id.uuidString)",
                    "hcgsentinel://report/\(id.uuidString)#start", "https://report/\(id.uuidString)"] {
            XCTAssertNil(DeepLink.target(from: URL(string: bad)!), bad)
        }
    }

    func testStatusSnapshotCarriesReferencesButNoReportContents() throws {
        var record = sampleRecord()
        record.findings = [SecurityFinding(id: "f", checkID: "c", title: "Very specific finding title", severity: .high, confidence: .high,
                                           basis: .verified, location: "https://example.test/admin", evidence: ["evidence-marker"],
                                           explanation: "x", remediation: "y")]
        let snapshot = NexusStatusSnapshot(generatedAt: Date(), activeOperations: [], verifiedCapabilities: 1, totalCapabilities: 2,
                                           previewMode: false, recentAssessments: [record.reference])
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertTrue(json.contains(record.id.uuidString))
        XCTAssertTrue(json.contains("\"findingCount\":1"))
        for leaked in ["Very specific finding title", "example.test", "evidence-marker"] {
            XCTAssertFalse(json.contains(leaked), leaked)
        }
        XCTAssertEqual(record.reference.link, DeepLink.url(forReport: record.id))
    }

    // MARK: Control

    func testControlCancellationAndDeadline() {
        let control = AssessmentControl(timeout: 60)
        XCTAssertNoThrow(try control.check())
        var fired = 0
        control.whenCancelled { fired += 1 }
        control.cancel()
        control.cancel()
        XCTAssertEqual(fired, 1)
        XCTAssertThrowsError(try control.check()) { XCTAssertEqual($0 as? AssessmentControl.Stop, .cancelled) }
        control.whenCancelled { fired += 1 }
        XCTAssertEqual(fired, 2, "late handlers run at once")
        XCTAssertFalse(control.pause(5), "pause returns at once when cancelled")

        let expired = AssessmentControl(timeout: 0)
        XCTAssertThrowsError(try expired.check()) { XCTAssertEqual($0 as? AssessmentControl.Stop, .timedOut) }
    }

    func testProgressFraction() {
        XCTAssertNil(AssessmentProgress(completed: 0, total: 0, current: "").fraction)
        XCTAssertEqual(AssessmentProgress(completed: 3, total: 4, current: "").fraction, 0.75)
        XCTAssertEqual(AssessmentProgress(completed: 9, total: 4, current: "").fraction, 1)
    }
}

final class ScopePolicyTests: XCTestCase {
    func testAddressClassification() {
        let cases: [(String, AddressClass)] = [
            ("127.0.0.1", .loopback), ("10.1.2.3", .privateNetwork), ("172.16.0.1", .privateNetwork), ("172.32.0.1", .publicInternet),
            ("192.168.1.10", .privateNetwork), ("100.64.0.1", .privateNetwork), ("169.254.169.254", .cloudMetadata),
            ("169.254.10.10", .linkLocal), ("100.100.100.200", .cloudMetadata), ("0.0.0.0", .unspecified),
            ("224.0.0.1", .multicast), ("93.184.215.14", .publicInternet), ("::1", .loopback), ("::", .unspecified),
            ("fe80::1", .linkLocal), ("fd12:3456::1", .privateNetwork), ("fd00:ec2::254", .cloudMetadata),
            ("::ffff:169.254.169.254", .cloudMetadata), ("::ffff:127.0.0.1", .loopback), ("64:ff9b::a9fe:a9fe", .cloudMetadata),
            ("2606:2800:220:1::1", .publicInternet), ("[::1]", .loopback)
        ]
        for (address, expected) in cases {
            XCTAssertEqual(AddressClassifier.classify(address), expected, address)
        }
        XCTAssertNil(AddressClassifier.classify("example.com"))
        // Ambiguous IPv4 spellings are not treated as addresses, so they can't sneak past the classifier.
        for odd in ["0177.0.0.1", "127.1", "0x7f.0.0.1", "1.2.3.256"] {
            XCTAssertNil(AddressClassifier.parseIPv4(odd), odd)
        }
    }

    func testParsingRejectsMetadataCredentialsAndOtherSchemes() {
        XCTAssertThrowsError(try TargetScope.parseTarget("http://169.254.169.254/latest/meta-data/", localNetwork: true))
        XCTAssertThrowsError(try TargetScope.parseTarget("http://metadata.google.internal/", localNetwork: true))
        XCTAssertThrowsError(try TargetScope.parseTarget("http://[fd00:ec2::254]/", localNetwork: true))
        XCTAssertThrowsError(try TargetScope.parseTarget("http://169.254.1.1/", localNetwork: true))
        XCTAssertThrowsError(try TargetScope.parseTarget("https://admin:pw@example.com/", localNetwork: false)) {
            XCTAssertEqual($0 as? ScopeError, .credentialsInURL)
        }
        XCTAssertThrowsError(try TargetScope.parseTarget("ftp://example.com/", localNetwork: false))
        XCTAssertThrowsError(try TargetScope.parseTarget("example.com", localNetwork: false))
        XCTAssertThrowsError(try TargetScope.parse(Array(repeating: (text: "https://example.com/", localNetwork: false), count: 6)
                                                    .enumerated().map { (text: $0.element.text + "\($0.offset)", localNetwork: false) }))
    }

    func testLocalTargetsNeedExplicitSelection() throws {
        let literal = try TargetScope.parseTarget("http://192.168.1.20:8080/", localNetwork: false)
        XCTAssertTrue(literal.localNetwork, "a literal private address is an explicit local selection")
        let named = try TargetScope.parseTarget("https://router.example.com/", localNetwork: false)
        XCTAssertFalse(named.localNetwork)
        let scope = TargetScope(targets: [named])
        XCTAssertThrowsError(try scope.validate(resolved: ["93.184.215.14", "10.0.0.5"], for: named)) {
            XCTAssertEqual($0 as? ScopeError, .localNotSelected(host: "router.example.com", address: "10.0.0.5"))
        }
        XCTAssertNoThrow(try scope.validate(resolved: ["93.184.215.14"], for: named))

        let flagged = try TargetScope.parseTarget("https://nas.example.com/", localNetwork: true)
        let local = TargetScope(targets: [flagged])
        XCTAssertNoThrow(try local.validate(resolved: ["192.168.1.30"], for: flagged))
        XCTAssertThrowsError(try local.validate(resolved: ["169.254.169.254"], for: flagged), "metadata is blocked even for local targets")
        XCTAssertThrowsError(try local.validate(resolved: [], for: flagged))
        XCTAssertThrowsError(try local.validate(connectedAddress: "169.254.169.254", for: flagged)) {
            XCTAssertEqual($0 as? ScopeError, .connectedElsewhere(host: "nas.example.com", address: "169.254.169.254"))
        }
    }

    func testRedirectsStayOnEnteredHosts() throws {
        let scope = try TargetScope.parse([(text: "http://app.example.com/", localNetwork: false)])
        XCTAssertNotNil(scope.target(for: URL(string: "https://app.example.com/login")!), "http→https on the same host")
        XCTAssertNotNil(scope.target(for: URL(string: "https://APP.example.com./")!))
        XCTAssertNil(scope.target(for: URL(string: "https://evil.example.net/")!))
        XCTAssertNil(scope.target(for: URL(string: "https://app.example.com.evil.net/")!))
        XCTAssertNil(scope.target(for: URL(string: "http://169.254.169.254/")!))
        XCTAssertNil(scope.target(for: URL(string: "https://user:pw@app.example.com/")!))
        XCTAssertNil(scope.target(for: URL(string: "https://app.example.com:8443/")!), "other ports are not in scope")
        XCTAssertNil(scope.target(for: URL(string: "file:///etc/passwd")!))
    }
}

final class InflateAndArchiveTests: XCTestCase {
    func testInflateDecodesStoredFixedAndDynamicBlocks() throws {
        XCTAssertEqual(try Inflate.inflate(SecurityLabFixtures.dynamicDeflate, maxOutput: 1 << 20).output,
                       Array(SecurityLabFixtures.dynamicText.utf8))
        XCTAssertEqual(String(decoding: try Inflate.inflate(SecurityLabFixtures.fixedDeflate, maxOutput: 100).output, as: UTF8.self),
                       "hello hello hello sentinel")
        XCTAssertEqual(String(decoding: try Inflate.inflate(SecurityLabFixtures.storedDeflate, maxOutput: 100).output, as: UTF8.self),
                       "stored block")
    }

    func testInflateEnforcesOutputLimitAndRejectsCorruptData() {
        XCTAssertThrowsError(try Inflate.inflate(SecurityLabFixtures.dynamicDeflate, maxOutput: 1000)) {
            XCTAssertEqual($0 as? Inflate.Failure, .outputLimit)
        }
        XCTAssertThrowsError(try Inflate.inflate(Array(SecurityLabFixtures.dynamicDeflate.prefix(40)), maxOutput: 1 << 20))
        XCTAssertThrowsError(try Inflate.inflate([0xff, 0xff, 0xff], maxOutput: 100))
        XCTAssertThrowsError(try Inflate.gunzip([1, 2, 3], maxOutput: 100))
        // Random garbage never crashes.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let noise = (0..<64).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = try? Inflate.inflate(noise, maxOutput: 4096)
        }
    }

    func testUnsafeEntryNames() {
        XCTAssertNotNil(ArchiveReader.unsafeReason("../../etc/passwd"))
        XCTAssertNotNil(ArchiveReader.unsafeReason("a/../../b"))
        XCTAssertNotNil(ArchiveReader.unsafeReason("/etc/passwd"))
        XCTAssertNotNil(ArchiveReader.unsafeReason("C:/Windows/x"))
        XCTAssertNotNil(ArchiveReader.unsafeReason("dir\\..\\x"))
        XCTAssertNil(ArchiveReader.unsafeReason("src/app/config.yml"))
        XCTAssertNil(ArchiveReader.unsafeReason("weird..name.txt"))
        XCTAssertEqual(ArchiveReader.displayName("a\u{1b}[31mred"), "a?[31mred")
    }

    private func items(_ bytes: [UInt8], kind: ArchiveKind, maxEntryBytes: Int = 1 << 20) throws -> [ArchiveItem] {
        var result: [ArchiveItem] = []
        try ArchiveReader.read(bytes, kind: kind, archiveName: "fixture", limits: ArchiveLimits(maxEntries: 100, maxEntryBytes: maxEntryBytes, maxTotalBytes: 8 << 20),
                               control: AssessmentControl(timeout: 60)) { result.append($0) }
        return result
    }

    func testZipEntriesAreReadOrSkippedSafely() throws {
        let entries = try items(SecurityLabFixtures.mixedZip, kind: .zip)
        let files = entries.compactMap { item -> String? in if case .file(let path, _) = item { return path }; return nil }
        XCTAssertEqual(Set(files), ["config/app.env", "README.md", "logo.bin"])
        XCTAssertTrue(entries.contains { if case .unsafePath(let path, _) = $0 { return path == "../../outside.txt" }; return false })
        XCTAssertTrue(entries.contains { if case .skipped(let path, let reason) = $0 { return path == "link-to-etc" && reason.contains("symbolic link") }; return false })
        XCTAssertTrue(entries.contains { if case .skipped(let path, let reason) = $0 { return path == "inner.zip" && reason.contains("nested") }; return false })
        if case .file(_, let data)? = entries.first(where: { if case .file(let p, _) = $0 { return p == "config/app.env" }; return false }) {
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("DB_PASSWORD="))
        } else {
            XCTFail("config/app.env was not read")
        }
    }

    func testDecompressionBombAndEncryptedEntriesAreSkipped() throws {
        let bomb = try items(SecurityLabFixtures.bombZip, kind: .zip, maxEntryBytes: 1 << 20)
        XCTAssertEqual(bomb.count, 1)
        guard case .skipped(_, let reason) = bomb[0] else { return XCTFail("bomb was not skipped: \(bomb)") }
        XCTAssertTrue(reason.contains("decompression bomb"), reason)

        let encrypted = try items(SecurityLabFixtures.encryptedZip, kind: .zip)
        guard case .skipped(_, let why)? = encrypted.first else { return XCTFail("encrypted entry was not skipped") }
        XCTAssertTrue(why.contains("encrypted"))
    }

    func testTarGzEntries() throws {
        let entries = try items(SecurityLabFixtures.tarGz, kind: .tarGzip)
        let files = entries.compactMap { item -> String? in if case .file(let path, _) = item { return path }; return nil }
        XCTAssertEqual(Set(files), ["project/settings.ini", "project/notes.txt"])
        XCTAssertTrue(entries.contains { if case .skipped(let path, _) = $0 { return path == "project/link" }; return false })
        XCTAssertTrue(entries.contains { if case .unsafePath(let path, _) = $0 { return path == "/abs/path.txt" }; return false })
    }

    func testMalformedArchivesFailCleanly() {
        XCTAssertThrowsError(try items(Array(SecurityLabFixtures.mixedZip.prefix(100)), kind: .zip))
        XCTAssertThrowsError(try items(Array(repeating: 0x41, count: 600), kind: .tar))
        XCTAssertThrowsError(try items([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3, 1, 2, 3, 4, 5, 6, 7, 8], kind: .tarGzip))
    }
}
