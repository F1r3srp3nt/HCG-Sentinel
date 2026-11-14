import XCTest
@testable import SentinelCore

final class CapabilityTests: XCTestCase {
    func testEverythingStartsDisabledAndUnverified() {
        let registry = CapabilityRegistry()
        XCTAssertEqual(registry.states.count, CapabilityID.allCases.count)
        XCTAssertEqual(registry.verifiedCount, 0)
        for state in registry.states {
            XCTAssertFalse(state.userEnabled)
            XCTAssertEqual(state.verification, .unverified)
            XCTAssertNotEqual(state.readiness, .verified)
            XCTAssertFalse(state.explanation.isEmpty)
        }
    }

    func testVerificationRequiresEnablementAndRealOperation() {
        let registry = CapabilityRegistry()
        XCTAssertFalse(registry.recordVerified(.captureFileInspection, evidence: "parsed"), "disabled capabilities cannot be verified")
        XCTAssertEqual(registry.state(.captureFileInspection)?.readiness, .disabled)

        registry.setUserEnabled(.captureFileInspection, true)
        XCTAssertEqual(registry.state(.captureFileInspection)?.readiness, .ready)
        XCTAssertTrue(registry.recordVerified(.captureFileInspection, evidence: "parsed 7 packets"))
        XCTAssertEqual(registry.state(.captureFileInspection)?.readiness, .verified)
        XCTAssertEqual(registry.verifiedCount, 1)

        registry.setUserEnabled(.captureFileInspection, false)
        XCTAssertEqual(registry.state(.captureFileInspection)?.readiness, .disabled)
        XCTAssertEqual(registry.state(.captureFileInspection)?.verification, .unverified, "disabling clears verification")
    }

    func testInterfaceOnlyCapabilitiesCanNeverBeVerified() {
        let registry = CapabilityRegistry()
        for id in [CapabilityID.deviceWideCapture, .macDebugProxy, .serverAssessments] {
            registry.setUserEnabled(id, true)
            registry.setEnvironment(id, .supported)
            XCTAssertFalse(registry.recordVerified(id, evidence: "claimed"))
            XCTAssertEqual(registry.state(id)?.readiness, .interfaceOnly)
            XCTAssertNotNil(registry.state(id)?.action)
        }
    }

    func testFilteringAndWifiDiscoveryNeedAVerifiedBackend() {
        let registry = CapabilityRegistry()
        for id in [CapabilityID.trafficFiltering, .nearbyWifiDiscovery] {
            XCTAssertEqual(registry.state(id)?.descriptor.implementation, .included)
            registry.setUserEnabled(id, true)
            XCTAssertEqual(registry.state(id)?.readiness, .environmentUnknown, "shown as unverified until a backend reports it")
            registry.setEnvironment(id, .unsupported("No helper or node offers this."))
            XCTAssertFalse(registry.recordVerified(id, evidence: "claimed"))
            XCTAssertEqual(registry.state(id)?.readiness, .unsupported)
        }
        XCTAssertEqual(registry.state(.nearbyWifiDiscovery)?.descriptor.tier, .externalNode)
        XCTAssertEqual(registry.state(.trafficFiltering)?.descriptor.tier, .privilegedHelper)
        XCTAssertEqual(registry.state(.networkAssessment)?.descriptor.tier, .onDevice)
    }

    func testUnsupportedEnvironmentBlocksAndClearsVerification() {
        let registry = CapabilityRegistry()
        registry.setUserEnabled(.bluetoothDiscovery, true)
        XCTAssertEqual(registry.state(.bluetoothDiscovery)?.readiness, .environmentUnknown)
        registry.setEnvironment(.bluetoothDiscovery, .supported)
        XCTAssertTrue(registry.recordVerified(.bluetoothDiscovery, evidence: "advertisement received"))
        registry.setEnvironment(.bluetoothDiscovery, .unsupported("Bluetooth permission denied"))
        XCTAssertEqual(registry.state(.bluetoothDiscovery)?.readiness, .unsupported)
        XCTAssertEqual(registry.state(.bluetoothDiscovery)?.explanation, "Bluetooth permission denied")
        XCTAssertFalse(registry.recordVerified(.bluetoothDiscovery, evidence: "stale"))
    }

    func testFailureIsReportedWithReason() {
        let registry = CapabilityRegistry()
        registry.setUserEnabled(.requestComposer, true)
        registry.recordFailure(.requestComposer, reason: "timed out")
        XCTAssertEqual(registry.state(.requestComposer)?.readiness, .failed)
        XCTAssertTrue(registry.state(.requestComposer)?.explanation.contains("timed out") ?? false)
    }

    func testChangeCallbackFiresOnlyOnRealChanges() {
        let registry = CapabilityRegistry()
        var changes = 0
        registry.onChange = { changes += 1 }
        registry.setUserEnabled(.requestComposer, false)
        XCTAssertEqual(changes, 0)
        registry.setUserEnabled(.requestComposer, true)
        registry.setUserEnabled(.requestComposer, true)
        XCTAssertEqual(changes, 1)
    }

    func testHintsAreNeverProofOfPrivilegedAccess() {
        let allHints = Set(PrivilegeAssessment.Hint.allCases)
        let hintsOnly = PrivilegeAssessment(hints: allHints, helperSessionAuthenticated: false, helperReportedCapabilities: false)
        XCTAssertEqual(hintsOnly.conclusion, .hintsOnly)
        XCTAssertFalse(hintsOnly.isPrivilegedAccessVerified)

        let authenticatedButSilent = PrivilegeAssessment(hints: allHints, helperSessionAuthenticated: true, helperReportedCapabilities: false)
        XCTAssertFalse(authenticatedButSilent.isPrivilegedAccessVerified)

        let verified = PrivilegeAssessment(hints: [], helperSessionAuthenticated: true, helperReportedCapabilities: true)
        XCTAssertTrue(verified.isPrivilegedAccessVerified)
        XCTAssertEqual(PrivilegeAssessment(hints: [], helperSessionAuthenticated: false, helperReportedCapabilities: false).conclusion, .noEvidence)
    }

    func testFeasibilityItemsCanNeverRunOrVerify() {
        let registry = CapabilityRegistry()
        let research = CapabilityCatalog.all.filter { $0.tier == .feasibility }.map { $0.id }
        XCTAssertEqual(Set(research), [.satelliteAccess, .radioModification, .watchScanning])
        for id in research {
            registry.setUserEnabled(id, true)
            registry.setEnvironment(id, .supported)
            XCTAssertFalse(registry.recordVerified(id, evidence: "claimed"))
            XCTAssertEqual(registry.state(id)?.readiness, .notIncluded)
            XCTAssertTrue(registry.state(id)?.explanation.hasPrefix("Not implemented") == true)
        }
        XCTAssertFalse(CapabilityTier.operational.contains(.feasibility))
        XCTAssertEqual(CapabilityTier.operational.count + 1, CapabilityTier.allCases.count)
    }

    func testCatalogCoversEveryCapabilityOnce() {
        XCTAssertEqual(Set(CapabilityCatalog.all.map { $0.id }), Set(CapabilityID.allCases))
        XCTAssertEqual(CapabilityCatalog.all.count, CapabilityID.allCases.count)
        for tier in CapabilityTier.allCases {
            XCTAssertFalse(CapabilityCatalog.all.filter { $0.tier == tier }.isEmpty)
        }
    }
}

final class RedactorTests: XCTestCase {
    private let redactor = Redactor.standard

    func testSensitiveHeaderValuesAreReplaced() {
        XCTAssertEqual(redactor.headerValue(name: "Authorization", value: "Bearer abc.def.ghi"), "[REDACTED]")
        XCTAssertEqual(redactor.headerValue(name: "cookie", value: "sid=1"), "[REDACTED]")
        XCTAssertEqual(redactor.headerValue(name: "X-API-Key", value: "k123"), "[REDACTED]")
        XCTAssertEqual(redactor.headerValue(name: "Accept", value: "application/json"), "application/json")
    }

    func testURLQueryAndUserInfo() {
        let url = redactor.url("https://user:hunter2@test.example:8443/path?token=abc123&page=2&api_key=zzz")
        XCTAssertFalse(url.contains("hunter2"))
        XCTAssertFalse(url.contains("abc123"))
        XCTAssertFalse(url.contains("zzz"))
        XCTAssertTrue(url.contains("page=2"))
        XCTAssertTrue(url.contains("test.example:8443/path"))
    }

    func testFreeTextPatterns() {
        XCTAssertEqual(redactor.text("Authorization: Bearer eyJhbGciOi.payload.sig"), "Authorization: [REDACTED]")
        XCTAssertFalse(redactor.text("sent with bearer abcdef123456 today").contains("abcdef123456"))
        let json = redactor.text(#"{"user":"ana","password":"p@ss \"quoted\"","access_token":"tok","count":3,"pin_secret":1234}"#)
        XCTAssertFalse(json.contains("p@ss"))
        XCTAssertFalse(json.contains("tok\""))
        XCTAssertFalse(json.contains("1234"))
        XCTAssertTrue(json.contains(#""user":"ana""#))
        XCTAssertTrue(json.contains(#""count":3"#))
        let form = redactor.text("name=ana&password=s3cret&session_id=77")
        XCTAssertEqual(form, "name=ana&password=[REDACTED]&session_id=[REDACTED]")
        XCTAssertFalse(redactor.text("GET http://bob:pw123@host/").contains("pw123"))
    }

    func testRedactionIsIdempotentAndLeavesOrdinaryTextAlone() {
        let once = redactor.text("token=abc Authorization: Basic Zm9vOmJhcg==")
        XCTAssertEqual(redactor.text(once), once)
        let plain = "Bluetooth LE scan started. 4 device(s) listed."
        XCTAssertEqual(redactor.text(plain), plain)
    }
}

final class ActivityLogTests: XCTestCase {
    func testEntriesAreRedactedBoundedAndNewestFirst() {
        let log = ActivityLog(capacity: 3)
        var sunk: [ActivityEntry] = []
        log.sink = { sunk.append($0) }
        log.record(.request, "Sent GET http://h/?token=abc")
        log.record(.system, "two")
        log.record(.system, "three")
        log.record(.bluetooth, "four", severity: .warning)
        XCTAssertEqual(log.entries.map { $0.message }, ["four", "three", "two"])
        XCTAssertEqual(log.entries.first?.severity, .warning)
        XCTAssertEqual(sunk.count, 4)
        XCTAssertFalse(sunk[0].message.contains("abc"))
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testDiagnosticFileAppendsRotatesAndDeletes() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sentinel-log-\(UUID().uuidString).log")
        let file = DiagnosticLogFile(url: url, maxBytes: 2048)
        let log = ActivityLog()
        log.sink = { file.append($0) }
        for index in 0..<200 { log.record(.system, "entry number \(index) password=hunter2") }
        let contents = file.contents()
        XCTAssertFalse(contents.contains("hunter2"))
        XCTAssertTrue(contents.contains("entry number 199"))
        XCTAssertFalse(contents.contains("entry number 0 "))
        XCTAssertLessThanOrEqual(file.byteCount, 2048)
        XCTAssertTrue(contents.hasSuffix("\n"))
        file.delete()
        XCTAssertEqual(file.byteCount, 0)
        XCTAssertEqual(file.contents(), "")
    }
}

final class OperationsAndSettingsTests: XCTestCase {
    func testStopAllStopsOnlyActiveRegisteredOperations() {
        let coordinator = OperationsCoordinator()
        var scanActive = true, requestActive = false, stubborn = true
        coordinator.register(OperationHandle(id: "ble", title: "Bluetooth scan", isActive: { scanActive }, stop: { scanActive = false }))
        coordinator.register(OperationHandle(id: "request", title: "Test request", isActive: { requestActive }, stop: { requestActive = false }))
        coordinator.register(OperationHandle(id: "stuck", title: "Stuck", isActive: { stubborn }, stop: {}))
        XCTAssertEqual(coordinator.activeOperations.map { $0.id }, ["ble", "stuck"])
        let report = coordinator.stopAll()
        XCTAssertEqual(report.stopped, ["Bluetooth scan"])
        XCTAssertEqual(report.stillActive, ["Stuck"])
        XCTAssertFalse(scanActive)
        stubborn = false
        XCTAssertEqual(coordinator.stopAll().summary, "Nothing was running.")
    }

    func testReRegisteringReplacesHandle() {
        let coordinator = OperationsCoordinator()
        coordinator.register(OperationHandle(id: "a", title: "Old", isActive: { true }, stop: {}))
        coordinator.register(OperationHandle(id: "a", title: "New", isActive: { true }, stop: {}))
        XCTAssertEqual(coordinator.activeOperations.map { $0.title }, ["New"])
    }

    func testDefaultsKeepActiveCollectionOff() {
        let settings = SentinelSettings()
        XCTAssertFalse(settings.scanningEnabled)
        XCTAssertFalse(settings.remoteConnectionsEnabled)
        XCTAssertFalse(settings.diagnosticLoggingEnabled)
        XCTAssertFalse(settings.previewMode)
        XCTAssertTrue(settings.testEndpoints.isEmpty)
        XCTAssertTrue(settings.animationsEnabled)
    }

    func testSettingsDecodeToleratesMissingAndInvalidValues() throws {
        let json = #"{"bluetoothScanningEnabled":true,"helperPort":80,"requestTimeoutSeconds":9999,"captureRetention":"forever","bluetoothAutoStopSeconds":17}"#
        let settings = try JSONDecoder().decode(SentinelSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.scanningEnabled, "the old Bluetooth switch migrates to Scanning")
        XCTAssertEqual(settings.helperPort, 47_655)
        XCTAssertEqual(settings.requestTimeoutSeconds, 120)
        XCTAssertEqual(settings.captureRetention, .sevenDays)
        XCTAssertEqual(settings.bluetoothAutoStopSeconds, 60)
        XCTAssertFalse(settings.remoteConnectionsEnabled)
    }

    func testLegacySettingsMigrate() throws {
        let json = #"{"radioNodeEnabled":false,"helperEnabled":true,"testEndpoint":"http://192.168.1.20:8080"}"#
        let settings = try JSONDecoder().decode(SentinelSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.remoteConnectionsEnabled, "either old connection switch migrates to Remote connections")
        XCTAssertEqual(settings.testEndpoints, ["http://192.168.1.20:8080"])
        let current = #"{"remoteConnectionsEnabled":false,"helperEnabled":true,"testEndpoints":[" http://a ","http://A","",""]}"#
        let decoded = try JSONDecoder().decode(SentinelSettings.self, from: Data(current.utf8))
        XCTAssertFalse(decoded.remoteConnectionsEnabled, "a stored new value wins over legacy keys")
        XCTAssertEqual(decoded.testEndpoints, ["http://a"], "trimmed, de-duplicated, blanks removed")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertNil(encoded["helperEnabled"], "legacy keys are not written back")
    }

    func testSettingsRoundTripThroughStore() {
        let suite = "sentinel-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(store.load(), SentinelSettings())
        var settings = SentinelSettings()
        settings.captureRetention = .untilDeleted
        settings.testEndpoints = ["http://127.0.0.1:8080"]
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
    }

    func testDeepLinksAreNavigationOnly() {
        XCTAssertEqual(DeepLink.section(from: URL(string: "hcgsentinel://open/bluetooth")!), .bluetooth)
        XCTAssertEqual(DeepLink.section(from: URL(string: "HCGSentinel://open/Settings")!), .settings)
        XCTAssertEqual(DeepLink.section(from: URL(string: "hcgsentinel://open/networkcheck")!), .networkCheck)
        for section in SentinelSection.allCases {
            XCTAssertEqual(DeepLink.section(from: DeepLink.url(for: section)), section)
        }
        for rejected in ["hcgsentinel://start/bluetooth", "hcgsentinel://open/bluetooth?scan=1", "hcgsentinel://open/bluetooth/start",
                         "hcgsentinel://open/unknown", "https://open/bluetooth", "hcgsentinel://open/"] {
            XCTAssertNil(DeepLink.section(from: URL(string: rejected)!), rejected)
        }
    }

    func testNexusSnapshotCarriesOnlyCountsAndLabels() throws {
        let snapshot = NexusStatusSnapshot(generatedAt: Date(timeIntervalSince1970: 10), activeOperations: ["Bluetooth scan"],
                                           verifiedCapabilities: 2, totalCapabilities: 10, previewMode: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "generatedAt", "activeOperations", "verifiedCapabilities", "totalCapabilities", "previewMode"])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
    }
}
