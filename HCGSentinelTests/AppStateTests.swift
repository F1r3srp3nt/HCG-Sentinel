import SentinelCore
import XCTest
@testable import HCGSentinel

/// App-level state tests. They run hosted inside the app on a simulator and
/// exercise the wiring between settings, tools and the capability registry.
final class AppStateTests: XCTestCase {
    private func makeApp(_ settings: SentinelSettings = SentinelSettings()) -> (AppModel, InMemorySettingsStore) {
        let store = InMemorySettingsStore(settings)
        return (AppModel(store: store), store)
    }

    func testFreshStateIsIdleUnverifiedAndCollectingNothing() {
        let (app, _) = makeApp()
        XCTAssertTrue(app.activeOperations.isEmpty)
        XCTAssertEqual(app.verifiedCapabilityCount, 0)
        XCTAssertEqual(app.capabilities.count, CapabilityID.allCases.count)
        XCTAssertEqual(app.bluetooth.state, .idle)
        XCTAssertTrue(app.bluetooth.peripherals.isEmpty)
        XCTAssertEqual(app.radio.state, .disconnected)
        XCTAssertNil(app.radio.frame)
        XCTAssertEqual(app.requests.state, .idle)
        XCTAssertTrue(app.requests.endpoints.isEmpty)
        XCTAssertFalse(app.settings.scanningEnabled)
        XCTAssertFalse(app.settings.remoteConnectionsEnabled)
        XCTAssertFalse(app.networkCheck.isRunning, "Check My Network never starts by itself")
        XCTAssertNil(app.networkCheck.report)
        XCTAssertEqual(app.helper.state, .disconnected)
        XCTAssertEqual(app.capabilityState(.bluetoothDiscovery)?.readiness, .disabled)
        XCTAssertEqual(app.capabilityState(.deviceWideCapture)?.readiness, .interfaceOnly)
    }

    func testBluetoothScanIsBlockedUntilEnabledInSettings() {
        let (app, _) = makeApp()
        app.bluetooth.start()
        XCTAssertEqual(app.bluetooth.state, .blocked(.disabledInSettings))
        XCTAssertTrue(app.activeOperations.isEmpty)
        app.settings.scanningEnabled = true
        XCTAssertEqual(app.bluetooth.state, .idle, "enabling the setting clears the notice but must not start a scan")
        XCTAssertNotEqual(app.capabilityState(.bluetoothDiscovery)?.readiness, .verified)
    }

    func testSettingsArePersistedAndDriveCapabilities() {
        let (app, store) = makeApp()
        app.settings.remoteConnectionsEnabled = true
        app.settings.testEndpoints = ["http://127.0.0.1:8080"]
        XCTAssertTrue(store.load().remoteConnectionsEnabled)
        XCTAssertEqual(app.requests.endpoints.first?.host, "127.0.0.1")
        XCTAssertEqual(app.requests.draft.url, "http://127.0.0.1:8080/", "a fresh draft starts at the primary endpoint")
        XCTAssertEqual(app.capabilityState(.requestComposer)?.readiness, .ready)
        XCTAssertEqual(app.capabilityState(.radioNodeLink)?.readiness, .environmentUnknown)
        XCTAssertEqual(app.capabilityState(.nearbyWifiDiscovery)?.readiness, .disabled, "Wi-Fi discovery also needs Scanning")
        app.settings.scanningEnabled = true
        XCTAssertEqual(app.capabilityState(.nearbyWifiDiscovery)?.readiness, .environmentUnknown, "still unverified without a node")
        app.settings.testEndpoints = ["not a url"]
        XCTAssertTrue(app.requests.endpoints.isEmpty)
        XCTAssertEqual(app.requests.endpointProblems.count, 1)
        XCTAssertEqual(app.capabilityState(.requestComposer)?.readiness, .disabled)
    }

    func testRequestsNeedEndpointAndRemoteConnections() {
        let (app, _) = makeApp()
        XCTAssertFalse(app.requests.canSend)
        app.requests.send()
        XCTAssertEqual(app.requests.state, .idle, "nothing is sent without an endpoint")
        app.settings.testEndpoints = ["http://127.0.0.1:9"]
        XCTAssertFalse(app.requests.canSend, "Remote connections are still off")
        app.requests.send()
        XCTAssertEqual(app.requests.state, .idle)
        XCTAssertTrue(app.activeOperations.isEmpty)
        if case .failure(let error) = app.requests.prepare() {
            XCTFail("the draft itself is valid: \(error)")
        }
        app.requests.draft.url = "https://elsewhere.example/"
        XCTAssertEqual(app.requests.prepare().failureValue, .offEndpoint)
    }

    func testRadioStaysDisconnectedWithoutRemoteConnectionsOrKey() {
        let (app, _) = makeApp()
        app.radio.connect()
        XCTAssertEqual(app.radio.state, .disconnected)
        XCTAssertFalse(app.radio.canConnect)
        app.settings.remoteConnectionsEnabled = true
        app.radio.connect()
        XCTAssertEqual(app.radio.state, .disconnected, "no pairing key or address was configured")
        XCTAssertNotNil(app.radio.errorMessage)
        XCTAssertFalse(app.radio.setPairingKey("abcd"))
    }

    func testFilteringExplainsWhatIsMissing() {
        let (app, _) = makeApp()
        XCTAssertFalse(app.helper.canUseFiltering)
        XCTAssertTrue(app.helper.filteringRequirement?.contains("Remote connections") ?? false)
        app.settings.remoteConnectionsEnabled = true
        XCTAssertFalse(app.helper.canUseFiltering)
        XCTAssertNotNil(app.helper.filteringRequirement)
        var message: String?
        app.helper.applyFilterRules([FilterRule(id: "r1", action: "block", transport: "tcp", remoteAddress: "203.0.113.1")]) { message = $0 }
        XCTAssertNotNil(message, "the request is refused with an explanation, not sent")
        XCTAssertEqual(app.helper.state, .disconnected)
    }

    func testTurningSwitchesOffStopsTheirOperations() {
        var settings = SentinelSettings()
        settings.scanningEnabled = true
        settings.remoteConnectionsEnabled = true
        let (app, _) = makeApp(settings)
        app.settings.scanningEnabled = false
        XCTAssertFalse(app.bluetooth.state.isActive)
        app.settings.remoteConnectionsEnabled = false
        XCTAssertFalse(app.radio.state.isActive)
        XCTAssertFalse(app.helper.state.isActive)
        XCTAssertFalse(app.requests.isSending)
        XCTAssertTrue(app.activity.contains { $0.message.contains("Remote connections off") })
        XCTAssertTrue(app.activity.contains { $0.message.contains("Scanning off") })
    }

    func testPreviewModePausesLiveToolsAndVerifiesNothing() {
        var settings = SentinelSettings()
        settings.scanningEnabled = true
        settings.remoteConnectionsEnabled = true
        settings.testEndpoints = ["http://127.0.0.1:9"]
        let (app, _) = makeApp(settings)
        app.settings.previewMode = true
        app.bluetooth.start()
        XCTAssertEqual(app.bluetooth.state, .idle)
        app.requests.send()
        XCTAssertEqual(app.requests.state, .idle)
        app.networkCheck.start()
        XCTAssertFalse(app.networkCheck.isRunning, "Check My Network does not run in Preview mode")
        app.network.openPreview()
        XCTAssertNotNil(app.network.open)
        XCTAssertEqual(app.verifiedCapabilityCount, 0, "demonstration data must never verify a capability")
        XCTAssertTrue(app.network.saved.isEmpty || app.network.open?.stored == nil)
        app.settings.previewMode = false
        XCTAssertNil(app.network.open, "demonstration data is removed when Preview mode ends")
    }

    func testStopAllWithNothingRunningLeavesSettingsAlone() {
        var settings = SentinelSettings()
        settings.captureRetention = .untilDeleted
        let (app, store) = makeApp(settings)
        app.stopAllOperations()
        XCTAssertEqual(app.stopReport, "Nothing was running.")
        XCTAssertEqual(store.load(), settings)
        XCTAssertEqual(app.settings, settings)
    }

    func testRouterSendsSecondarySectionsToSheetOnlyInCompactLayout() {
        let router = Router()
        router.layoutChanged(compact: true)
        router.open(.settings)
        XCTAssertEqual(router.sheet, .settings)
        XCTAssertEqual(router.section, .dashboard)
        router.open(.bluetooth)
        XCTAssertNil(router.sheet)
        XCTAssertEqual(router.section, .bluetooth)

        router.layoutChanged(compact: false)
        router.open(.capabilities)
        XCTAssertNil(router.sheet)
        XCTAssertEqual(router.section, .capabilities)
        router.layoutChanged(compact: true)
        XCTAssertEqual(router.section, .dashboard, "a section without a tab falls back to the dashboard")
    }

    func testHelperPairingKeyValidation() {
        let (app, _) = makeApp()
        XCTAssertFalse(app.helper.setPairingKey("too short"))
        XCTAssertFalse(app.helper.setPairingKey(String(repeating: "zz", count: 32)))
        XCTAssertFalse(app.helper.setPairingKey(String(repeating: "a", count: 63)))
    }

    func testPreviewDataIsWellFormed() throws {
        XCTAssertEqual(PreviewData.peripherals().count, 3)
        XCTAssertNoThrow(try NodeCodec.validate(PreviewData.spectrum()))
        XCTAssertFalse(DeviceInfo.modelIdentifier.isEmpty)
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
