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
        enabledInSettings = settings.bluetoothScanningEnabled
        controller.isEnabledInSettings = settings.bluetoothScanningEnabled && !settings.previewMode
        controller.allowDuplicates = settings.bluetoothContinuousUpdates
        controller.autoStopInterval = TimeInterval(settings.bluetoothAutoStopSeconds)
        if !controller.isEnabledInSettings && controller.state.isActive {
            controller.stop(reason: "Scan stopped because scanning was turned off")
        }
        if settings.bluetoothScanningEnabled, case .blocked(.disabledInSettings) = controller.state {
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
    @Published private(set) var node: NodeHelloAck?
    @Published private(set) var capabilities: NodeCapabilities?
    @Published private(set) var status: NodeStatus?
    @Published private(set) var frame: SpectrumFrame?
    @Published private(set) var framesReceived = 0
    @Published private(set) var enabled = false
    @Published private(set) var previewMode = false
    @Published private(set) var address = ""
    @Published private(set) var hasToken = Keychain.has(.nodeToken)
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
        session.onLinkVerified = { [weak registry] ack in
            registry?.setEnvironment(.radioNodeLink, .supported)
            let kind = ack.simulated ? " (simulated data source)" : ""
            registry?.recordVerified(.radioNodeLink, evidence: "Protocol v\(ack.protocolVersion) handshake completed with node “\(ack.nodeName)”\(kind)")
            if ack.simulated {
                registry?.setEnvironment(.radioSpectrum, .unknown("The connected node is a simulator, not radio hardware. Its data is labelled simulated and proves nothing about real reception."))
            }
        }
        session.onHardwareSpectrumVerified = { [weak registry] in
            registry?.setEnvironment(.radioSpectrum, .supported)
            registry?.recordVerified(.radioSpectrum, evidence: "A valid spectrum frame arrived from a node reporting real radio hardware")
        }
    }

    var isSimulatedNode: Bool { session.isSimulatedNode }

    func apply(_ settings: SentinelSettings) {
        enabled = settings.radioNodeEnabled
        previewMode = settings.previewMode
        address = settings.radioNodeAddress
        if (!enabled || previewMode) && session.state.isActive {
            session.disconnect(reason: "Node session closed because the external node was turned off")
        }
    }

    func setToken(_ token: String) {
        if token.isEmpty {
            Keychain.delete(.nodeToken)
        } else {
            Keychain.write(Data(token.utf8), for: .nodeToken)
        }
        hasToken = Keychain.has(.nodeToken)
    }

    func connect() {
        guard enabled, !previewMode else { return }
        errorMessage = nil
        do {
            try session.connect(to: address, authToken: Keychain.readString(.nodeToken))
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

    func tick() {
        session.tick()
    }

    private func sync() {
        let wasActive = state.isActive
        if state != session.state { state = session.state }
        if node != session.node { node = session.node }
        if capabilities != session.capabilities { capabilities = session.capabilities }
        if status != session.status { status = session.status }
        frame = session.latestFrame
        framesReceived = session.framesReceived
        if case .failed(let reason) = session.state, wasActive {
            registry.recordFailure(.radioNodeLink, reason: reason)
            registry.resetVerification(.radioSpectrum)
        } else if session.state == .disconnected, wasActive {
            // A closed session is no longer evidence that a node is reachable.
            registry.resetVerification(.radioNodeLink)
            registry.resetVerification(.radioSpectrum)
        }
    }
}

// MARK: - Request composer

final class RequestModel: ObservableObject {
    @Published var draft = RequestDraft.template
    @Published private(set) var state: RequestComposer.State = .idle
    @Published private(set) var endpoint: TestEndpoint?
    @Published private(set) var endpointProblem: String?
    @Published private(set) var previewMode = false

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
            guard let self = self, let endpoint = self.endpoint else { return }
            self.registry.recordVerified(.requestComposer,
                                         evidence: "\(endpoint.host) answered a Sentinel request with HTTP \(response.statusCode)")
        }
    }

    var isSending: Bool { composer.isSending }

    func apply(_ settings: SentinelSettings) {
        previewMode = settings.previewMode
        timeout = TimeInterval(settings.requestTimeoutSeconds)
        let text = settings.testEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolved: TestEndpoint?
        var problem: String?
        if !text.isEmpty {
            do {
                resolved = try TestEndpoint(string: text)
            } catch {
                problem = (error as? RequestValidationError)?.userMessage ?? "The endpoint is not valid."
            }
        }
        if resolved != endpoint {
            if composer.isSending { composer.cancel() }
            endpoint = resolved
            registry.resetVerification(.requestComposer)
        }
        endpointProblem = problem
    }

    /// Validates the draft and describes exactly what Send would transmit.
    func prepare() -> Result<PreparedRequest, RequestValidationError> {
        do {
            return .success(try RequestBuilder.prepare(draft, endpoint: endpoint))
        } catch {
            return .failure((error as? RequestValidationError) ?? .invalidPath)
        }
    }

    var changes: [RequestChange] {
        RequestPreview.changes(from: .template, to: draft)
    }

    func send() {
        guard !previewMode else { return }
        composer.send(draft, endpoint: endpoint, timeout: timeout)
    }

    func cancel() {
        composer.cancel()
    }

    func resetDraft() {
        draft = .template
        composer.reset()
    }
}

// MARK: - Privileged helper

final class HelperModel: ObservableObject {
    @Published private(set) var state: HelperClientState = .disconnected
    @Published private(set) var report: HelperCapabilityReport?
    @Published private(set) var enabled = false
    @Published private(set) var hasPairingKey = Keychain.has(.helperPairingKey)
    @Published private(set) var port = 47_655
    @Published var message: String?

    private let transport: LoopbackHelperTransport
    private let client: HelperClient
    private let log: ActivityLog
    private let registry: CapabilityRegistry

    init(log: ActivityLog, registry: CapabilityRegistry) {
        let transport = LoopbackHelperTransport(port: 47_655)
        self.transport = transport
        self.client = HelperClient(transport: transport)
        self.log = log
        self.registry = registry
        client.onChange = { [weak self] in self?.sync() }
        client.onLog = { [weak log] message, severity in log?.record(.helper, message, severity: severity) }
        client.onVerified = { [weak registry] report in
            registry?.setEnvironment(.helperLink, .supported)
            registry?.recordVerified(.helperLink, evidence: "An authenticated helper session answered a capability report (helper \(report.helperVersion), \(report.packaging))")
        }
    }

    func apply(_ settings: SentinelSettings) {
        enabled = settings.helperEnabled && !settings.previewMode
        port = settings.helperPort
        transport.port = UInt16(clamping: settings.helperPort)
        if !enabled && client.state.isActive { client.disconnect() }
    }

    /// Accepts the pairing key as hexadecimal (at least 64 digits). Returns false when it is not valid.
    func setPairingKey(_ text: String) -> Bool {
        let cleaned = text.filter { !$0.isWhitespace }
        guard cleaned.count >= HelperProtocol.minimumKeyBytes * 2, cleaned.count % 2 == 0,
              cleaned.allSatisfy({ $0.isHexDigit }) else { return false }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return false }
            bytes.append(byte)
            index = next
        }
        Keychain.write(Data(bytes), for: .helperPairingKey)
        hasPairingKey = Keychain.has(.helperPairingKey)
        return hasPairingKey
    }

    func removePairingKey() {
        Keychain.delete(.helperPairingKey)
        hasPairingKey = false
        if client.state.isActive { client.disconnect() }
    }

    /// One user-triggered attempt: connect on loopback, authenticate, request a capability report, disconnect.
    func probe() {
        guard enabled, !client.state.isActive else { return }
        message = nil
        report = nil
        guard let key = Keychain.read(.helperPairingKey) else {
            message = "Add the pairing key shown by your helper installation first."
            return
        }
        log.record(.helper, "Probing for a helper on 127.0.0.1:\(port)")
        do {
            try client.connect(pairingKey: [UInt8](key))
        } catch {
            message = (error as? HelperClientError)?.userMessage ?? "The helper could not be contacted."
        }
    }

    func disconnect() {
        client.disconnect()
    }

    private func sync() {
        let previous = state
        state = client.state
        switch client.state {
        case .ready where previous != .ready:
            client.reportCapabilities { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let report):
                    self.report = report
                    self.message = "Helper verified. It reports \(report.supportedOperations.count) supported operation(s)."
                case .failure(let error):
                    self.message = error.userMessage
                    self.registry.recordFailure(.helperLink, reason: error.userMessage)
                }
                self.client.disconnect()
            }
        case .failed(let reason) where previous.isActive:
            message = reason
            registry.recordFailure(.helperLink, reason: reason)
        default:
            break
        }
    }
}
