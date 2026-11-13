import SentinelCore
import SwiftUI

struct RadioLabView: View {
    @EnvironmentObject private var radio: RadioModel
    @EnvironmentObject private var router: Router

    var body: some View {
        Screen {
            if radio.previewMode {
                PreviewBanner(detail: "The spectrum below is a fabricated curve drawn by the app. No node is connected and nothing was received.")
            }
            NoticeBanner(icon: "antenna.radiowaves.left.and.right",
                         text: "An iPhone or iPad does not give apps general RF reception, transmission, monitor mode, packet injection or cellular baseband access. Radio Lab only shows what an external analysis node you operate sends over an authenticated session.")
            connectionCard
            if radio.previewMode {
                SectionLabel(text: "Spectrum (demonstration)", tone: .accent)
                SpectrumCard(frame: PreviewData.spectrum(), label: "DEMONSTRATION DATA", tone: .accent)
            } else if radio.state.isAuthenticated {
                nodeCard
                streamCard
                if let frame = radio.frame {
                    SpectrumCard(frame: frame,
                                 label: radio.isSimulatedNode ? "SIMULATED NODE DATA — not a radio measurement" : "LIVE FROM NODE HARDWARE",
                                 tone: radio.isSimulatedNode ? .accent : .verified)
                }
                wifiCard
            }
            Explanation("Sentinel Node Protocol version \(NodeProtocol.version): mutual authentication with a pairing key, every message integrity-checked. Receive-side analysis only; it defines no transmit operation. See docs/NODE_PROTOCOL.md.")
        }
        .navigationBarTitle("Radio Lab", displayMode: .inline)
    }

    // MARK: Connection

    private var connectionCard: some View {
        SentinelCard(highlight: radio.state.isActive ? Theme.cyan : nil) {
            AdaptiveStack {
                PulseDot(color: stateTone.color, active: radio.state == .streaming)
                Text(radio.previewMode ? "Disconnected" : radio.state.title)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                StatusPill(text: radio.state.isAuthenticated && !radio.previewMode ? "Authenticated" : "No node", tone: stateTone)
            }
            if radio.previewMode {
                Explanation("Turn Preview mode off in Settings to connect to a real node.")
            } else if !radio.remoteConnectionsEnabled {
                Explanation("Remote connections are off, so Radio Lab stays disconnected. Turn them on in Settings and add your node’s address and pairing key.")
                Button("Open Sentinel Settings") { router.open(.settings) }
                    .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
            } else {
                InfoRow(label: "Node address", value: radio.address.isEmpty ? "Not set" : radio.address, mono: true)
                InfoRow(label: "Pairing key", value: radio.hasPairingKey ? "Stored in Keychain" : "Not set")
                if case .failed(let reason) = radio.state {
                    NoticeBanner(icon: "xmark.octagon.fill", text: reason, tone: .danger)
                }
                if let message = radio.errorMessage {
                    NoticeBanner(icon: "exclamationmark.triangle.fill", text: message, tone: .warning)
                }
                if radio.state.isActive {
                    Button(action: { radio.disconnect() }) { Label("Disconnect", systemImage: "xmark.circle") }
                        .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
                } else {
                    Button(action: { radio.connect() }) { Label("Connect to node", systemImage: "link") }
                        .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                        .disabled(!radio.canConnect)
                    Explanation(radio.canConnect
                                ? "Connects once, when you tap. The node must prove it holds the pairing key before anything it sends is shown."
                                : "Add the node address and pairing key in Settings first.")
                }
            }
        }
    }

    private var stateTone: Tone {
        if radio.previewMode { return .off }
        switch radio.state {
        case .disconnected: return .off
        case .connecting, .authenticating, .awaitingReady: return .ready
        case .connected, .streaming: return radio.isSimulatedNode ? .accent : .verified
        case .failed: return .danger
        }
    }

    // MARK: Node

    private var nodeCard: some View {
        SentinelCard {
            SectionLabel(text: "Authenticated node", tone: .info)
            if let node = radio.node {
                InfoRow(label: "Name", value: node.nodeName)
                InfoRow(label: "Software", value: node.nodeSoftware)
                InfoRow(label: "Data source", value: node.simulated ? "Simulated (no radio)" : "Radio hardware")
                if node.simulated {
                    NoticeBanner(icon: "theatermasks.fill",
                                 text: "This node declares that it generates test data. Anything it sends is labelled simulated and verifies nothing.", tone: .accent)
                }
            }
            InfoRow(label: "Recognised features", value: recognizedFeatures)
            if let status = radio.status {
                InfoRow(label: "Node state", value: status.state)
                InfoRow(label: "Hardware present", value: status.hardwarePresent ? "Yes" : "No")
            }
            if let hardware = radio.capabilities?.hardware, !hardware.isEmpty {
                ForEach(hardware) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(item.id) · \(item.driver)")
                            .font(Theme.mono(.footnote))
                            .foregroundColor(Theme.textPrimary)
                        Text("\(item.description). Receives \(Formatters.frequency(item.minFrequencyHz)) – \(Formatters.frequency(item.maxFrequencyHz)), span up to \(Formatters.frequency(item.maxSpanHz)).")
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Explanation("Only features Sentinel recognises are listed. Anything else a node claims (for example monitor mode or injection) is ignored.")
        }
    }

    private var recognizedFeatures: String {
        let features = radio.capabilities?.recognizedFeatures.sorted() ?? []
        return features.isEmpty ? "None" : features.joined(separator: ", ")
    }

    @ViewBuilder private var streamCard: some View {
        if radio.capabilities?.recognizedFeatures.contains(NodeProtocol.spectrumFeature) == true {
            SentinelCard {
                SectionLabel(text: "Spectrum stream")
                AdaptiveStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Centre (MHz)").font(.caption).foregroundColor(Theme.textSecondary)
                        TextField("100.0", text: $radio.centerMHz).keyboardType(.decimalPad).sentinelField()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Span (MHz)").font(.caption).foregroundColor(Theme.textSecondary)
                        TextField("2.0", text: $radio.spanMHz).keyboardType(.decimalPad).sentinelField()
                    }
                }
                .disabled(radio.state == .streaming)
                if radio.state == .streaming {
                    InfoRow(label: "Frames received", value: "\(radio.framesReceived)", mono: true)
                    Button(action: { radio.stopSpectrum() }) { Label("Stop stream", systemImage: "stop.fill") }
                        .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
                } else {
                    Button(action: { radio.startSpectrum() }) { Label("Start spectrum stream", systemImage: "waveform") }
                        .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                }
            }
        }
    }

    // MARK: Wi-Fi

    @ViewBuilder private var wifiCard: some View {
        SentinelCard {
            SectionLabel(text: "Nearby Wi-Fi (from the node)")
            if !radio.offersWifiScan {
                Explanation("This node does not offer Wi-Fi scanning, so nearby Wi-Fi discovery is unavailable. iOS does not let ordinary apps scan for nearby networks.")
            } else if !radio.scanningEnabled {
                Explanation("Scanning is off. Turn it on in Settings to request a scan from the node.")
            } else {
                if radio.wifiScanPending {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Waiting for the node’s scan…").font(.subheadline).foregroundColor(Theme.textPrimary)
                        Spacer(minLength: 0)
                    }
                    Button("Cancel scan") { radio.cancelWifiScan() }
                        .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
                } else {
                    Button(action: { radio.requestWifiScan() }) { Label("Request Wi-Fi scan", systemImage: "wifi") }
                        .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                }
                if let error = radio.wifiScanError {
                    NoticeBanner(icon: "exclamationmark.triangle.fill", text: error, tone: .warning)
                }
            }
            if let scan = radio.wifiScan {
                StatusPill(text: radio.isSimulatedNode ? "Simulated node data" : "Reported by the node", tone: radio.isSimulatedNode ? .accent : .verified)
                InfoRow(label: "Scanned", value: Formatters.preciseTime.string(from: Date(timeIntervalSince1970: scan.scannedAt)), mono: true)
                InfoRow(label: "Node interface", value: scan.interface, mono: true)
                if scan.networks.isEmpty {
                    Explanation("The node found no networks.")
                }
                ForEach(scan.networks) { network in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(network.ssid ?? "Hidden network")
                            .font(.subheadline)
                            .foregroundColor(network.ssid == nil ? Theme.textSecondary : Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(network.bssid) · ch \(network.channel) (\(network.frequencyMHz) MHz) · \(network.rssiDbm) dBm · \(network.security)")
                            .font(Theme.mono(.caption))
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
                Explanation("Signal strength is not a distance. A listed security type is what the network advertises; it is not a judgement of the network.")
            }
        }
    }
}

struct SpectrumCard: View {
    let frame: SpectrumFrame
    let label: String
    let tone: Tone

    private let floorDb = -120.0
    private let ceilingDb = 0.0

    var body: some View {
        SentinelCard(highlight: tone.color) {
            HStack {
                StatusPill(text: label, tone: tone)
                Spacer(minLength: 0)
            }
            GeometryReader { proxy in
                ZStack {
                    grid(in: proxy.size)
                    trace(in: proxy.size)
                        .stroke(tone == .accent ? Theme.violet : Theme.cyan, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
            .frame(height: 200)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.panelInset))
            .accessibilityLabel("Spectrum plot. \(label). Peak \(Int(peak.power)) dBFS at \(Formatters.frequency(peak.frequency)).")
            HStack {
                Text(Formatters.frequency(frame.centerFrequencyHz - frame.spanHz / 2))
                Spacer()
                Text(Formatters.frequency(frame.centerFrequencyHz))
                Spacer()
                Text(Formatters.frequency(frame.centerFrequencyHz + frame.spanHz / 2))
            }
            .font(Theme.mono(.caption2))
            .foregroundColor(Theme.textSecondary)
            InfoRow(label: "Peak", value: "\(String(format: "%.1f", peak.power)) dBFS at \(Formatters.frequency(peak.frequency))", mono: true)
            InfoRow(label: "Bins / scale", value: "\(frame.powers.count) / \(Int(floorDb)) to \(Int(ceilingDb)) dBFS", mono: true)
            Explanation("dBFS is power relative to the receiver’s full scale, not an absolute field strength.")
        }
    }

    private var peak: (power: Double, frequency: Double) {
        guard let maximum = frame.powers.max(), let index = frame.powers.firstIndex(of: maximum), frame.powers.count > 1 else {
            return (floorDb, frame.centerFrequencyHz)
        }
        let fraction = Double(index) / Double(frame.powers.count - 1)
        return (maximum, frame.centerFrequencyHz - frame.spanHz / 2 + fraction * frame.spanHz)
    }

    private func grid(in size: CGSize) -> some View {
        Path { path in
            for step in 1..<6 {
                let y = size.height * CGFloat(step) / 6
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            for step in 1..<4 {
                let x = size.width * CGFloat(step) / 4
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
        }
        .stroke(Theme.hairline, lineWidth: 1)
    }

    private func trace(in size: CGSize) -> Path {
        var path = Path()
        let count = frame.powers.count
        guard count > 1, size.width > 0 else { return path }
        for (index, power) in frame.powers.enumerated() {
            let clamped = min(max(power, floorDb), ceilingDb)
            let x = size.width * CGFloat(index) / CGFloat(count - 1)
            let y = size.height * CGFloat((ceilingDb - clamped) / (ceilingDb - floorDb))
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}
