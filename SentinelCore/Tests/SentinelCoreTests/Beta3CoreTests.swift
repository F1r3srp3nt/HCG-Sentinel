import XCTest
@testable import SentinelCore

final class CapabilityCenterTests: XCTestCase {
    func testEveryCapabilityHasAProfileAndAClass() {
        let registry = CapabilityRegistry()
        XCTAssertEqual(registry.states.count, CapabilityID.allCases.count, "every ID is in the catalog")
        for state in registry.states {
            XCTAssertFalse(state.profile.platforms.isEmpty, "\(state.id)")
            XCTAssertFalse(state.profile.hardware.isEmpty, "\(state.id)")
            _ = state.classification
        }
    }

    func testClassificationFollowsTheFactsOnly() {
        let registry = CapabilityRegistry()
        func cls(_ id: CapabilityID) -> CapabilityClass? { registry.state(id)?.classification }
        XCTAssertEqual(cls(.satelliteAccess), .research)
        XCTAssertEqual(cls(.watchScanning), .research)
        XCTAssertEqual(cls(.radioModification), .research)
        XCTAssertEqual(cls(.deviceWideCapture), .interfaceOnly)
        XCTAssertEqual(cls(.macDebugProxy), .interfaceOnly)
        XCTAssertEqual(cls(.serverAssessments), .interfaceOnly)
        XCTAssertEqual(cls(.icmpPing), .disabled, "nothing is on until the app enables it")
        registry.setUserEnabled(.icmpPing, true)
        XCTAssertEqual(cls(.icmpPing), .unverified)
        XCTAssertTrue(registry.recordVerified(.icmpPing, evidence: "Echo reply from 127.0.0.1"))
        XCTAssertEqual(cls(.icmpPing), .verified)
        registry.setUserEnabled(.helperLink, true)
        XCTAssertEqual(cls(.helperLink), .partial, "client only; no helper exists")
        registry.setUserEnabled(.radioNodeLink, true)
        XCTAssertEqual(cls(.radioNodeLink), .externalHardware)
        registry.setEnvironment(.bluetoothDiscovery, .unsupported("No radio"))
        XCTAssertEqual(cls(.bluetoothDiscovery), .unsupported)
        XCTAssertFalse(registry.recordVerified(.satelliteAccess, evidence: "x"), "research can never be verified")
    }

    func testFilters() {
        let registry = CapabilityRegistry()
        registry.setUserEnabled(.icmpPing, true)
        registry.recordVerified(.icmpPing, evidence: "e")
        registry.setUserEnabled(.wifiConnectionInfo, true)
        let verified = registry.states.filter(CapabilityFilter.verified.matches).map { $0.id }
        XCTAssertEqual(verified, [.icmpPing])
        XCTAssertTrue(registry.states.filter(CapabilityFilter.unverified.matches).map { $0.id }.contains(.wifiConnectionInfo))
        let planned = Set(registry.states.filter(CapabilityFilter.planned.matches).map { $0.id })
        XCTAssertTrue(planned.isSuperset(of: [.satelliteAccess, .deviceWideCapture, .macDebugProxy]))
        XCTAssertEqual(registry.states.filter(CapabilityFilter.all.matches).count, CapabilityID.allCases.count)
    }

    func testEvidenceIsPersistedButDoesNotVerifyTheNextSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CapabilityEvidenceStore(url: dir.appendingPathComponent("evidence.json"))
        let t = Date(timeIntervalSince1970: 1_000_000)
        let first = CapabilityRegistry(evidenceStore: store, now: { t })
        first.setUserEnabled(.deviceSecurity, true)
        first.recordVerified(.deviceSecurity, evidence: "7 checks returned results")
        first.recordFailure(.icmpPing, reason: "EACCES")
        let second = CapabilityRegistry(evidenceStore: store)
        let state = try XCTUnwrap(second.state(.deviceSecurity))
        XCTAssertEqual(state.lastSuccess, CapabilityEvidence(at: t, text: "7 checks returned results"))
        XCTAssertEqual(state.verification, .unverified, "history never verifies a new session")
        XCTAssertEqual(second.state(.icmpPing)?.lastFailure?.text, "EACCES")
        second.clearHistory()
        XCTAssertNil(CapabilityRegistry(evidenceStore: store).state(.deviceSecurity)?.lastSuccess)
    }
}

final class NavigationRegistryTests: XCTestCase {
    func testExistingLinkContractIsUnchanged() {
        // Exactly what HCG Nexus (HCGInterchange.m) and HCG System Tester (SentinelDeepLink) send.
        for name in ["dashboard", "network", "networkCheck", "securityLab", "bluetooth", "radio", "requests", "capabilities", "settings", "devices"] {
            let url = URL(string: "hcgsentinel://open/\(name)")!
            XCTAssertEqual(DeepLink.section(from: url)?.rawValue, name, name)
        }
    }

    func testEveryDestinationRoundTripsAndBelongsToOneArea() {
        for section in SentinelSection.allCases {
            XCTAssertEqual(DeepLink.target(from: DeepLink.url(for: section)), .section(section))
            XCTAssertTrue(SentinelArea.allCases.contains(section.area))
        }
        XCTAssertEqual(SentinelArea.allCases.count, 12)
        for area in SentinelArea.allCases { XCTAssertFalse(area.sections.isEmpty, "\(area)") }
        XCTAssertFalse(SentinelArea.commandCenter.sections.contains(.center), "the hub does not list itself")
    }

    func testNewDestinationsAreNavigationOnly() {
        for bad in ["hcgsentinel://open/ping?target=1.1.1.1", "hcgsentinel://open/localNetwork/sweep", "hcgsentinel://start/ping",
                    "hcgsentinel://open/deviceSecurity#run", "hcgsentinel://run/secretScanner"] {
            XCTAssertNil(DeepLink.target(from: URL(string: bad)!), bad)
        }
        XCTAssertEqual(DeepLink.section(from: URL(string: "HCGSENTINEL://OPEN/DEVICESECURITY")!), .deviceSecurity)
    }

    func testEveryProfileScreenIsARegisteredDestination() {
        for id in CapabilityID.allCases {
            if let section = CapabilityCatalog.profile(for: id).section {
                XCTAssertTrue(SentinelSection.allCases.contains(section))
            }
        }
    }
}

final class DeviceSecurityTests: XCTestCase {
    private let status = """
    Package: uikittools
    Status: install ok installed
    Version: 2.1.6
    Architecture: iphoneos-arm64

    Package: com.hakmicapitalgroup.hcgsentinel
    Status: install ok installed
    Priority: optional
    Version: 0.1.0~beta3
    Architecture: iphoneos-arm64
    Depends: firmware (>= 15.0), uikittools
    Description: Toolkit
     continuation line: not a field
    """

    private let list = """
    /.
    /var
    /var/jb
    /var/jb/Applications
    /var/jb/Applications/HCGSentinelModern.app
    /var/jb/Applications/HCGSentinelModern.app/HCGSentinelModern
    /var/jb/Applications/HCGSentinelModern.app/Info.plist
    /var/jb/Applications/HCGSentinelModern.app/Assets.car
    /var/jb/Applications/HCGSentinelModern.app/Fonts
    /var/jb/Applications/HCGSentinelModern.app/Fonts/SpaceGrotesk.ttf
    """

    func testDpkgParsing() throws {
        let packages = DpkgStatusParser.parse(status)
        XCTAssertEqual(packages.map { $0.name }, ["uikittools", "com.hakmicapitalgroup.hcgsentinel"])
        let sentinel = try XCTUnwrap(packages.last)
        XCTAssertEqual(sentinel.version, "0.1.0~beta3")
        XCTAssertTrue(sentinel.isInstalled)
        XCTAssertEqual(sentinel.depends, "firmware (>= 15.0), uikittools")
        XCTAssertTrue(DpkgStatusParser.parse("").isEmpty)
        XCTAssertFalse(DpkgStatusParser.parse("Package: x\nStatus: deinstall ok config-files").first!.isInstalled)
    }

    private func facts(bundlePath: String = "/var/jb/Applications/HCGSentinelModern.app", files: Set<String>,
                       dpkg: Result<String, DeviceSecurityFacts.ReadFailure>?, list: Result<String, DeviceSecurityFacts.ReadFailure>?,
                       passcode: DeviceSecurityFacts.Passcode = .set) -> DeviceSecurityFacts {
        DeviceSecurityFacts(systemName: "iOS", systemVersion: "17.4", model: "iPhone12,5", passcode: passcode, biometry: .faceID(enrolled: true),
                            dataProtection: "NSFileProtectionCompleteUntilFirstUserAuthentication", atsAllowsArbitraryLoads: false,
                            atsExceptionDomains: ["captive.apple.com"], atsAllowsLocalNetworking: true, bundleIdentifier: "com.hcg.sentinel",
                            appVersion: "0.1.0 (3)", executableSHA256: "ab12", rootlessPrefixVisible: true, bundlePath: bundlePath,
                            dpkgStatus: dpkg, packageList: list, bundleFiles: files, bundleDirectories: ["Fonts"])
    }

    func testIntactUnleashedInstall() {
        let report = DeviceSecurityEvaluator.evaluate(facts(files: ["HCGSentinelModern", "Info.plist", "Assets.car", "Fonts/SpaceGrotesk.ttf", "_CodeSignature/CodeResources"],
                                                            dpkg: .success(status), list: .success(list)))
        XCTAssertEqual(report.edition, "Unleashed (package-manager install)")
        let byID = Dictionary(uniqueKeysWithValues: report.checks.map { ($0.id, $0) })
        XCTAssertEqual(byID["passcode"]?.outcome, .pass)
        XCTAssertEqual(byID["package"]?.outcome, .pass)
        XCTAssertEqual(byID["package-files"]?.outcome, .pass)
        XCTAssertTrue(byID["package-files"]?.detail.contains("4 files") ?? false, byID["package-files"]?.detail ?? "")
        XCTAssertTrue(byID["package-files"]?.detail.contains("no checksums") ?? false, "never implies contents were compared")
        XCTAssertEqual(byID["ats"]?.outcome, .pass)
        XCTAssertTrue(report.text().contains("Nothing was changed"))
    }

    func testTamperedBundleAndMissingPasscodeAreFlagged() {
        let report = DeviceSecurityEvaluator.evaluate(facts(files: ["HCGSentinelModern", "Info.plist", "Fonts/SpaceGrotesk.ttf", "inject.dylib"],
                                                            dpkg: .success(status), list: .success(list), passcode: .notSet))
        let byID = Dictionary(uniqueKeysWithValues: report.checks.map { ($0.id, $0) })
        XCTAssertEqual(byID["passcode"]?.outcome, .fail)
        XCTAssertNotNil(byID["passcode"]?.remediation)
        XCTAssertEqual(byID["package-files"]?.outcome, .fail)
        let detail = byID["package-files"]?.detail ?? ""
        XCTAssertTrue(detail.contains("Assets.car") && detail.contains("inject.dylib"), detail)
    }

    func testUnreadableIsNeverAPass() {
        let report = DeviceSecurityEvaluator.evaluate(facts(files: [], dpkg: .failure(.init("Operation not permitted")),
                                                            list: .failure(.init("Operation not permitted")), passcode: .unknown("LAError -1000")))
        let byID = Dictionary(uniqueKeysWithValues: report.checks.map { ($0.id, $0) })
        XCTAssertEqual(byID["package"]?.outcome, .unavailable)
        XCTAssertEqual(byID["package-files"]?.outcome, .unavailable)
        XCTAssertEqual(byID["passcode"]?.outcome, .unavailable)
    }

    func testStandardInstallHasNoPackageComparison() {
        let report = DeviceSecurityEvaluator.evaluate(facts(bundlePath: "/private/var/containers/Bundle/Application/X/HCGSentinelModern.app",
                                                            files: ["Info.plist"], dpkg: nil, list: nil))
        XCTAssertEqual(report.edition, "Standard")
        XCTAssertNil(report.checks.first { $0.id == "package-files" })
        XCTAssertEqual(report.checks.first { $0.id == "package" }?.outcome, .info)
    }
}

final class ReportImportTests: XCTestCase {
    private func report(title: String = "Connection security", evidence: [String] = ["USB data link: functional"]) -> DiagnosticReport {
        DiagnosticReport.make(reportId: UUID().uuidString, kind: "systemtester.connection-security", title: title,
                              origin: .init(app: "HCG System Tester", appVersion: "0.2.0", installationId: "test", deviceName: "Mac"),
                              createdAt: Date(timeIntervalSince1970: 1_700_000_000), completedAt: nil,
                              summary: .init(status: "completed", highestSeverity: "low", findingCount: 1), scope: ["USB devices"],
                              findings: [.init(title: "Device accepts host pairing", severity: "low", confidence: "high", basis: "observed",
                                               location: nil, evidence: evidence, explanation: nil, remediation: nil)],
                              checks: [], limitations: [], notTested: [])
    }

    func testValidReportImportsAndIsStored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ImportedReportStore(directory: dir)
        let r = report()
        guard case .success(let entry) = store.add(try r.encoded()) else { return XCTFail("valid report refused") }
        XCTAssertEqual(entry.report.title, "Connection security")
        XCTAssertEqual(store.list().map { $0.report.reportId }, [r.reportId])
        store.delete(r.reportId)
        XCTAssertTrue(store.list().isEmpty)
    }

    /// The exact shape HCG System Tester 0.2.0 writes (DeviceLinkDiagnosticReport.encoded(): pretty-printed, sorted keys,
    /// ISO 8601 dates, no escaped slashes).
    func testImportsHCGSystemTesterExport() {
        let json = """
        {
          "checks" : [ { "detail" : "USB 3 SuperSpeed", "outcome" : "functional", "title" : "Data link" } ],
          "createdAt" : "2026-11-24T18:02:11Z",
          "findings" : [ {
            "basis" : "observed",
            "confidence" : "high",
            "evidence" : [ "Trust dialog accepted on the device", "Pairing record present on this Mac" ],
            "explanation" : "This Mac can read device data while the device is unlocked.",
            "remediation" : "Remove the pairing in Settings › General › Transfer or Reset iPhone if you no longer use this Mac.",
            "severity" : "low",
            "title" : "Host pairing established"
          } ],
          "kind" : "systemtester.connection-security",
          "limitations" : [ "Only devices connected by cable were assessed." ],
          "notTested" : [ ],
          "origin" : { "app" : "HCG System Tester", "appVersion" : "0.2.0", "deviceName" : "Mac", "installationId" : "a1b2", "module" : "connection-security" },
          "redaction" : { "applied" : true, "policy" : "hcg.redaction/1" },
          "reportId" : "4b2f6d1e-0c3a-4f6e-9d7a-1f2e3d4c5b6a",
          "schema" : "hcg.diagnostic-report/1",
          "scope" : [ "USB and Thunderbolt devices on this Mac" ],
          "summary" : { "findingCount" : 1, "highestSeverity" : "low", "status" : "completed" },
          "title" : "Connection security findings"
        }
        """
        guard case .success(let report) = ReportImporter.importReport(Data(json.utf8)) else {
            return XCTFail("System Tester's export must import: \(ReportImporter.importReport(Data(json.utf8)))")
        }
        XCTAssertEqual(report.origin.app, "HCG System Tester")
        XCTAssertEqual(report.findings.first?.title, "Host pairing established")
        XCTAssertTrue(ReportTextRenderer.text(report).contains("Evidence: Trust dialog accepted on the device"), "the evidence is rendered as text")
    }

    func testRefusals() throws {
        XCTAssertEqual(ReportImporter.importReport(Data("not json".utf8)), .failure(.notJSON))
        XCTAssertEqual(ReportImporter.importReport(Data(#"{"schema":"hcg.systemtester.inventory/1"}"#.utf8)), .failure(.wrongSchema("hcg.systemtester.inventory/1")))
        XCTAssertEqual(ReportImporter.importReport(Data(count: ReportValidator.maxBytes + 1)), .failure(.tooLarge(ReportValidator.maxBytes + 1)))
        // A report whose sender left a private key in it is refused, as HCG Server would refuse it.
        var leaky = report()
        leaky.findings[0].evidence = ["-----BEGIN RSA PRIVATE KEY----- abc"]
        guard case .failure(.refused(let problems)) = ReportImporter.importReport(try leaky.encoded()) else { return XCTFail("leaky report imported") }
        XCTAssertTrue(problems.contains { $0.contains("private key") }, "\(problems)")
    }
}

final class CaptureStatisticsTests: XCTestCase {
    private func capture() throws -> ParsedCapture {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let a: [UInt8] = [192, 168, 1, 10], b: [UInt8] = [192, 168, 1, 1], c: [UInt8] = [10, 0, 0, 5]
        let records = [
            SyntheticCapture.Record(timestamp: base, bytes: SyntheticCapture.ethernet(etherType: 0x0800, payload: SyntheticCapture.ipv4(source: a, destination: b, proto: 6, payload: SyntheticCapture.tcp(sourcePort: 50000, destinationPort: 443)))),
            SyntheticCapture.Record(timestamp: base.addingTimeInterval(0.5), bytes: SyntheticCapture.ethernet(etherType: 0x0800, payload: SyntheticCapture.ipv4(source: b, destination: a, proto: 6, payload: SyntheticCapture.tcp(sourcePort: 443, destinationPort: 50000)))),
            SyntheticCapture.Record(timestamp: base.addingTimeInterval(2), bytes: SyntheticCapture.ethernet(etherType: 0x0800, payload: SyntheticCapture.ipv4(source: a, destination: c, proto: 17, payload: SyntheticCapture.udp(sourcePort: 5353, destinationPort: 53)))),
        ]
        return try CaptureParser.parse(SyntheticCapture.pcapng(records))
    }

    func testStatisticsAndTimeline() throws {
        let stats = CaptureStatistics.compute(try capture())
        XCTAssertEqual(stats.packetCount, 3)
        XCTAssertEqual(stats.distinctEndpoints, 3)
        XCTAssertEqual(stats.duration ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(stats.protocols.first?.packets, 2, "TCP first: \(stats.protocols)")
        XCTAssertEqual(stats.timeline.reduce(0) { $0 + $1.packets }, 3)
        XCTAssertLessThanOrEqual(stats.timeline.count, CaptureStatistics.maxBuckets)
        XCTAssertEqual(stats.conversations.first?.packets, 2, "both TCP directions are one conversation")
    }

    func testReportHidesAddresses() throws {
        let text = CaptureReport.text(try capture())
        XCTAssertFalse(text.contains("192.168.1.10") || text.contains("10.0.0.5"), text)
        XCTAssertTrue(text.contains("host-1"))
        XCTAssertTrue(text.contains("Packets: 3"))
        XCTAssertTrue(text.contains("not decrypted"))
    }

    func testNiceWidths() {
        XCTAssertEqual(CaptureStatistics.niceWidth(0.03), 0.05, accuracy: 1e-9)
        XCTAssertEqual(CaptureStatistics.niceWidth(1.5), 2, accuracy: 1e-9)
        XCTAssertEqual(CaptureStatistics.niceWidth(7), 10, accuracy: 1e-9)
    }
}

final class NetworkHistoryTests: XCTestCase {
    func testPingEntryMasksAddressesAndStoreIsBounded() throws {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = NetworkHistoryEntry.ping(target: "192.168.1.1", configuration: PingConfiguration(count: 3),
                                             results: [PingProbeResult(sequence: 1, outcome: .reply(milliseconds: 2), at: at),
                                                       PingProbeResult(sequence: 2, outcome: .reply(milliseconds: 6), at: at),
                                                       PingProbeResult(sequence: 3, outcome: .timeout, at: at)], at: at, failure: nil)
        XCTAssertFalse(entry.text.contains("192.168.1.1"), entry.text)
        XCTAssertTrue(entry.facts.contains("Loss 33 %"), "\(entry.facts)")
        XCTAssertTrue(entry.facts.contains("Jitter range 4.0 ms"), "\(entry.facts)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NetworkHistoryStore(url: dir.appendingPathComponent("history.json"))
        for i in 0..<(NetworkHistoryStore.maxEntries + 5) {
            var e = entry
            e.id = UUID()
            e.at = at.addingTimeInterval(Double(i))
            store.add(e)
        }
        let list = store.list()
        XCTAssertEqual(list.count, NetworkHistoryStore.maxEntries)
        XCTAssertEqual(list.first?.at, at.addingTimeInterval(Double(NetworkHistoryStore.maxEntries + 4)), "newest kept")
        store.clear()
        XCTAssertTrue(store.list().isEmpty)
    }

    func testAssessmentTextMasksAddresses() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let finding = AssessmentFinding(id: "gw", step: .connection, kind: .observation, title: "Gateway 192.168.1.1",
                                        evidence: ["Gateway: 192.168.1.1"], observedAt: at, limitations: "x", remediation: nil)
        let report = AssessmentReport(startedAt: at, finishedAt: at, findings: [finding], completedSteps: 1, totalSteps: 1, cancelled: false)
        let text = report.text()
        XCTAssertFalse(text.contains("192.168.1.1"), text)
        XCTAssertTrue(text.contains("external diagnostic node"))
        XCTAssertTrue(report.text(maskNetworkIdentifiers: false).contains("192.168.1.1"))
    }
}
