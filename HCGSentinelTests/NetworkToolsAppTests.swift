import SentinelCore
import XCTest
#if SENTINEL_MODERN_TESTS
@testable import HCGSentinelModern
#else
@testable import HCGSentinel
#endif

/// Beta 2 network tools, as wired into the app: nothing starts by itself, bad input is refused before anything is
/// sent, and Stop All / leaving the foreground stop what runs.
final class NetworkToolsAppTests: XCTestCase {
    private func makeApp() -> AppModel {
        AppModel(store: InMemorySettingsStore(SentinelSettings()))
    }

    func testToolsAreIdleAtLaunch() {
        let app = makeApp()
        XCTAssertFalse(app.ping.isRunning)
        XCTAssertNil(app.ping.current)
        XCTAssertEqual(app.ping.status, .idle)
        XCTAssertFalse(app.localNetwork.isActive)
        XCTAssertEqual(app.localNetwork.status, .idle)
        XCTAssertTrue(app.localNetwork.services.isEmpty)
        XCTAssertFalse(app.localNetwork.authorizationConfirmed, "authorisation is never pre-confirmed")
        XCTAssertTrue(app.settings.bluetoothContinuousUpdates)
    }

    func testPingRefusesBadInputWithoutStarting() {
        let app = makeApp()
        app.ping.input = "https://example.com/x"
        app.ping.start()
        XCTAssertFalse(app.ping.isRunning)
        XCTAssertNotNil(app.ping.inputError)
        app.ping.input = "192.168.1.1"
        app.ping.useTCP = true
        app.ping.tcpPort = "99999"
        app.ping.start()
        XCTAssertFalse(app.ping.isRunning)
        XCTAssertEqual(app.ping.inputError, "Enter a TCP port from 1 to 65535.")
    }

    /// Runs the main run loop (where tool events are delivered) until the condition holds or time runs out.
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return condition()
    }

    func testPingRunsAgainstLoopbackAndStopAllStopsIt() {
        let app = makeApp()
        app.ping.input = "127.0.0.1"
        app.ping.count = 100
        app.ping.start()
        XCTAssertTrue(app.ping.isRunning)
        XCTAssertTrue(waitUntil(10) { !(app.ping.current?.results.isEmpty ?? true) || app.ping.current?.failure != nil },
                      "a real probe result (or a stated failure) arrives")
        if let run = app.ping.current, let first = run.results.first {
            print("SIMULATOR-PING 127.0.0.1 first probe: \(first.outcome)")
        }
        app.stopAllOperations()
        XCTAssertTrue(waitUntil(5) { !app.ping.isRunning })
        XCTAssertEqual(app.ping.history.first?.cancelled, true)
    }

    func testSweepRefusedWithoutConfirmationAndOutsideLocalNetworks() {
        let app = makeApp()
        let home = LocalInterfaceNetwork(interface: "en0", address: IPv4("192.168.1.23")!, network: IPv4Network("192.168.1.0/24")!)
        app.localNetwork.rangeInput = "192.168.1.0/24"
        app.localNetwork.startSweep(networks: [home])
        XCTAssertFalse(app.localNetwork.sweepRunning)
        XCTAssertEqual(app.localNetwork.sweepMessage, DiscoveryScope.Refusal.notConfirmed.message)
        app.localNetwork.authorizationConfirmed = true
        app.localNetwork.rangeInput = "8.8.8.0/24"
        app.localNetwork.startSweep(networks: [home])
        XCTAssertFalse(app.localNetwork.sweepRunning)
        XCTAssertTrue(app.localNetwork.sweepMessage?.contains("not a private") ?? false)
        XCTAssertEqual(app.localNetwork.suggestedRange(networks: [home]), "192.168.1.0/24")
    }

    func testBackgroundStopsActiveTools() {
        let app = makeApp()
        app.ping.input = "127.0.0.1"
        app.ping.count = 100
        app.ping.start()
        XCTAssertTrue(app.ping.isRunning)
        app.sceneDidEnterBackground()
        XCTAssertTrue(waitUntil(5) { !app.ping.isRunning })
    }
}
