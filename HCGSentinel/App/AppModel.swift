import Combine
import Foundation
import SentinelCore

/// Composition root. Owns the shared core objects, applies settings to every
/// tool, and backs the dashboard. Everything here runs on the main queue.
final class AppModel: ObservableObject {
    @Published var settings: SentinelSettings {
        didSet {
            guard settings != oldValue else { return }
            settingsDidChange(from: oldValue)
        }
    }
    @Published private(set) var capabilities: [CapabilityState] = []
    @Published private(set) var activity: [ActivityEntry] = []
    @Published private(set) var activeOperations: [String] = []
    @Published private(set) var diagnosticLogBytes = 0
    @Published var stopReport: String?

    let registry: CapabilityRegistry
    let log: ActivityLog
    let operations = OperationsCoordinator()
    let connection = ConnectionMonitor()
    let captureStore: CaptureStore
    let diagnosticFile: DiagnosticLogFile

    let bluetooth: BluetoothModel
    let network: NetworkModel
    let radio: RadioModel
    let requests: RequestModel
    let helper: HelperModel
    let networkCheck: NetworkCheckModel
    let securityLab: SecurityLabModel

    private let store: SettingsStore
    private var timer: Timer?

    init(store: SettingsStore = UserDefaultsSettingsStore()) {
        self.store = store
        let loaded = store.load()
        self.settings = loaded

        // Locals first, so nothing reads `self` before every stored property is set.
        let registry = CapabilityRegistry()
        let log = ActivityLog()
        self.registry = registry
        self.log = log

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let captureStore = CaptureStore(directory: support.appendingPathComponent("Captures", isDirectory: true))
        self.captureStore = captureStore
        diagnosticFile = DiagnosticLogFile(url: support.appendingPathComponent("Diagnostics/sentinel-activity.log"))

        bluetooth = BluetoothModel(central: CoreBluetoothCentral(), log: log, registry: registry)
        network = NetworkModel(store: captureStore, log: log, registry: registry)
        radio = RadioModel(transport: WebSocketNodeTransport(), log: log, registry: registry)
        requests = RequestModel(transport: URLSessionHTTPTransport(), log: log, registry: registry)
        helper = HelperModel(log: log, registry: registry)
        networkCheck = NetworkCheckModel(probe: PlatformNetworkProbe(), log: log, registry: registry)
        securityLab = SecurityLabModel(store: SecurityReportStore(directory: support.appendingPathComponent("SecurityLab/Reports", isDirectory: true)),
                                       log: log, registry: registry)

        registry.onChange = { [weak self] in self?.capabilities = self?.registry.states ?? [] }
        log.onChange = { [weak self] in
            if Thread.isMainThread { self?.refreshActivity() } else { DispatchQueue.main.async { self?.refreshActivity() } }
        }
        log.sink = { [weak self] entry in
            guard let self = self, self.settings.diagnosticLoggingEnabled else { return }
            self.diagnosticFile.append(entry)
        }

        registerOperations()
        for model in [bluetooth.objectWillChange, network.objectWillChange, radio.objectWillChange,
                      requests.objectWillChange, helper.objectWillChange, networkCheck.objectWillChange,
                      securityLab.objectWillChange] {
            model.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshOperations() }.store(in: &cancellables)
        }

        connection.onFirstUpdate = { [weak self] in
            self?.registry.recordVerified(.connectionDiagnostics, evidence: "iOS delivered a network path update for this app")
        }

        applySettings(loaded, initial: true)
        capabilities = registry.states
        diagnosticLogBytes = diagnosticFile.byteCount
    }

    private var cancellables = Set<AnyCancellable>()

    /// Called once when the first scene becomes active.
    func start() {
        guard timer == nil else { return }
        connection.start()
        let removed = captureStore.purgeExpired(policy: settings.captureRetention)
        if !removed.isEmpty {
            log.record(.network, "Retention removed \(removed.count) saved capture(s) older than \(settings.captureRetention.title)")
        }
        network.reload()
        log.record(.system, "Sentinel started. All active collection is off until you start it.")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        bluetooth.tick()
        radio.tick()
        refreshOperations()
    }

    // MARK: Operations

    private func registerOperations() {
        operations.register(OperationHandle(id: "bluetooth", title: "Bluetooth scan",
                                            isActive: { [bluetooth] in bluetooth.state.isActive },
                                            stop: { [bluetooth] in bluetooth.stop(reason: "Scan stopped by Stop All Operations") }))
        operations.register(OperationHandle(id: "request", title: "Test request",
                                            isActive: { [requests] in requests.isSending },
                                            stop: { [requests] in requests.cancel() }))
        operations.register(OperationHandle(id: "radio", title: "Radio node session",
                                            isActive: { [radio] in radio.state.isActive },
                                            stop: { [radio] in radio.disconnect(reason: "Node session closed by Stop All Operations") }))
        operations.register(OperationHandle(id: "helper", title: "Helper session",
                                            isActive: { [helper] in helper.state.isActive },
                                            stop: { [helper] in helper.disconnect() }))
        operations.register(OperationHandle(id: "networkcheck", title: "Network check",
                                            isActive: { [networkCheck] in networkCheck.isRunning },
                                            stop: { [networkCheck] in networkCheck.cancel() }))
        operations.register(OperationHandle(id: "securitylab", title: "Security Lab assessment",
                                            isActive: { [securityLab] in securityLab.isRunning },
                                            stop: { [securityLab] in securityLab.stop(reason: "Stopped by Stop All Operations") }))
        operations.register(OperationHandle(id: "authlab", title: "Authentication lab service",
                                            isActive: { [securityLab] in securityLab.labIsRunning },
                                            stop: { [securityLab] in securityLab.stopLab() }))
        operations.register(OperationHandle(id: "import", title: "Capture import",
                                            isActive: { [network] in network.isParsing },
                                            stop: { [network] in network.cancelImport() }))
    }

    /// Stops every Sentinel-owned scan, request and session. Saved captures,
    /// settings and system services are left exactly as they are.
    func stopAllOperations() {
        let report = operations.stopAll()
        log.record(.system, "Stop All Operations: \(report.summary)", severity: .notice)
        stopReport = report.summary
        refreshOperations()
    }

    private func refreshOperations() {
        let titles = operations.activeOperations.map { $0.title }
        if titles != activeOperations { activeOperations = titles }
    }

    // MARK: Settings

    private func settingsDidChange(from old: SentinelSettings) {
        store.save(settings)
        applySettings(settings, initial: false)
        if settings.previewMode && !old.previewMode {
            let report = operations.stopAll()
            log.record(.settings, "Preview mode on. Live tools paused. \(report.summary)", severity: .notice)
        } else if !settings.previewMode && old.previewMode {
            log.record(.settings, "Preview mode off. Demonstration data removed.")
        }
        if settings.scanningEnabled != old.scanningEnabled {
            log.record(.settings, settings.scanningEnabled
                       ? "Scanning on: you can now start Bluetooth scans and request Wi-Fi scans. Nothing starts by itself."
                       : "Scanning off: running Bluetooth and Wi-Fi scans were stopped")
        }
        if settings.remoteConnectionsEnabled != old.remoteConnectionsEnabled {
            log.record(.settings, settings.remoteConnectionsEnabled
                       ? "Remote connections on: you can now connect to your node and helper and send test requests. Nothing connects by itself."
                       : "Remote connections off: node and helper sessions closed and any test request cancelled")
        }
        if settings.animationsEnabled != old.animationsEnabled {
            log.record(.settings, settings.animationsEnabled ? "Animation on" : "Animation off")
        }
        if settings.diagnosticLoggingEnabled != old.diagnosticLoggingEnabled {
            log.record(.settings, settings.diagnosticLoggingEnabled
                       ? "Diagnostic logging on: redacted activity is now also written to a file in the app sandbox"
                       : "Diagnostic logging off: nothing further is written to the log file")
            diagnosticLogBytes = diagnosticFile.byteCount
        }
        refreshOperations()
    }

    private func applySettings(_ settings: SentinelSettings, initial: Bool) {
        bluetooth.apply(settings)
        network.apply(settings)
        networkCheck.apply(settings)
        securityLab.apply(settings)
        radio.apply(settings)
        requests.apply(settings)
        helper.apply(settings)

        registry.setUserEnabled(.connectionDiagnostics, true)
        registry.setUserEnabled(.captureFileInspection, true)
        registry.setUserEnabled(.networkAssessment, true)
        registry.setUserEnabled(.bluetoothDiscovery, settings.scanningEnabled)
        registry.setUserEnabled(.requestComposer, settings.remoteConnectionsEnabled && !requests.endpoints.isEmpty)
        registry.setUserEnabled(.radioNodeLink, settings.remoteConnectionsEnabled)
        registry.setUserEnabled(.radioSpectrum, settings.remoteConnectionsEnabled)
        registry.setUserEnabled(.nearbyWifiDiscovery, settings.remoteConnectionsEnabled && settings.scanningEnabled)
        registry.setUserEnabled(.helperLink, settings.remoteConnectionsEnabled)
        registry.setUserEnabled(.trafficFiltering, settings.remoteConnectionsEnabled)
        registry.setUserEnabled(.secretScanning, true)
        registry.setUserEnabled(.exposureCheck, settings.remoteConnectionsEnabled)
        registry.setUserEnabled(.authDefenseLab, true)
        registry.setUserEnabled(.serverAssessments, false)
    }

    // MARK: Diagnostics

    private func refreshActivity() {
        activity = log.entries
        if settings.diagnosticLoggingEnabled { diagnosticLogBytes = diagnosticFile.byteCount }
    }

    func deleteDiagnosticLog() {
        diagnosticFile.delete()
        diagnosticLogBytes = 0
        log.record(.settings, "Diagnostic log file deleted")
    }

    func clearActivity() {
        log.clear()
    }

    func capabilityState(_ id: CapabilityID) -> CapabilityState? {
        capabilities.first { $0.id == id }
    }

    var verifiedCapabilityCount: Int { capabilities.filter { $0.readiness == .verified }.count }

    /// Capabilities that can run or have a defined interface (feasibility research is not counted).
    var operationalCapabilityCount: Int { capabilities.filter { $0.descriptor.tier != .feasibility }.count }

    /// Status for HCG surfaces such as Nexus: counts, labels and report references only. Nexus has no Sentinel
    /// integration yet and Sentinel has no App Group, so this is built on request and not written anywhere.
    func statusSnapshot(now: Date = Date()) -> NexusStatusSnapshot {
        NexusStatusSnapshot(generatedAt: now, activeOperations: activeOperations, verifiedCapabilities: verifiedCapabilityCount,
                            totalCapabilities: operationalCapabilityCount, previewMode: settings.previewMode,
                            recentAssessments: securityLab.references)
    }
}

/// A report a link asked to open. Opening only shows the stored report.
struct ReportLink: Identifiable, Equatable {
    let id: UUID
}

/// Navigation state shared by the compact (tab) and regular (sidebar) layouts.
final class Router: ObservableObject {
    @Published var section: SentinelSection = .dashboard
    @Published var sheet: SentinelSection?
    @Published var pendingReport: ReportLink?
    var isCompact = true

    static let tabSections: [SentinelSection] = [.dashboard, .network, .bluetooth, .radio, .requests]

    /// Navigates only; never starts an operation.
    func open(_ target: SentinelSection) {
        if isCompact && !Router.tabSections.contains(target) {
            sheet = target
        } else {
            sheet = nil
            section = target
        }
    }

    /// Opens Security Lab with the stored report on top. Never runs anything.
    func openReport(_ id: UUID) {
        open(.securityLab)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.pendingReport = ReportLink(id: id) }
    }

    /// Handles `hcgsentinel://` links: navigation and report review only.
    func handle(_ url: URL) {
        switch DeepLink.target(from: url) {
        case .section(let section)?: open(section)
        case .report(let id)?: openReport(id)
        case nil: break
        }
    }

    func layoutChanged(compact: Bool) {
        isCompact = compact
        if compact && !Router.tabSections.contains(section) {
            section = .dashboard
        }
    }
}

extension SentinelSection {
    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .network: return "network"
        case .networkCheck: return "checkmark.shield"
        case .securityLab: return "shield.lefthalf.fill"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .radio: return "antenna.radiowaves.left.and.right"
        case .requests: return "paperplane"
        case .capabilities: return "checkmark.seal"
        case .settings: return "gearshape"
        }
    }

    var shortTitle: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .network: return "Network"
        case .networkCheck: return "Check"
        case .securityLab: return "Security Lab"
        case .bluetooth: return "Bluetooth"
        case .radio: return "Radio"
        case .requests: return "Requests"
        case .capabilities: return "Capabilities"
        case .settings: return "Settings"
        }
    }
}
