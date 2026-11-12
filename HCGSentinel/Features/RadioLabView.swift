import SentinelCore
import SwiftUI

struct RadioLabView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var radio: RadioModel
    @EnvironmentObject private var router: Router

    var body: some View {
        Screen {
            if radio.previewMode {
                PreviewBanner(detail: "The spectrum below is a fabricated curve drawn by the app. No node is connected and nothing was received.")
            }
            NoticeBanner(icon: "antenna.radiowaves.left.and.right",
                         text: "An iPhone or iPad does not give apps general RF reception, transmission or cellular baseband access. Radio Lab only displays what an external analysis node sends it over the Sentinel Node Protocol.")
            connectionCard
            if radio.previewMode {
                SectionLabel(text: "Spectrum (demonstration)", tone: .accent)
                SpectrumCard(frame: PreviewData.spectrum(), label: "DEMONSTRATION DATA", tone: .accent)
            } else if radio.state == .connected || radio.state == .streaming {
                nodeCard
                streamCard
                if let frame = radio.frame {
                    SpectrumCard(frame: frame,
                                 label: radio.isSimulatedNode ? "SIMULATED NODE DATA — not a radio measurement" : "LIVE FROM NODE HARDWARE",
                                 tone: radio.isSimulatedNode ? .accent : .verified)
                }
            }
            Explanation("Protocol version \(NodeProtocol.version) is receive-side analysis only and defines no transmit operation. It is documented in docs/NODE_PROTOCOL.md.")
        }
        .navigationBarTitle("Radio Lab", displayMode: .inline)
    }

    // MARK: Connection

    private var connectionCard: some View {
        SentinelCard(highlight: radio.state.isActive ? Theme.cyan : nil) {
            HStack(spacing: 8) {
                PulseDot(color: stateTone.color, active: radio.state == .streaming)
                Text(radio.previewMode ? "Disconnected" : radio.state.title)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                StatusPill(text: radio.state.isActive && !radio.previewMode ? "Node link" : "No node", tone: stateTone)
            }
            if radio.previewMode {
                Explanation("Turn Preview mode off in Settings to connect to a real node.")
            } else if !radio.enabled {
                Explanation("The external node connection is turned off. Radio Lab stays disconnected until you enable it and enter the address of a node you operate.")
                Button("Open Sentinel Settings") { router.open(.settings) }
                    .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
            } else {
                InfoRow(label: "Node address", value: radio.address.isEmpty ? "Not set" : radio.address, mono: true)
                InfoRow(label: "Access token", value: radio.hasToken ? "Stored in Keychain" : "None")
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
                    Explanation("Connects once, when you tap. Sentinel does not reconnect by itself or search the network for nodes.")
                }
            }
        }
    }

    private var stateTone: Tone {
        if radio.previewMode { return .off }
        switch radio.state {
        case .disconnected: return .off
        case .connecting, .handshaking: return .ready
        case .connected, .streaming: return radio.isSimulatedNode ? .accent : .verified
        case .failed: return .danger
        }
    }

    // MARK: Node

    private var nodeCard: some View {
        SentinelCard {
            SectionLabel(text: "Node", tone: .info)
            if let node = radio.node {
                InfoRow(label: "Name", value: node.nodeName)
                InfoRow(label: "Software", value: node.nodeSoftware)
                InfoRow(label: "Protocol", value: "SNP v\(node.protocolVersion)", mono: true)
                InfoRow(label: "Data source", value: node.simulated ? "Simulated (no radio)" : "Radio hardware")
                if node.simulated {
                    NoticeBanner(icon: "theatermasks.fill",
                                 text: "This node declares that it generates test data. Anything it streams is labelled simulated and does not verify radio reception.", tone: .accent)
                }
            }
            if let status = radio.status {
                InfoRow(label: "Node state", value: status.state)
                InfoRow(label: "Hardware present", value: status.hardwarePresent ? "Yes" : "No")
                if let message = status.message, !message.isEmpty { Explanation(message) }
            } else {
                Explanation("Waiting for the node’s status…")
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
            } else if radio.capabilities != nil {
                NoticeBanner(icon: "exclamationmark.triangle.fill",
                             text: "The node reports no radio hardware, so there is no spectrum to request.", tone: .warning)
            }
        }
    }

    private var streamCard: some View {
        SentinelCard {
            SectionLabel(text: "Spectrum stream")
            HStack(spacing: 10) {
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

/// Draws one spectrum frame. The label always states where the data came from.
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
