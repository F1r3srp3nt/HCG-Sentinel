import XCTest
@testable import SentinelCore

/// Synthetic credentials, assembled at run time so no complete vendor-format token is stored in the repository.
/// None of them is valid anywhere.
enum FakeSecrets {
    static let github = "gh" + "p_" + String(repeating: "aB3d", count: 9)
    static let awsKeyID = "AK" + "IA" + "QWERTYUIOP234567"
    static let stripeLive = "sk" + "_live_" + String(repeating: "Zq8", count: 8)
    static let urlPassword = "Wq7Lm2Zr9Pk4"
    static let assigned = "Hq3Lz9Wm2Rt7Yp5K"
    static let envValue = "Xk9vR2mQ7tLp4wZs"
    static let entropyValue = "q8Zr3Lw0Pm5Xt2Vn7Bk4Hs9Jd6Gf1Ca"
    static let privateKey = "-----BEGIN " + "RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA1b2c3d4e5f6g7h8i9j0klmnopq\n-----END RSA PRIVATE KEY-----\n"

    static var all: [String] { [github, awsKeyID, stripeLive, urlPassword, assigned, envValue, entropyValue, "MIIEowIBAAKCAQEA1b2c3d4e5f6g7h8i9j0klmnopq"] }
}

final class SecretScannerTests: XCTestCase {
    private var root: URL!
    private let key = [UInt8](repeating: 7, count: 32)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("secret-scan-\(UUID().uuidString)/project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func write(_ relative: String, _ text: String) throws {
        try write(relative, Data(text.utf8))
    }

    private func write(_ relative: String, _ data: Data) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func scan(_ configure: (inout SecretScanConfiguration) -> Void = { _ in }, sources: [URL]? = nil,
                      control: AssessmentControl = AssessmentControl(timeout: 120)) -> SecurityAssessmentRecord {
        var configuration = SecretScanConfiguration(fingerprintKey: key)
        configure(&configuration)
        return SecretScanner(configuration: configuration).scan(sources ?? [root], control: control)
    }

    private func ruleIDs(_ record: SecurityAssessmentRecord) -> [String] { record.findings.map { $0.checkID }.sorted() }

    // MARK: Detection

    func testDetectsEachFamily() {
        let scanner = SecretScanner(configuration: SecretScanConfiguration(fingerprintKey: key))
        let text = """
        let token = "\(FakeSecrets.github)"
        aws_access_key_id = \(FakeSecrets.awsKeyID)
        STRIPE = "\(FakeSecrets.stripeLive)"
        DATABASE_URL=postgres://admin:\(FakeSecrets.urlPassword)@db.internal:5432/app
        api_key: "\(FakeSecrets.assigned)"
        signing_key_material \(FakeSecrets.entropyValue)
        \(FakeSecrets.privateKey)
        """
        let found = scanner.candidates(in: text, path: "src/config.swift")
        let ids = Set(found.map { $0.ruleID })
        for expected in ["github-token", "aws-access-key-id", "stripe-live-key", "url-credentials", "config-assignment-quoted",
                         "high-entropy-value", "private-key-block"] {
            XCTAssertTrue(ids.contains(expected), "missing \(expected): \(found.map { $0.ruleID })")
        }
        XCTAssertEqual(found.first { $0.ruleID == "private-key-block" }?.confidence, .high)
        XCTAssertEqual(found.first { $0.ruleID == "stripe-live-key" }?.severity, .critical)
        XCTAssertEqual(found.first { $0.ruleID == "high-entropy-value" }?.confidence, .low)
        // The generic assignment rule does not double-report a value a specific rule already matched.
        XCTAssertEqual(found.filter { $0.line == 1 }.count, 1)
        for candidate in found {
            for secret in FakeSecrets.all {
                XCTAssertFalse(candidate.redactedLine.contains(secret), "redacted line leaks a secret: \(candidate.redactedLine)")
            }
        }
    }

    func testPlaceholdersAndCommonFalsePositivesAreIgnored() {
        let scanner = SecretScanner(configuration: SecretScanConfiguration(fingerprintKey: key))
        let text = """
        password = "changeme"
        API_KEY=${API_KEY}
        token: "<your-token-here>"
        secret = os.environ["APP_SECRET"]
        db_password = settings.database.password
        client_secret = "xxxxxxxxxxxxxxxx"
        retries = 12345678
        integrity sha512 key: 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
        // documentation: -----BEGIN \("RSA PRIVATE KEY")-----
        postgres://user:password@localhost/db
        """
        let found = scanner.candidates(in: text, path: "app/config.py")
        XCTAssertTrue(found.filter { $0.confidence != .low }.isEmpty, "unexpected: \(found.map { "\($0.ruleID)@\($0.line)" })")
        // A private-key header with no body is reported, but only with low confidence.
        XCTAssertEqual(found.map { $0.ruleID }, ["private-key-block"])
    }

    func testLockFilesSkipTheEntropyRule() {
        let scanner = SecretScanner(configuration: SecretScanConfiguration(fingerprintKey: key))
        let line = "api_signature_token_material \(FakeSecrets.entropyValue)\n"
        XCTAssertFalse(scanner.candidates(in: line, path: "a/b.txt").isEmpty)
        XCTAssertTrue(scanner.candidates(in: line, path: "a/package-lock.json").isEmpty)
    }

    // MARK: Scanning, redaction, suppression

    func testFolderScanReportsLocationsAndNeverStoresSecrets() throws {
        try write("Sources/App.swift", "import Foundation\nlet token = \"\(FakeSecrets.github)\"\n")
        try write(".env", "DATABASE_URL=postgres://admin:\(FakeSecrets.urlPassword)@db.internal/app\nAPP_SECRET=\(FakeSecrets.envValue)\n")
        try write("keys/deploy.pem", FakeSecrets.privateKey)
        try write("README.md", "Nothing to see.\n")
        let record = scan()

        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.module, .secretScanner)
        XCTAssertEqual(record.location, .thisDevice)
        XCTAssertEqual(ruleIDs(record), ["config-assignment-plain", "github-token", "private-key-block", "url-credentials"])
        let github = try XCTUnwrap(record.findings.first { $0.checkID == "github-token" })
        XCTAssertEqual(github.location, "project/Sources/App.swift:2")
        XCTAssertEqual(github.basis, .observation)
        XCTAssertTrue(github.explanation.contains("cannot show whether the credential is active"))
        XCTAssertNotNil(github.fingerprint)
        XCTAssertTrue(github.evidence.contains { $0.contains("ghp_[REDACTED 40 chars]") }, "\(github.evidence)")
        XCTAssertEqual(record.checks.first { $0.id == SecretCategory.privateKey.rawValue }?.outcome, .finding)
        XCTAssertEqual(record.checks.first { $0.id == SecretCategory.highEntropy.rawValue }?.outcome, .passed)
        XCTAssertEqual(record.workCompleted, 4)
        XCTAssertEqual(record.workTotal, 4)
        XCTAssertTrue(record.limitations.contains { $0.contains("cannot prove whether a credential is active") })

        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        let report = SecurityReportRenderer.text(record)
        for secret in FakeSecrets.all {
            XCTAssertFalse(json.contains(secret), "stored record leaks \(secret.prefix(4))…")
            XCTAssertFalse(report.contains(secret), "report leaks \(secret.prefix(4))…")
        }
        XCTAssertTrue(report.contains("project/.env:"))
    }

    func testFalsePositiveSuppressionByFingerprintAndInlineMarker() throws {
        try write("a.swift", "let token = \"\(FakeSecrets.github)\"\n")
        try write("b.swift", "let token = \"\(FakeSecrets.github)\" // sentinel:allow test fixture\n")
        let first = scan()
        XCTAssertEqual(first.findings.count, 1)
        XCTAssertEqual(first.suppressedCount, 1, "inline marker")
        let fingerprint = try XCTUnwrap(first.findings.first?.fingerprint)

        let second = scan { $0.suppressedFingerprints = [fingerprint] }
        XCTAssertTrue(second.findings.isEmpty)
        XCTAssertEqual(second.suppressedCount, 2)

        let otherKey = SecretScanner(configuration: SecretScanConfiguration(fingerprintKey: [UInt8](repeating: 9, count: 32)))
        XCTAssertNotEqual(otherKey.fingerprint(ruleID: "github-token", path: "project/a.swift", value: FakeSecrets.github), fingerprint,
                          "fingerprints are keyed per installation")
    }

    // MARK: Safety and limits

    func testSymbolicLinksAreNeverFollowed() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("let token = \"\(FakeSecrets.github)\"\n".utf8).write(to: outside.appendingPathComponent("secret.swift"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-dir"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.swift"),
                                                   withDestinationURL: outside.appendingPathComponent("secret.swift"))
        try write("ok.txt", "fine\n")
        let record = scan()
        XCTAssertTrue(record.findings.isEmpty, "\(record.findings.map { $0.location ?? "" })")
        XCTAssertTrue(record.notTested.contains { $0.contains("2 symbolic link(s) were not followed") }, "\(record.notTested)")

        let direct = scan(sources: [root.appendingPathComponent("linked.swift")])
        XCTAssertTrue(direct.findings.isEmpty, "a selected symlink is not followed either")
    }

    func testOversizedBinaryExcludedAndFileLimit() throws {
        try write("big.txt", String(repeating: "x", count: 5000) + "\nlet token = \"\(FakeSecrets.github)\"\n")
        var binary = Data([0, 1, 2, 0])
        binary.append(Data("let token = \"\(FakeSecrets.github)\"".utf8))
        try write("image.bin", binary)
        try write("node_modules/lib/index.js", "const token = \"\(FakeSecrets.github)\"\n")
        try write("logs/debug.log", "token=\(FakeSecrets.envValue)\n")
        try write("small.txt", "hello\n")
        let record = scan { config in
            config.maxFileBytes = 1024
            config.exclusions = ["*.log"]
        }
        XCTAssertTrue(record.findings.isEmpty, "\(record.findings.map { $0.location ?? "" })")
        XCTAssertTrue(record.notTested.contains { $0.contains("larger than 1 KB") && $0.contains("big.txt") }, "\(record.notTested)")
        XCTAssertTrue(record.notTested.contains { $0.contains("1 binary file") })
        XCTAssertTrue(record.notTested.contains { $0.contains("2 item(s) matched an exclusion") }, "\(record.notTested)")

        let capped = scan { $0.maxFiles = 1 }
        XCTAssertTrue(capped.notTested.contains { $0.contains("beyond the 1-file limit") }, "\(capped.notTested)")
    }

    func testTotalByteBudget() throws {
        for index in 0..<5 { try write("f\(index).txt", String(repeating: "a", count: 600) + "\n") }
        let record = scan { $0.maxTotalBytes = 1500 }
        XCTAssertTrue(record.notTested.contains { $0.contains("total read limit") }, "\(record.notTested)")
        XCTAssertEqual(record.checks.first?.outcome, .inconclusive, "an incomplete scan is never a pass")
    }

    func testGlobPatterns() {
        XCTAssertTrue(GlobPattern("*.log")!.matches("logs/debug.log"))
        XCTAssertTrue(GlobPattern("docs/")!.matches("docs/guide/a.md"))
        XCTAssertFalse(GlobPattern("docs/")!.matches("src/docs.swift"))
        XCTAssertTrue(GlobPattern("tests/fixtures/**")!.matches("tests/fixtures/a/b.json"))
        XCTAssertFalse(GlobPattern("tests/*.json")!.matches("tests/a/b.json"))
        XCTAssertTrue(GlobPattern("secret?.txt")!.matches("a/secret1.txt"))
        XCTAssertNil(GlobPattern("   "))
        XCTAssertNil(GlobPattern("# comment"))
    }

    // MARK: Archives

    func testArchivesAreScannedInMemoryWithUnsafeEntriesReported() throws {
        let archives = root.deletingLastPathComponent().appendingPathComponent("archives")
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        let zip = archives.appendingPathComponent("bundle.zip")
        try Data(SecurityLabFixtures.mixedZip).write(to: zip)
        let tgz = archives.appendingPathComponent("release.tar.gz")
        try Data(SecurityLabFixtures.tarGz).write(to: tgz)
        let bomb = archives.appendingPathComponent("bomb.zip")
        try Data(SecurityLabFixtures.bombZip).write(to: bomb)

        let record = scan(sources: [zip, tgz, bomb])
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.scope.map { $0.kind }, [.archive, .archive, .archive])
        let locations = record.findings.compactMap { $0.location }
        XCTAssertTrue(locations.contains("bundle.zip!/config/app.env:2"), "\(locations)")
        XCTAssertTrue(locations.contains("release.tar.gz!/project/settings.ini:2"), "\(locations)")
        XCTAssertTrue(locations.contains("bundle.zip!/../../outside.txt"))
        XCTAssertTrue(locations.contains("release.tar.gz!//abs/path.txt"))
        XCTAssertEqual(record.checks.first { $0.id == "archive-safety" }?.outcome, .finding)
        let skipped = record.notTested.joined(separator: "\n")
        XCTAssertTrue(skipped.contains("symbolic link"))
        XCTAssertTrue(skipped.contains("nested archive"))
        XCTAssertTrue(skipped.contains("decompression bomb"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archives.appendingPathComponent("outside.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("outside.txt").path))
    }

    func testCorruptArchiveIsAnExecutionErrorNotAFinding() throws {
        let broken = root.appendingPathComponent("broken.zip")
        try Data(SecurityLabFixtures.mixedZip.prefix(200)).write(to: broken)
        let record = scan(sources: [broken])
        XCTAssertTrue(record.findings.isEmpty)
        XCTAssertFalse(record.errors.isEmpty)
        XCTAssertTrue(record.notTested.contains { $0.contains("broken.zip") })
        XCTAssertEqual(record.checks.first?.outcome, .inconclusive)
    }

    // MARK: Cancellation and time limits

    func testCancellationAndTimeLimit() throws {
        for index in 0..<20 { try write("f\(index).txt", "let token = \"\(FakeSecrets.github)\"\n") }
        let cancelled = AssessmentControl(timeout: 60)
        cancelled.cancel()
        let first = scan(control: cancelled)
        XCTAssertEqual(first.status, .cancelled)
        XCTAssertTrue(first.findings.isEmpty)
        XCTAssertTrue(first.checks.allSatisfy { $0.outcome == .inconclusive })
        XCTAssertTrue(first.headline.hasPrefix("Cancelled"))

        let expired = scan(control: AssessmentControl(timeout: 0))
        XCTAssertEqual(expired.status, .timedOut)
    }

    func testCancelMidScanStopsAtTheNextFile() throws {
        for index in 0..<50 { try write("f\(String(format: "%02d", index)).txt", "let token = \"\(FakeSecrets.github)\"\n") }
        let control = AssessmentControl(timeout: 60)
        var configuration = SecretScanConfiguration(fingerprintKey: key)
        configuration.maxFiles = 100
        var progressCalls = 0
        let record = SecretScanner(configuration: configuration).scan([root], control: control) { progress in
            progressCalls += 1
            if progress.completed == 10 { control.cancel() }
        }
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertEqual(record.workCompleted, 10)
        XCTAssertEqual(record.findings.count, 10)
        XCTAssertTrue(record.notTested.contains { $0.contains("40 file(s) were not reached") }, "\(record.notTested)")
        XCTAssertGreaterThan(progressCalls, 10)
    }
}
