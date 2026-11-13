import Foundation

public enum NodeTransportEvent: Equatable {
    case opened
    case text(String)
    case closed(String?)
    case failed(String)
}

/// A bidirectional text-message channel to a node (a WebSocket in the app).
public protocol NodeTransport: AnyObject {
    /// Events must be delivered on the main queue.
    var onEvent: ((NodeTransportEvent) -> Void)? { get set }
    func connect(to url: URL)
    func send(text: String)
    func close()
}

public enum RadioNodeState: Equatable {
    case disconnected
    case connecting
    /// `hello` sent; waiting for the node to prove it holds the pairing key.
    case authenticating
    /// Node verified; our proof sent; waiting for the node's authenticated `ready`.
    case awaitingReady
    case connected
    case streaming
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .disconnected, .failed: return false
        case .connecting, .authenticating, .awaitingReady, .connected, .streaming: return true
        }
    }

    /// True only after the authenticated capability handshake has completed.
    public var isAuthenticated: Bool { self == .connected || self == .streaming }

    public var title: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .authenticating: return "Verifying the node"
        case .awaitingReady: return "Completing handshake"
        case .connected: return "Connected (authenticated)"
        case .streaming: return "Streaming spectrum"
        case .failed: return "Connection failed"
        }
    }
}

public enum RadioNodeError: Error, Equatable {
    case invalidURL
    case pairingKeyRequired
    case notConnected
    case spectrumUnsupported
    case wifiScanUnsupported
    case scanInProgress
    case noHardware
    case unknownHardware
    case invalidRequest(String)

    public var userMessage: String {
        switch self {
        case .invalidURL: return "Enter a ws:// or wss:// node address."
        case .pairingKeyRequired: return "Enter the node’s pairing key (at least 64 hexadecimal digits). Radio Lab only connects to a node that proves it holds this key."
        case .notConnected: return "Connect to a node first."
        case .spectrumUnsupported: return "This node does not offer the spectrum feature."
        case .wifiScanUnsupported: return "This node does not offer Wi-Fi scanning."
        case .scanInProgress: return "A Wi-Fi scan is already in progress."
        case .noHardware: return "The node reports no radio hardware, so there is nothing to analyse."
        case .unknownHardware: return "The selected radio is not in the node’s hardware list."
        case .invalidRequest(let reason): return reason
        }
    }
}

/// Client side of the Sentinel Node Protocol v2. The session stays disconnected until `connect` is called and
/// is only considered connected after the node has proved it holds the pairing key and sent an authenticated
/// `ready`. It never reports data it did not receive over the authenticated session. Confine to the main queue.
public final class RadioNodeSession {
    public private(set) var state: RadioNodeState = .disconnected
    /// Set during the handshake; only meaningful once `state.isAuthenticated`.
    public private(set) var node: NodeInfo?
    public private(set) var capabilities: NodeCapabilities?
    public private(set) var status: NodeStatus?
    public private(set) var latestFrame: SpectrumFrame?
    public private(set) var framesReceived = 0
    public private(set) var latestWifiScan: WifiScanResult?
    public private(set) var isWifiScanPending = false
    public private(set) var wifiScanError: String?
    public private(set) var lastNodeError: NodeErrorPayload?

    public var onChange: (() -> Void)?
    public var onLog: ((String, ActivitySeverity) -> Void)?
    /// The authenticated capability handshake completed.
    public var onLinkVerified: ((NodeInfo, NodeCapabilities) -> Void)?
    /// First valid frame from a node that reports real (non-simulated) hardware.
    public var onHardwareSpectrumVerified: (() -> Void)?
    /// A valid Wi-Fi scan arrived from a node that is not simulated.
    public var onWifiScanVerified: ((WifiScanResult) -> Void)?

    private let transport: NodeTransport
    private let now: () -> Date
    private let nonceSource: (Int) -> [UInt8]
    private let clientVersion: String
    private var pairingKey: [UInt8] = []
    private var clientNonce = ""
    private var nodeNonce = ""
    private var sessionKey: [UInt8] = []
    private var sendSeq = 0
    private var receiveSeq = 0
    private var handshakeDeadline: Date?
    private var scanDeadline: Date?
    private var hardwareVerified = false

    public init(transport: NodeTransport, clientVersion: String = "1.0", now: @escaping () -> Date = Date.init,
                nonceSource: @escaping (Int) -> [UInt8] = SecureRandom.bytes) {
        self.transport = transport
        self.clientVersion = clientVersion
        self.now = now
        self.nonceSource = nonceSource
        transport.onEvent = { [weak self] in self?.handle($0) }
    }

    public var isSimulatedNode: Bool { node?.simulated ?? false }

    public func supports(_ feature: String) -> Bool {
        state.isAuthenticated && (capabilities?.recognizedFeatures.contains(feature) ?? false)
    }

    public static func validatedURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }

    public func connect(to address: String, pairingKey: [UInt8]) throws {
        guard !state.isActive else { return }
        guard let url = RadioNodeSession.validatedURL(address) else { throw RadioNodeError.invalidURL }
        guard pairingKey.count >= NodeProtocol.minimumKeyBytes else { throw RadioNodeError.pairingKeyRequired }
        resetSessionData()
        self.pairingKey = pairingKey
        handshakeDeadline = now().addingTimeInterval(NodeProtocol.handshakeTimeout)
        onLog?("Connecting to node at \(url.host ?? "?")", .info)
        transition(.connecting)
        transport.connect(to: url)
    }

    public func disconnect(reason: String = "Disconnected from node") {
        guard state.isActive else {
            if case .failed = state { transition(.disconnected) }
            return
        }
        if state.isAuthenticated { sendAuthenticated(NodeMessageType.bye, payload: NodeCodec.payloadText(EmptyPayload())) }
        transport.close()
        onLog?(reason, .info)
        resetSessionData()
        transition(.disconnected)
    }

    public func startSpectrum(_ request: SpectrumRequest) throws {
        guard state.isAuthenticated else { throw RadioNodeError.notConnected }
        guard let capabilities = capabilities, capabilities.recognizedFeatures.contains(NodeProtocol.spectrumFeature) else {
            throw RadioNodeError.spectrumUnsupported
        }
        guard status?.hardwarePresent == true, !capabilities.hardware.isEmpty else { throw RadioNodeError.noHardware }
        guard let hardware = capabilities.hardware.first(where: { $0.id == request.hardwareID }) else {
            throw RadioNodeError.unknownHardware
        }
        let maxBins = min(capabilities.maxBins, NodeProtocol.maxBins)
        guard request.bins >= NodeProtocol.minBins, request.bins <= maxBins else {
            throw RadioNodeError.invalidRequest("Bins must be between \(NodeProtocol.minBins) and \(maxBins).")
        }
        guard request.spanHz > 0, request.spanHz <= hardware.maxSpanHz else {
            throw RadioNodeError.invalidRequest("Span must be greater than 0 and at most \(Int(hardware.maxSpanHz)) Hz for this radio.")
        }
        let low = request.centerFrequencyHz - request.spanHz / 2, high = request.centerFrequencyHz + request.spanHz / 2
        guard low >= hardware.minFrequencyHz, high <= hardware.maxFrequencyHz else {
            throw RadioNodeError.invalidRequest("The requested range is outside what this radio reports it can receive.")
        }
        guard request.maxFramesPerSecond > 0, request.maxFramesPerSecond <= 30 else {
            throw RadioNodeError.invalidRequest("Frame rate must be between 0 and 30 per second.")
        }
        latestFrame = nil
        framesReceived = 0
        onLog?("Requested spectrum stream at \(Int(request.centerFrequencyHz)) Hz, span \(Int(request.spanHz)) Hz", .info)
        transition(.streaming)
        sendAuthenticated(NodeMessageType.subscribeSpectrum, payload: NodeCodec.payloadText(request))
    }

    public func stopSpectrum() {
        guard state == .streaming else { return }
        onLog?("Spectrum stream stopped after \(framesReceived) frame(s)", .info)
        transition(.connected)
        sendAuthenticated(NodeMessageType.unsubscribeSpectrum, payload: NodeCodec.payloadText(EmptyPayload()))
    }

    /// Asks the node for one scan of nearby Wi-Fi networks.
    public func requestWifiScan() throws {
        guard state.isAuthenticated else { throw RadioNodeError.notConnected }
        guard capabilities?.recognizedFeatures.contains(NodeProtocol.wifiScanFeature) == true else {
            throw RadioNodeError.wifiScanUnsupported
        }
        guard !isWifiScanPending else { throw RadioNodeError.scanInProgress }
        isWifiScanPending = true
        wifiScanError = nil
        scanDeadline = now().addingTimeInterval(NodeProtocol.requestTimeout)
        onLog?("Requested a Wi-Fi scan from the node", .info)
        onChange?()
        sendAuthenticated(NodeMessageType.getWifiScan, payload: NodeCodec.payloadText(WifiScanRequest()))
    }

    /// Abandons a pending Wi-Fi scan request (late results are ignored).
    public func cancelWifiScan() {
        guard isWifiScanPending else { return }
        isWifiScanPending = false
        scanDeadline = nil
        wifiScanError = "Scan cancelled."
        onChange?()
    }

    /// Enforces the handshake and request timeouts. Call periodically while active.
    public func tick() {
        let current = now()
        if [RadioNodeState.connecting, .authenticating, .awaitingReady].contains(state), let deadline = handshakeDeadline, current >= deadline {
            fail("The node did not complete the authenticated handshake within \(Int(NodeProtocol.handshakeTimeout)) seconds.")
            return
        }
        if isWifiScanPending, let deadline = scanDeadline, current >= deadline {
            isWifiScanPending = false
            scanDeadline = nil
            wifiScanError = "The node did not return a scan within \(Int(NodeProtocol.requestTimeout)) seconds."
            onLog?("Wi-Fi scan timed out", .warning)
            onChange?()
        }
    }

    // MARK: Event handling

    private func handle(_ event: NodeTransportEvent) {
        switch event {
        case .opened:
            guard state == .connecting else { return }
            clientNonce = NodeAuth.base64(nonceSource(NodeProtocol.nonceBytes))
            let hello = ClientHello(protocolVersions: NodeProtocol.supportedVersions, client: "HCG Sentinel",
                                    clientVersion: clientVersion, clientNonce: clientNonce)
            transition(.authenticating) // State first: a transport may answer synchronously.
            transport.send(text: NodeCodec.encode(NodeEnvelope(type: NodeMessageType.hello, payload: NodeCodec.payloadText(hello))))
        case .text(let text):
            guard state.isActive, state != .connecting else { return }
            do {
                try handle(try NodeCodec.envelope(from: text))
            } catch let error as NodeProtocolError {
                fail(error.userMessage)
            } catch {
                fail("Unexpected protocol error.")
            }
        case .closed(let reason):
            guard state.isActive else { return }
            fail(reason.map { "The node closed the connection: \($0)" } ?? "The node closed the connection.", closeTransport: false)
        case .failed(let reason):
            guard state.isActive else { return }
            fail(reason, closeTransport: false)
        }
    }

    private func handle(_ envelope: NodeEnvelope) throws {
        switch state {
        case .authenticating:
            if envelope.type == NodeMessageType.error { return rejected(envelope) }
            guard envelope.type == NodeMessageType.challenge else {
                throw NodeProtocolError.outOfOrder("“\(envelope.type)” arrived before the node authenticated")
            }
            try acceptChallenge(envelope)
        case .awaitingReady:
            if envelope.type == NodeMessageType.error && envelope.mac == nil { return rejected(envelope) }
            try verify(envelope)
            guard envelope.type == NodeMessageType.ready else {
                throw NodeProtocolError.outOfOrder("expected “ready”, got “\(envelope.type)”")
            }
            handshakeDeadline = nil
            guard let node = node, let capabilities = capabilities else { throw NodeProtocolError.outOfOrder("no capability report") }
            let recognized = capabilities.recognizedFeatures.sorted().joined(separator: ", ")
            onLog?("Node authenticated: \(node.nodeName) (\(node.nodeSoftware))\(node.simulated ? ", simulated data source" : ""); features: \(recognized.isEmpty ? "none" : recognized)", .info)
            transition(.connected)
            onLinkVerified?(node, capabilities)
            sendAuthenticated(NodeMessageType.getStatus, payload: NodeCodec.payloadText(EmptyPayload()))
        case .connected, .streaming:
            try verify(envelope)
            try handleSessionMessage(envelope)
        default:
            return
        }
    }

    private func rejected(_ envelope: NodeEnvelope) {
        let error = try? NodeCodec.decodePayload(NodeErrorPayload.self, from: envelope)
        lastNodeError = error
        fail("The node rejected the connection: \(error?.message ?? "no reason given")")
    }

    private func acceptChallenge(_ envelope: NodeEnvelope) throws {
        guard let payload = envelope.payload, let mac = NodeAuth.bytes(fromBase64: envelope.mac) else {
            throw NodeProtocolError.authenticationFailed("the node’s challenge is incomplete")
        }
        let expected = NodeAuth.challengeMAC(key: pairingKey, clientNonce: clientNonce, payload: payload)
        guard HMACSHA256.constantTimeEquals(expected, mac) else {
            throw NodeProtocolError.authenticationFailed("the node could not prove it holds the pairing key. Nothing it sent was used.")
        }
        let challenge = try NodeCodec.decodePayload(NodeChallenge.self, from: envelope)
        guard challenge.protocolVersion == NodeProtocol.version else {
            throw NodeProtocolError.unsupportedVersion(challenge.protocolVersion)
        }
        guard let nonce = NodeAuth.bytes(fromBase64: challenge.nodeNonce), nonce.count == NodeProtocol.nonceBytes else {
            throw NodeProtocolError.authenticationFailed("the node’s nonce is invalid")
        }
        try NodeCodec.validate(challenge.capabilities)
        nodeNonce = challenge.nodeNonce
        node = challenge.node
        capabilities = challenge.capabilities
        sessionKey = NodeAuth.sessionKey(key: pairingKey, clientNonce: clientNonce, nodeNonce: nodeNonce)
        let proof = NodeAuth.authenticateMAC(key: pairingKey, clientNonce: clientNonce, nodeNonce: nodeNonce)
        pairingKey = []
        transition(.awaitingReady)
        transport.send(text: NodeCodec.encode(NodeEnvelope(type: NodeMessageType.authenticate, mac: NodeAuth.base64(proof))))
    }

    /// Checks the MAC and that the sequence number is exactly the next one (no replay, reordering or gap).
    private func verify(_ envelope: NodeEnvelope) throws {
        guard let seq = envelope.seq, let mac = NodeAuth.bytes(fromBase64: envelope.mac) else {
            throw NodeProtocolError.authenticationFailed("the node sent an unauthenticated “\(envelope.type)” message")
        }
        let expected = NodeAuth.messageMAC(sessionKey: sessionKey, sender: "node", seq: seq, type: envelope.type,
                                           payload: envelope.payload ?? "")
        guard HMACSHA256.constantTimeEquals(expected, mac) else {
            throw NodeProtocolError.authenticationFailed("a “\(envelope.type)” message failed its integrity check")
        }
        guard seq == receiveSeq + 1 else {
            throw NodeProtocolError.outOfOrder("message \(seq) arrived after message \(receiveSeq)")
        }
        receiveSeq = seq
    }

    private func handleSessionMessage(_ envelope: NodeEnvelope) throws {
        switch envelope.type {
        case NodeMessageType.status:
            status = try NodeCodec.decodePayload(NodeStatus.self, from: envelope)
            onChange?()
        case NodeMessageType.spectrumFrame:
            let frame = try NodeCodec.decodePayload(SpectrumFrame.self, from: envelope)
            try NodeCodec.validate(frame)
            guard state == .streaming else { return } // Late frames after unsubscribe are dropped.
            latestFrame = frame
            framesReceived += 1
            if !hardwareVerified, node?.simulated == false, status?.hardwarePresent == true {
                hardwareVerified = true
                onHardwareSpectrumVerified?()
            }
            onChange?()
        case NodeMessageType.wifiScan:
            let scan = try NodeCodec.decodePayload(WifiScanResult.self, from: envelope)
            try NodeCodec.validate(scan)
            guard isWifiScanPending else { return } // Unrequested or cancelled scans are ignored.
            isWifiScanPending = false
            scanDeadline = nil
            latestWifiScan = scan
            onLog?("Node returned a Wi-Fi scan: \(scan.networks.count) network(s)\(isSimulatedNode ? " (simulated)" : "")", .info)
            if node?.simulated == false { onWifiScanVerified?(scan) }
            onChange?()
        case NodeMessageType.error:
            let error = try NodeCodec.decodePayload(NodeErrorPayload.self, from: envelope)
            lastNodeError = error
            onLog?("Node reported an error: \(error.code) – \(error.message)", .warning)
            if isWifiScanPending {
                isWifiScanPending = false
                scanDeadline = nil
                wifiScanError = "The node could not scan: \(error.message)"
            }
            if state == .streaming { transition(.connected) } else { onChange?() }
        case NodeMessageType.pong:
            break
        default:
            throw NodeProtocolError.outOfOrder("unexpected “\(envelope.type)” during the session")
        }
    }

    private func sendAuthenticated(_ type: String, payload: String) {
        sendSeq += 1
        let mac = NodeAuth.messageMAC(sessionKey: sessionKey, sender: "client", seq: sendSeq, type: type, payload: payload)
        transport.send(text: NodeCodec.encode(NodeEnvelope(type: type, seq: sendSeq, payload: payload, mac: NodeAuth.base64(mac))))
    }

    private func fail(_ reason: String, closeTransport: Bool = true) {
        if closeTransport { transport.close() }
        onLog?("Node connection failed: \(reason)", .warning)
        resetSessionData()
        transition(.failed(reason))
    }

    private func resetSessionData() {
        node = nil
        capabilities = nil
        status = nil
        latestFrame = nil
        framesReceived = 0
        latestWifiScan = nil
        isWifiScanPending = false
        wifiScanError = nil
        pairingKey = []
        clientNonce = ""
        nodeNonce = ""
        sessionKey = []
        sendSeq = 0
        receiveSeq = 0
        handshakeDeadline = nil
        scanDeadline = nil
        hardwareVerified = false
    }

    private func transition(_ new: RadioNodeState) {
        state = new
        onChange?()
    }
}
