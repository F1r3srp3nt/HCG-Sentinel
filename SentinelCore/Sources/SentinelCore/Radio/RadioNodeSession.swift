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
    case handshaking
    case connected
    case streaming
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .disconnected, .failed: return false
        case .connecting, .handshaking, .connected, .streaming: return true
        }
    }

    public var title: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .handshaking: return "Negotiating protocol"
        case .connected: return "Connected"
        case .streaming: return "Streaming spectrum"
        case .failed: return "Connection failed"
        }
    }
}

public enum RadioNodeError: Error, Equatable {
    case invalidURL
    case notConnected
    case spectrumUnsupported
    case noHardware
    case unknownHardware
    case invalidRequest(String)

    public var userMessage: String {
        switch self {
        case .invalidURL: return "Enter a ws:// or wss:// node address."
        case .notConnected: return "Connect to a node first."
        case .spectrumUnsupported: return "This node does not offer the spectrum feature."
        case .noHardware: return "The node reports no radio hardware, so there is nothing to analyse."
        case .unknownHardware: return "The selected radio is not in the node’s hardware list."
        case .invalidRequest(let reason): return reason
        }
    }
}

/// Client side of the Sentinel Node Protocol. The session stays disconnected
/// until `connect` is called and never reports data it did not receive.
/// Confine to the main queue.
public final class RadioNodeSession {
    public private(set) var state: RadioNodeState = .disconnected
    public private(set) var node: NodeHelloAck?
    public private(set) var capabilities: NodeCapabilities?
    public private(set) var status: NodeStatus?
    public private(set) var latestFrame: SpectrumFrame?
    public private(set) var framesReceived = 0
    public private(set) var lastNodeError: NodeErrorPayload?

    public var onChange: (() -> Void)?
    public var onLog: ((String, ActivitySeverity) -> Void)?
    /// Handshake completed with a node.
    public var onLinkVerified: ((NodeHelloAck) -> Void)?
    /// First valid frame from a node that reports real (non-simulated) hardware.
    public var onHardwareSpectrumVerified: (() -> Void)?

    private let transport: NodeTransport
    private let now: () -> Date
    private let clientVersion: String
    private var pendingToken: String?
    private var handshakeDeadline: Date?
    private var hardwareVerified = false

    public init(transport: NodeTransport, clientVersion: String = "1.0", now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.clientVersion = clientVersion
        self.now = now
        transport.onEvent = { [weak self] in self?.handle($0) }
    }

    public var isSimulatedNode: Bool { node?.simulated ?? false }

    public static func validatedURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }

    public func connect(to address: String, authToken: String?) throws {
        guard !state.isActive else { return }
        guard let url = RadioNodeSession.validatedURL(address) else { throw RadioNodeError.invalidURL }
        resetSessionData()
        pendingToken = (authToken?.isEmpty ?? true) ? nil : authToken
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
        if state == .connected || state == .streaming { transport.send(text: NodeCodec.encode(.bye)) }
        transport.close()
        onLog?(reason, .info)
        resetSessionData()
        transition(.disconnected)
    }

    public func startSpectrum(_ request: SpectrumRequest) throws {
        guard state == .connected || state == .streaming else { throw RadioNodeError.notConnected }
        guard let capabilities = capabilities, capabilities.features.contains(NodeProtocol.spectrumFeature) else {
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
        transport.send(text: NodeCodec.encode(.subscribeSpectrum(request)))
    }

    public func stopSpectrum() {
        guard state == .streaming else { return }
        transport.send(text: NodeCodec.encode(.unsubscribeSpectrum))
        onLog?("Spectrum stream stopped after \(framesReceived) frame(s)", .info)
        transition(.connected)
    }

    /// Enforces the handshake timeout. Call periodically while active.
    public func tick() {
        guard state == .connecting || state == .handshaking, let deadline = handshakeDeadline, now() >= deadline else { return }
        fail("The node did not complete the handshake within \(Int(NodeProtocol.handshakeTimeout)) seconds.")
    }

    // MARK: Event handling

    private func handle(_ event: NodeTransportEvent) {
        switch event {
        case .opened:
            guard state == .connecting else { return }
            let hello = ClientHello(protocolVersions: NodeProtocol.supportedVersions, client: "HCG Sentinel",
                                    clientVersion: clientVersion, authToken: pendingToken)
            pendingToken = nil
            transition(.handshaking) // State first: a transport may answer synchronously.
            transport.send(text: NodeCodec.encode(.hello(hello)))
        case .text(let text):
            guard state.isActive else { return }
            do {
                try handle(try NodeCodec.decode(text))
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

    private func handle(_ message: NodeMessage) throws {
        if state == .handshaking {
            switch message {
            case .helloAck(let ack):
                node = ack
                handshakeDeadline = nil
                onLog?("Node handshake complete: \(ack.nodeName) (\(ack.nodeSoftware))\(ack.simulated ? ", simulated data source" : "")", .info)
                transition(.connected)
                onLinkVerified?(ack)
                transport.send(text: NodeCodec.encode(.getCapabilities))
                transport.send(text: NodeCodec.encode(.getStatus))
            case .error(let error):
                lastNodeError = error
                fail("The node rejected the connection: \(error.message)")
            default:
                throw NodeProtocolError.invalidPayload("message received before the handshake completed")
            }
            return
        }
        switch message {
        case .helloAck:
            throw NodeProtocolError.invalidPayload("unexpected second handshake")
        case .capabilities(let value):
            capabilities = value
            onChange?()
        case .status(let value):
            status = value
            onChange?()
        case .spectrumFrame(let frame):
            guard state == .streaming else { return } // Late frames after unsubscribe are dropped.
            latestFrame = frame
            framesReceived += 1
            if !hardwareVerified, node?.simulated == false, status?.hardwarePresent == true {
                hardwareVerified = true
                onHardwareSpectrumVerified?()
            }
            onChange?()
        case .error(let error):
            lastNodeError = error
            onLog?("Node reported an error: \(error.code) – \(error.message)", .warning)
            if state == .streaming { transition(.connected) } else { onChange?() }
        case .pong:
            break
        }
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
        pendingToken = nil
        handshakeDeadline = nil
        hardwareVerified = false
    }

    private func transition(_ new: RadioNodeState) {
        state = new
        onChange?()
    }
}
