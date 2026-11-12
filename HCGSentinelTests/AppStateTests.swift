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
        XCTAssertNil(app.requests.endpoint)
        XCTAssertEqual(app.helper.state, .disconnected)
        XCTAssertEqual(app.capabilityState(.bluetoothDiscovery)?.readiness, .disabled)
        XCTAssertEqual(app.capabilityState(.deviceWideCapture)?.readiness, .interfaceOnly)
    }

    func testBluetoothScanIsBlockedUntilEnabledInSettings() {
        let (app, _) = makeApp()
        app.bluetooth.start()
        XCTAssertEqual(app.bluetooth.state, .blocked(.disabledInSettings))
        XCTAssertTrue(app.activeOperations.isEmpty)
        app.settings.bluetoothScanningEnabled = true
        XCTAssertEqual(app.bluetooth.state, .idle, "enabling the setting clears the notice but must not start a scan")
        XCTAssertNotEqual(app.capabilityState(.bluetoothDiscovery)?.readiness, .verified)
    }

    func testSettingsArePersistedAndDriveCapabilities() {
        let (app, store) = makeApp()
        app.settings.radioNodeEnabled = true
        app.settings.testEndpoint = "http://127.0.0.1:8080"
        XCTAssertTrue(store.load().radioNodeEnabled)
        XCTAssertEqual(app.requests.endpoint?.host, "127.0.0.1")
        XCTAssertEqual(app.capabilityState(.requestComposer)?.readiness, .ready)
        XCTAssertEqual(app.capabilityState(.radioNodeLink)?.readiness, .environmentUnknown)
        app.settings.testEndpoint = "not a url"
        XCTAssertNil(app.requests.endpoint)
        XCTAssertNotNil(app.requests.endpointProblem)
        XCTAssertEqual(app.capabilityState(.requestComposer)?.readiness, .disabled)
    }

    func testRequestCannotBeSentWithoutEndpoint() {
        let (app, _) = makeApp()
        app.requests.send()
        XCTAssertEqual(app.requests.state, .failed(.validation(.noEndpoint)))
        XCTAssertFalse(app.requests.isSending)
    }

    func testRadioStaysDisconnectedWhenNodeIsOff() {
        let (app, _) = makeApp()
        app.radio.connect()
        XCTAssertEqual(app.radio.state, .disconnected)
        app.settings.radioNodeEnabled = true
        app.radio.connect()
        XCTAssertEqual(app.radio.state, .disconnected, "no address was configured")
        XCTAssertNotNil(app.radio.errorMessage)
    }

    func testPreviewModePausesLiveToolsAndVerifiesNothing() {
        var settings = SentinelSettings()
        settings.bluetoothScanningEnabled = true
        settings.testEndpoint = "http://127.0.0.1:9"
        let (app, _) = makeApp(settings)
        app.settings.previewMode = true
        app.bluetooth.start()
        XCTAssertEqual(app.bluetooth.state, .idle)
        app.requests.send()
        XCTAssertEqual(app.requests.state, .idle)
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
