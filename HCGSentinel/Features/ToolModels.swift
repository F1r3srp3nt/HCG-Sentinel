import Foundation
import SentinelCore

// MARK: - Bluetooth

final class BluetoothModel: ObservableObject {
    @Published private(set) var state: BluetoothScanState = .idle
    @Published private(set) var peripherals: [DiscoveredPeripheral] = []
    @Published private(set) var autoStopDeadline: Date?
    @Published private(set) var previewMode = false
    @Published private(set) var enabledInSettings = false

    private let controller: BluetoothScanController
    private let log: ActivityLog
    private let registry: CapabilityRegistry
    private var publishScheduled = false

    init(central: BluetoothCentral, log: ActivityLog, registry: CapabilityRegistry) {
        self.controller = BluetoothScanController(central: central)
        self.log = log
        self.registry = registry
        controller.onChange = { [weak self] in self?.controllerChanged() }
        controller.onStateEvent = { [weak log] message, severity in log?.record(.bluetooth, message, severity: severity) }
        controller.onFirstDiscovery = { [weak registry] in
            registry?.recordVerified(.bluetoothDiscovery, evidence: "A Bluetooth LE advertisement was received during a scan")
        }
    }

    func apply(_ settings: SentinelSettings) {
        previewMode = settings.previewMode
        enabledInSettings = settings.scanningEnabled
        controller.isEnabledInSettings = settings.scanningEnabled && !settings.previewMode
        controller.allowDuplicates = settings.bluetoothContinuousUpdates
        controller.autoStopInterval = TimeInterval(settings.bluetoothAutoStopSeconds)
        if !controller.isEnabledInSettings && controller.state.isActive {
            controller.stop(reason: "Bluetooth scan stopped because Scanning was turned off")
        }
        if settings.scanningEnabled, case .blocked(.disabledInSettings) = controller.state {
            controller.stop()
        }
    }

    func start() {
        guard !previewMode else { return }
        controller.start()
    }

    func stop(reason: String = "Scan stopped") {
        controller.stop(reason: reason)
    }

    func clear() {
        controller.clearResults()
        log.record(.bluetooth, "Discovered device list cleared")
    }

    func tick() {
        controller.tick()
    }

    private func controllerChanged() {
        if controller.state != state {
            publish()
            updateEnvironment()
        } else if !publishScheduled {
            // Advertisements can arrive many times per second; coalesce list updates.
            publishScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.publish() }
        }
    }

    private func publish() {
        publishScheduled = false
        state = controller.state
        peripherals = controller.sortedPeripherals
        autoStopDeadline = controller.autoStopDeadline
    }

    private func updateEnvironment() {
        switch controller.state {
        case .scanning:
            registry.setEnvironment(.bluetoothDiscovery, .supported)
        case .blocked(let blocker) where blocker != .disabledInSettings:
            registry.setEnvironment(.bluetoothDiscovery, .unsupported("\(blocker.title). \(blocker.guidance)"))
        default:
            break
        }
    }
}

// MARK: - Network inspector

struct OpenCapture: Identifiable {
    enum Source {
        case importedFile
        case preview
    }

    let id = UUID()
    let name: String
    let source: Source
    let capture: ParsedCapture
    let stored: StoredCapture?
}

final class NetworkModel: ObservableObject {
    @Published private(set) var saved: [StoredCapture] = []
    @Published private(set) var isParsing = false
    @Published private(set) var retention = RetentionPolicy.sevenDays
    @Published private(set) var previewMode = false
    @Published var open: OpenCapture?
    @Published var errorMessage: String?

    private let store: CaptureStore
    private let log: ActivityLog
    private let registry: CapabilityRegistry
    private var generation = 0

    init(store: CaptureStore, log: ActivityLog, registry: CapabilityRegistry) {
        self.store = store
        self.log = log
        self.registry = registry
    }

    func apply(_ settings: SentinelSettings) {
        retention = settings.captureRetention
        previewMode = settings.previewMode
        if !settings.previewMode, case .preview? = open?.source { open = nil }
    }

    func reload() {
        saved = store.list()
    }

    /// Imports a file chosen in the document picker (already a private copy).
    func importFile(at url: URL) {
        guard !isParsing else { return }
        let name = url.lastPathComponent
        let limit = CaptureLimits.default.maxFileBytes
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= limit else {
            try? FileManager.default.removeItem(at: url)
            return fail(name, CaptureParseError.fileTooLarge(size: size, limit: limit).userMessage)
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return fail(name, "The file could not be read.")
        }
        let owned = Data(data) // Detach from the temporary file before it is removed.
        try? FileManager.default.removeItem(at: url)
        parse(owned, name: name, stored: nil, saveAfterParsing: retention.savesImports)
    }

    func openSaved(_ item: StoredCapture) {
        guard !isParsing else { return }
        do {
            parse(try store.data(for: item), name: item.originalName, stored: item, saveAfterParsing: false)
        } catch {
            fail(item.originalName, "The saved capture could not be read. It may have been removed.")
            reload()
        }
    }

    func openPreview() {
        guard let capture = try? CaptureParser.parse(SyntheticCapture.demoCapture()) else { return }
        open = OpenCapture(name: "Demonstration capture", source: .preview, capture: capture, stored: nil)
    }

    func cancelImport() {
        guard isParsing else { return }
        generation += 1
        isParsing = false
        log.record(.network, "Capture import cancelled")
    }

    func delete(_ item: StoredCapture) {
        do {
            try store.delete(id: item.id)
            log.record(.network, "Deleted saved capture “\(item.originalName)”")
        } catch {
            errorMessage = "The capture could not be deleted."
        }
        if open?.stored?.id == item.id { open = nil }
        reload()
    }

    func deleteAll() {
        do {
            let count = try store.deleteAll()
            log.record(.network, "Deleted all \(count) saved capture(s)", severity: .notice)
        } catch {
            errorMessage = "The saved captures could not be deleted."
        }
        if open?.stored != nil { open = nil }
        reload()
    }

    var savedByteCount: Int { saved.reduce(0) { $0 + $1.byteCount } }

    private func parse(_ data: Data, name: String, stored: StoredCapture?, saveAfterParsing: Bool) {
        generation += 1
        let current = generation
        isParsing = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try CaptureParser.parse(data) }
            DispatchQueue.main.async {
                guard let self = self, self.generation == current else { return }
                self.isParsing = false
                switch result {
                case .success(let capture):
                    var record = stored
                    if saveAfterParsing {
                        record = try? self.store.save(data, originalName: name, format: capture.format, packetCount: capture.packets.count)
                        if record == nil { self.errorMessage = "The capture opened, but could not be saved for later." }
                        self.reload()
                    }
                    self.registry.recordVerified(.captureFileInspection,
                                                 evidence: "Parsed an imported \(capture.format.displayName) file with \(capture.packets.count) packet(s)")
                    let early = capture.stoppedEarly ? ", stopped early" : ""
                    let kept = (saveAfterParsing && record != nil) ? ", saved" : ", not saved"
                    self.log.record(.network, "Opened capture file “\(name)”: \(capture.format.displayName), \(capture.packets.count) packet(s)\(early)\(kept)")
                    self.open = OpenCapture(name: record?.originalName ?? name, source: .importedFile, capture: capture, stored: record)
                case .failure(let error):
                    let message = (error as? CaptureParseError)?.userMessage ?? "The file could not be parsed."
                    self.fail(name, message)
                }
            }
        }
    }

    private func fail(_ name: String, _ message: String) {
        errorMessage = message
        log.record(.network, "Could not open “\(name)”: \(message)", severity: .warning)
    }
}

// MARK: - Radio lab

final class RadioModel: ObservableObject {
    @Published private(set) var state: RadioNodeState = .disconnected
    @Published private(set) var node: NodeInfo?
    @Published private(set) var capabilities: NodeCapabilities?
    @Published private(set) var status: NodeStatus?
    @Published private(set) var frame: SpectrumFrame?
    @Published private(set) var framesReceived = 0
    @Published private(set) var wifiScan: WifiScanResult?
    @Published private(set) var wifiScanPending = false
    @Published private(set) var wifiScanError: String?
    @Published private(set) var remoteConnectionsEnabled = false
    @Published private(set) var scanningEnabled = false
    @Published private(set) var previewMode = false
    @Published private(set) var address = ""
    @Published private(set) var hasPairingKey = Keychain.has(.nodePairingKey)
    @Published var errorMessage: String?
    @Published var centerMHz = "100.0"
    @Published var spanMHz = "2.0"
    @Published var selectedHardwareID = ""

    private let session: RadioNodeSession
    private let log: ActivityLog
    private let registry: CapabilityRegistry

    init(transport: NodeTransport, log: ActivityLog, registry: CapabilityRegistry) {
        self.session = RadioNodeSession(transport: transport, clientVersion: DeviceInfo.appVersion)
        self.log = log
        self.registry = registry
        session.onChange = { [weak self] in self?.sync() }
        session.onLog = { [weak log] message, severity in log?.record(.radio, message, severity: severity) }
        session.onLinkVerified = { [weak registry] node, capabilities in
            guard let registry = registry else { return }
            registry.setEnvironment(.radioNodeLink, .supported)
            let kind = node.simulated ? " (simulated data source)" : ""
            registry.recordVerified(.radioNodeLink, evidence: "Authenticated protocol v\(NodeProtocol.version) handshake with node “\(node.nodeName)”\(kind)")
            let features = capabilities.recognizedFeatures
            if node.simulated {
                let reason = "The connected node is a simulator. Its data is labelled simulated and proves nothing about real hardware."
                registry.setEnvironment(.radioSpectrum, .unknown(reason))
                registry.setEnvironment(.nearbyWifiDiscovery, .unknown(reason))
            } else {
                registry.setEnvironment(.radioSpectrum, features.contains(NodeProtocol.spectrumFeature)
                    ? .unknown("The node offers spectrum; confirmed by the first valid frame.")
                    : .unsupported("The connected node does not offer the spectrum feature."))
                registry.setEnvironment(.nearbyWifiDiscovery, features.contains(NodeProtocol.wifiScanFeature)
                    ? .unknown("The node offers Wi-Fi scanning; confirmed by the first valid scan.")
                    : .unsupported("The connected node does not offer Wi-Fi scanning."))
            }
        }
        session.onHardwareSpectrumVerified = { [weak registry] in
            registry?.setEnvironment(.radioSpectrum, .supported)
            registry?.recordVerified(.radioSpectrum, evidence: "A valid spectrum frame arrived from an authenticated node reporting real radio hardware")
        }
        session.onWifiScanVerified = { [weak registry] scan in
            registry?.setEnvironment(.nearbyWifiDiscovery, .supported)
            registry?.recordVerified(.nearbyWifiDiscovery, evidence: "An authenticated, non-simulated node returned a valid scan of \(scan.networks.count) network(s)")
        }
    }

    var isSimulatedNode: Bool { session.isSimulatedNode }
    var canConnect: Bool { remoteConnectionsEnabled && !previewMode && hasPairingKey && !address.isEmpty }
    var offersWifiScan: Bool { session.supports(NodeProtocol.wifiScanFeature) }

    func apply(_ settings: SentinelSettings) {
        remoteConnectionsEnabled = settings.remoteConnectionsEnabled
        scanningEnabled = settings.scanningEnabled
        previewMode = settings.previewMode
        address = settings.radioNodeAddress
        if (!remoteConnectionsEnabled || previewMode) && session.state.isActive {
            session.disconnect(reason: "Node session closed because Remote connections was turned off")
        }
        if (!scanningEnabled || previewMode) && session.isWifiScanPending {
            session.cancelWifiScan()
            log.record(.radio, "Wi-Fi scan request cancelled because Scanning was turned off")
        }
    }

    /// Stores the node's pairing key (hex). Returns false when it is not at least 32 bytes of hex.
    func setPairingKey(_ text: String) -> Bool {
        guard let key = NodeAuth.pairingKey(fromHex: text) else { return false }
        Keychain.write(Data(key), for: .nodePairingKey)
        hasPairingKey = Keychain.has(.nodePairingKey)
        return hasPairingKey
    }

    func removePairingKey() {
        Keychain.delete(.nodePairingKey)
        hasPairingKey = false
        if session.state.isActive { session.disconnect(reason: "Node session closed because the pairing key was removed") }
    }

    func connect() {
        guard remoteConnectionsEnabled, !previewMode else { return }
        errorMessage = nil
        guard let key = Keychain.read(.nodePairingKey) else {
            errorMessage = RadioNodeError.pairingKeyRequired.userMessage
            return
        }
        do {
            try session.connect(to: address, pairingKey: [UInt8](key))
        } catch {
            errorMessage = (error as? RadioNodeError)?.userMessage ?? "Could not connect."
        }
    }

    func disconnect(reason: String = "Disconnected from node") {
        session.disconnect(reason: reason)
    }

    func startSpectrum() {
        errorMessage = nil
        guard let center = Double(centerMHz.replacingOccurrences(of: ",", with: ".")),
              let span = Double(spanMHz.replacingOccurrences(of: ",", with: ".")) else {
            errorMessage = "Enter the centre frequency and span as numbers in MHz."
            return
        }
        let hardwareID = selectedHardwareID.isEmpty ? (capabilities?.hardware.first?.id ?? "") : selectedHardwareID
        let request = SpectrumRequest(hardwareID: hardwareID, centerFrequencyHz: center * 1_000_000, spanHz: span * 1_000_000,
                                      bins: min(512, capabilities?.maxBins ?? 512), maxFramesPerSecond: 5)
        do {
            try session.startSpectrum(request)
        } catch {
            errorMessage = (error as? RadioNodeError)?.userMessage ?? "The stream could not be started."
        }
    }

    func stopSpectrum() {
        session.stopSpectrum()
    }

    func requestWifiScan() {
        errorMessage = nil
        guard scanningEnabled, !previewMode else {
            errorMessage = "Turn on Scanning in Settings to request a Wi-Fi scan."
            return
        }
        do {
            try session.requestWifiScan()
        } catch {
            errorMessage = (error as? RadioNodeError)?.userMessage ?? "The scan could not be requested."
        }
    }

    func cancelWifiScan() {
        session.cancelWifiScan()
    }

    var isWifiScanPending: Bool { session.isWifiScanPending }

    func tick() {
        session.tick()
    }

    private func sync() {
        let wasActive = state.isActive
        let wasAuthenticated = state.isAuthenticated
        if state != session.state { state = session.state }
        if node != session.node { node = session.node }
        if capabilities != session.capabilities { capabilities = session.capabilities }
        if status != session.status { status = session.status }
        frame = session.latestFrame
        framesReceived = session.framesReceived
        if wifiScan != session.latestWifiScan { wifiScan = session.latestWifiScan }
        wifiScanPending = session.isWifiScanPending
        wifiScanError = session.wifiScanError
        if case .failed(let reason) = session.state, wasActive {
            registry.recordFailure(.radioNodeLink, reason: reason)
            registry.resetVerification(.radioSpectrum)
            registry.resetVerification(.nearbyWifiDiscovery)
        } else if session.state == .disconnected, wasActive || wasAuthenticated {
            // A closed session is no longer evidence that a node is reachable.
            registry.resetVerification(.radioNodeLink)
            registry.resetVerification(.radioSpectrum)
            registry.resetVerification(.nearbyWifiDiscovery)
        }
    }
}

// MARK: - Request composer

final class RequestModel: ObservableObject {
    @Published var draft = RequestDraft.template
    @Published private(set) var state: RequestComposer.State = .idle
    @Published private(set) var endpoints: [TestEndpoint] = []
    @Published private(set) var endpointProblems: [String] = []
    @Published private(set) var remoteConnectionsEnabled = false
    @Published private(set) var previewMode = false
    @Published var bodyFormat: ResponseBodyFormat = .text

    private let composer: RequestComposer
    private let registry: CapabilityRegistry
    private var timeout: TimeInterval = 30

    init(transport: HTTPTransport, log: ActivityLog, registry: CapabilityRegistry) {
        self.composer = RequestComposer(transport: transport, log: log)
        self.registry = registry
        composer.onChange = { [weak self] in
            guard let self = self else { return }
            self.state = self.composer.state
            if case .failed(.execution(let error)) = self.composer.state, error != .cancelled {
                self.registry.recordFailure(.requestComposer, reason: error.userMessage)
            }
        }
        composer.onResponse = { [weak self] response in
            guard let self = self else { return }
            self.bodyFormat = ResponseFormatter.suggestedFormat(for: response.body)
            self.registry.recordVerified(.requestComposer, evidence: "A test endpoint answered a Sentinel request with HTTP \(response.statusCode)")
        }
    }

    var isSending: Bool { composer.isSending }
    var canSend: Bool { remoteConnectionsEnabled && !previewMode && !endpoints.isEmpty && !isSending }

    func apply(_ settings: SentinelSettings) {
        previewMode = settings.previewMode
        timeout = TimeInterval(settings.requestTimeoutSeconds)
        let parsed = TestEndpoint.parseList(settings.testEndpoints)
        if parsed.endpoints != endpoints {
            if composer.isSending { composer.cancel() }
            endpoints = parsed.endpoints
            registry.resetVerification(.requestComposer)
        }
        endpointProblems = parsed.problems
        let wasEnabled = remoteConnectionsEnabled
        remoteConnectionsEnabled = settings.remoteConnectionsEnabled
        if wasEnabled && !remoteConnectionsEnabled && composer.isSending {
            composer.cancel()
        }
        // A fresh draft starts at the primary endpoint's root.
        if draft.url == "/", let primary = endpoints.first {
            draft.url = primary.displayString + "/"
        }
    }

    /// Validates the draft and describes exactly what Send would transmit.
    func prepare() -> Result<PreparedRequest, RequestValidationError> {
        do {
            return .success(try RequestBuilder.prepare(draft, endpoints: endpoints))
        } catch {
            return .failure((error as? RequestValidationError) ?? .invalidURL)
        }
    }

    var changes: [RequestChange] {
        var baseline = RequestDraft.template
        if let primary = endpoints.first { baseline.url = primary.displayString + "/" }
        return RequestPreview.changes(from: baseline, to: draft)
    }

    func send() {
        guard canSend else { return }
        composer.send(draft, endpoints: endpoints, timeout: timeout)
    }

    func cancel() {
        composer.cancel()
    }

    func resetDraft() {
        draft = .template
        if let primary = endpoints.first { draft.url = primary.displayString + "/" }
        composer.reset()
    }
}

// MARK: - Privileged helper

final class HelperModel: ObservableObject {
    enum ProbeResult: Equatable {
        case notProbed
        case noAnswer(String)
        case verified(HelperCapabilityReport, Date)
    }

    @Published private(set) var state: HelperClientState = .disconnected
    @Published private(set) var report: HelperCapabilityReport?
    @Published private(set) var probeResult: ProbeResult = .notProbed
    @Published private(set) var remoteConnectionsEnabled = false
    @Published private(set) var previewMode = false
    @Published private(set) var hasPairingKey = Keychain.has(.helperPairingKey)
    @Published private(set) var port = 47_655
    @Published private(set) var operationInFlight: HelperOperation?
    @Published var message: String?

    private let transport: LoopbackHelperTransport
    private let client: HelperClient
    private let log: ActivityLog
    private let registry: CapabilityRegistry
    private var pending: (operation: HelperOperation, body: Data, completion: (Result<Data, HelperClientError>) -> Void)?

    init(log: ActivityLog, registry: CapabilityRegistry) {
        let transport = LoopbackHelperTransport(port: 47_655)
        self.transport = transport
        self.client = HelperClient(transport: transport)
        self.log = log
        self.registry = registry
        client.onChange = { [weak self] in self?.sync() }
        client.onLog = { [weak log] message, severity in log?.record(.helper, message, severity: severity) }
    }

    /// Operations the last authenticated helper report listed that Sentinel recognises.
    var verifiedOperations: Set<HelperOperation> {
        if case .verified(let report, _) = probeResult { return report.recognizedOperations }
        return []
    }

    var canUseFiltering: Bool { remoteConnectionsEnabled && !previewMode && verifiedOperations.contains(.setFilterRules) }

    /// Why own-device filtering cannot be used right now, or nil when it can.
    var filteringRequirement: String? {
        if previewMode { return "Preview mode is on." }
        if !remoteConnectionsEnabled { return "Turn on Remote connections in Settings. Sentinel only contacts a helper when it is on." }
        if !hasPairingKey { return "Add the pairing key from your helper installation in Settings, then probe for the helper." }
        switch probeResult {
        case .notProbed:
            return "Probe for the helper in Settings. Filtering is offered only after an authenticated helper reports that it can apply rules."
        case .noAnswer(let reason):
            return "No helper answered the last probe (\(reason)). Filtering needs a separately installed privileged helper; Sentinel does not include one, and none has been built yet."
        case .verified(let report, _):
            if !report.recognizedOperations.contains(.setFilterRules) {
                return "The helper authenticated but does not report setFilterRules, so it cannot apply filter rules."
            }
            return nil
        }
    }

    func apply(_ settings: SentinelSettings) {
        remoteConnectionsEnabled = settings.remoteConnectionsEnabled
        previewMode = settings.previewMode
        port = settings.helperPort
        transport.port = UInt16(clamping: settings.helperPort)
        if (!remoteConnectionsEnabled || previewMode) && client.state.isActive {
            client.disconnect()
            log.record(.helper, "Helper session closed because Remote connections was turned off")
        }
    }

    /// Accepts the pairing key as hexadecimal (at least 64 digits). Returns false when it is not valid.
    func setPairingKey(_ text: String) -> Bool {
        guard let key = NodeAuth.pairingKey(fromHex: text) else { return false }
        Keychain.write(Data(key), for: .helperPairingKey)
        hasPairingKey = Keychain.has(.helperPairingKey)
        return hasPairingKey
    }

    func removePairingKey() {
        Keychain.delete(.helperPairingKey)
        hasPairingKey = false
        probeResult = .notProbed
        registry.resetVerification(.helperLink)
        registry.resetVerification(.trafficFiltering)
        if client.state.isActive { client.disconnect() }
    }

    /// One user-triggered attempt: connect on loopback, authenticate, request a capability report, disconnect.
    func probe() {
        run(nil)
    }

    /// Sends filter rules through a verified helper. Never called unless `canUseFiltering`.
    func applyFilterRules(_ rules: [FilterRule], completion: @escaping (String) -> Void) {
        guard canUseFiltering else { return completion(filteringRequirement ?? "Filtering is not available.") }
        let body: Data
        do {
            body = try JSONEncoder().encode(FilterRulesParameters(rules: rules))
            try HelperRequestValidator.validate(operation: HelperOperation.setFilterRules.rawValue, body: body)
        } catch {
            return completion("The rules are not valid: addresses must be IP literals (optionally with /prefix), ports 1–65535, at most \(HelperRequestValidator.maxFilterRules) rules.")
        }
        run((HelperOperation.setFilterRules, body, { [weak self] result in
            switch result {
            case .success:
                self?.registry.setEnvironment(.trafficFiltering, .supported)
                self?.registry.recordVerified(.trafficFiltering, evidence: "The authenticated helper accepted \(rules.count) filter rule(s)")
                completion("The helper accepted \(rules.count) rule(s).")
            case .failure(let error):
                self?.registry.recordFailure(.trafficFiltering, reason: error.userMessage)
                completion(error.userMessage)
            }
        }))
    }

    func clearFilterRules(completion: @escaping (String) -> Void) {
        guard canUseFiltering, verifiedOperations.contains(.clearFilterRules) else {
            return completion(filteringRequirement ?? "The helper does not report clearFilterRules.")
        }
        run((HelperOperation.clearFilterRules, Data(), { result in
            switch result {
            case .success: completion("The helper removed its filter rules.")
            case .failure(let error): completion(error.userMessage)
            }
        }))
    }

    func disconnect() {
        client.disconnect()
    }

    private func run(_ operation: (HelperOperation, Data, (Result<Data, HelperClientError>) -> Void)?) {
        guard remoteConnectionsEnabled, !previewMode, !client.state.isActive else { return }
        message = nil
        guard let key = Keychain.read(.helperPairingKey) else {
            message = "Add the pairing key shown by your helper installation first."
            return
        }
        pending = operation.map { (operation: $0.0, body: $0.1, completion: $0.2) }
        operationInFlight = operation?.0
        log.record(.helper, operation == nil ? "Probing for a helper on 127.0.0.1:\(port)" : "Contacting the helper on 127.0.0.1:\(port) for \(operation!.0.rawValue)")
        do {
            try client.connect(pairingKey: [UInt8](key))
        } catch {
            message = (error as? HelperClientError)?.userMessage ?? "The helper could not be contacted."
            finishPending(.failure(.notReady))
        }
    }

    private func finishPending(_ result: Result<Data, HelperClientError>) {
        let waiting = pending
        pending = nil
        operationInFlight = nil
        waiting?.completion(result)
    }

    private func sync() {
        let previous = state
        state = client.state
        switch client.state {
        case .ready where previous != .ready:
            // Always refresh the capability report first; controls depend on what the helper reports now.
            client.reportCapabilities { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let report):
                    self.report = report
                    self.probeResult = .verified(report, Date())
                    self.registry.setEnvironment(.helperLink, .supported)
                    self.registry.recordVerified(.helperLink, evidence: "An authenticated helper session answered a capability report (helper \(report.helperVersion), \(report.packaging))")
                    self.registry.setEnvironment(.trafficFiltering, report.recognizedOperations.contains(.setFilterRules)
                        ? .unknown("The helper reports setFilterRules; confirmed when it accepts a rule set.")
                        : .unsupported("The authenticated helper does not report setFilterRules."))
                    let recognized = report.recognizedOperations.map { $0.rawValue }.sorted().joined(separator: ", ")
                    self.message = "Helper verified. Recognised operations: \(recognized.isEmpty ? "none" : recognized)."
                    if let pending = self.pending {
                        guard report.recognizedOperations.contains(pending.operation) else {
                            self.finishPending(.failure(.operationNotGranted))
                            self.client.disconnect()
                            return
                        }
                        self.client.request(pending.operation, body: pending.body) { [weak self] result in
                            self?.finishPending(result)
                            self?.client.disconnect()
                        }
                    } else {
                        self.client.disconnect()
                    }
                case .failure(let error):
                    self.message = error.userMessage
                    self.registry.recordFailure(.helperLink, reason: error.userMessage)
                    self.finishPending(.failure(error))
                    self.client.disconnect()
                }
            }
        case .failed(let reason) where previous.isActive:
            message = reason
            probeResult = .noAnswer(reason)
            registry.recordFailure(.helperLink, reason: reason)
            registry.setEnvironment(.trafficFiltering, .unsupported("No authenticated helper is available."))
            finishPending(.failure(.connectionLost(reason)))
        default:
            break
        }
    }
}
