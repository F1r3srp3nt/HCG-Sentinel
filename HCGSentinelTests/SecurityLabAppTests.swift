import SentinelCore
import XCTest
@testable import HCGSentinel

final class SecurityLabAppTests: XCTestCase {
    private func waitUntil(_ description: String, timeout: TimeInterval = 30, _ condition: @escaping () -> Bool) {
        let done = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        done.expectationDescription = description
        wait(for: [done], timeout: timeout)
    }

    func testCapabilitiesAreHonestAndSwitchesGateExposureCheck() {
        let app = AppModel(store: InMemorySettingsStore())
        XCTAssertEqual(app.capabilityState(.serverAssessments)?.readiness, .interfaceOnly)
        XCTAssertEqual(app.capabilityState(.secretScanning)?.readiness, .ready, "enabled but not yet verified by a real scan")
        XCTAssertEqual(app.capabilityState(.exposureCheck)?.readiness, .disabled, "needs Remote connections")

        app.securityLab.exposureEntries = [ExposureEntry(text: "https://service.example.com", localNetwork: false)]
        app.securityLab.authorizationConfirmed = true
        XCTAssertFalse(app.securityLab.canStartExposure, "Remote connections is off")
        app.settings.remoteConnectionsEnabled = true
        XCTAssertTrue(app.securityLab.canStartExposure)
        app.securityLab.authorizationConfirmed = false
        XCTAssertFalse(app.securityLab.canStartExposure, "authorisation must be confirmed")

        app.securityLab.authorizationConfirmed = true
        app.securityLab.exposureEntries = [ExposureEntry(text: "http://169.254.169.254/latest/meta-data/", localNetwork: true)]
        XCTAssertFalse(app.securityLab.canStartExposure, "metadata endpoints can never be entered")
    }

    func testReportLinksOpenReviewOnlyAndStopAllClosesTheLab() {
        let app = AppModel(store: InMemorySettingsStore())
        let router = Router()
        let id = UUID()
        router.handle(DeepLink.url(forReport: id))
        XCTAssertEqual(router.sheet, .securityLab)
        waitUntil("pending report") { router.pendingReport == ReportLink(id: id) }
        XCTAssertFalse(app.securityLab.isRunning, "a link never runs anything")
        router.handle(URL(string: "hcgsentinel://report/\(id.uuidString)?start=1")!)

        app.securityLab.startLab()
        XCTAssertTrue(app.securityLab.labIsRunning)
        XCTAssertTrue(app.activeOperations.contains("Authentication lab service") || app.operations.activeOperations.contains { $0.id == "authlab" })
        app.stopAllOperations()
        XCTAssertFalse(app.securityLab.labIsRunning)
    }

    func testLabAssessmentRunsThroughTheAppAndSnapshotCarriesOnlyReferences() throws {
        let app = AppModel(store: InMemorySettingsStore())
        let lab = app.securityLab
        lab.deleteAllReports()
        lab.startLab()
        defer { lab.stopLab() }
        lab.wrongPasswordsText = "not-the-password-1\nnot-the-password-2"
        lab.attemptCap = 3
        XCTAssertNil(lab.labPlanProblem)
        lab.startAuthAssessment()
        XCTAssertEqual(lab.running, .authDefenseLab)
        waitUntil("assessment finished", timeout: 40) { lab.running == nil }
        let record = try XCTUnwrap(lab.reports.first)
        XCTAssertEqual(record.module, .authDefenseLab)
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.location, .thisDevice)
        XCTAssertEqual(app.capabilityState(.authDefenseLab)?.readiness, .verified)

        let export = try XCTUnwrap(lab.exportFile(for: record))
        let text = try String(contentsOf: export)
        XCTAssertFalse(text.contains("not-the-password"))
        XCTAssertTrue(text.contains("## Limitations"))

        let snapshot = String(decoding: try JSONEncoder().encode(app.statusSnapshot()), as: UTF8.self)
        XCTAssertTrue(snapshot.contains(record.id.uuidString))
        XCTAssertFalse(snapshot.contains("lab-alice"), "no scope or evidence in the snapshot")
        XCTAssertFalse(snapshot.contains("127.0.0.1"))
        lab.deleteAllReports()
    }
}
