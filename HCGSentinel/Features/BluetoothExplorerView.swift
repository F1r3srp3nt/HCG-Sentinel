import SentinelCore
import SwiftUI
import UIKit

struct BluetoothExplorerView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var bluetooth: BluetoothModel
    @EnvironmentObject private var router: Router

    private var isPreview: Bool { bluetooth.previewMode }
    private var devices: [DiscoveredPeripheral] { isPreview ? PreviewData.peripherals() : bluetooth.peripherals }

    var body: some View {
        Screen {
            if isPreview { PreviewBanner(detail: "These three devices are fabricated. No Bluetooth scan is running and none can be started in Preview mode.") }
            controlCard
            NoticeBanner(icon: "info.circle",
                         text: "RSSI is received signal strength, not distance. Walls, bodies, antenna orientation and transmit power all change it, so it cannot reliably tell you how far away a device is.")
            HStack {
                SectionLabel(text: "Discovered devices")
                if !isPreview && !bluetooth.peripherals.isEmpty {
                    Button("Clear") { bluetooth.clear() }.font(.footnote)
                }
            }
            if devices.isEmpty {
                SentinelCard {
                    EmptyState(icon: "dot.radiowaves.left.and.right", title: "No devices listed",
                               message: "Start a scan to list Bluetooth LE devices that are advertising nearby.")
                }
            } else {
                ForEach(devices) { device in
                    NavigationLink(destination: PeripheralDetailView(device: device, isPreview: isPreview)) {
                        PeripheralRow(device: device, isPreview: isPreview)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            Explanation("Sentinel lists advertisements only. It does not connect to devices, cannot see traffic between other devices, and does not judge whether a device is safe or hostile. iOS hides hardware addresses; the identifier shown is assigned by iOS for this app.")
        }
        .navigationBarTitle("Bluetooth Explorer", displayMode: .inline)
    }

    // MARK: Controls

    private var controlCard: some View {
        SentinelCard(highlight: isScanning ? Theme.cyan : nil) {
            AdaptiveStack(spacing: 8) {
                PulseDot(color: stateTone.color, active: isScanning)
                Text(stateTitle)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                StatusPill(text: statePill, tone: stateTone)
            }
            stateDetail
            if !isPreview {
                if bluetooth.state.isActive {
                    Button(action: { bluetooth.stop() }) {
                        Label("Stop scanning", systemImage: "stop.fill")
                    }
                    .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
                } else {
                    Button(action: { bluetooth.start() }) {
                        Label("Start scanning", systemImage: "play.fill")
                    }
                    .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                }
            }
        }
    }

    private var isScanning: Bool {
        if case .scanning = bluetooth.state, !isPreview { return true }
        return false
    }

    private var stateTitle: String {
        if isPreview { return "Scanning unavailable in Preview mode" }
        switch bluetooth.state {
        case .idle: return "Not scanning"
        case .waitingForRadio: return "Waiting for Bluetooth…"
        case .scanning: return "Scanning for advertisements"
        case .blocked(let blocker): return blocker.title
        }
    }

    private var statePill: String {
        if isPreview { return "Preview" }
        switch bluetooth.state {
        case .idle: return "Idle"
        case .waitingForRadio: return "Starting"
        case .scanning: return "Live"
        case .blocked: return "Blocked"
        }
    }

    private var stateTone: Tone {
        if isPreview { return .accent }
        switch bluetooth.state {
        case .idle: return .off
        case .waitingForRadio, .scanning: return .ready
        case .blocked: return .warning
        }
    }

    @ViewBuilder private var stateDetail: some View {
        if isPreview {
            Explanation("Turn Preview mode off in Settings to scan for real devices.")
        } else {
            switch bluetooth.state {
            case .idle:
                Explanation(bluetooth.enabledInSettings
                            ? "Scanning runs only while this screen’s scan is started, and stops when you stop it or at the time limit."
                            : "Scanning is turned off in Settings. Starting a scan will explain how to enable it.")
            case .waitingForRadio:
                Explanation("iOS may be asking for Bluetooth permission. The scan starts as soon as Bluetooth reports that it is ready.")
            case .scanning(let since):
                Explanation("Started at \(Formatters.time.string(from: since)). \(deadlineText) Listing \(bluetooth.peripherals.count) device(s).")
            case .blocked(let blocker):
                NoticeBanner(icon: "exclamationmark.triangle.fill", text: blocker.guidance, tone: .warning)
                if blocker == .disabledInSettings {
                    Button("Open Sentinel Settings") { router.open(.settings) }
                        .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
                } else if blocker == .permissionDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open iOS Settings for Sentinel") { UIApplication.shared.open(url) }
                        .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
                }
            }
        }
    }

    private var deadlineText: String {
        guard let deadline = bluetooth.autoStopDeadline else { return "No time limit is set." }
        return "Stops automatically at \(Formatters.time.string(from: deadline))."
    }
}

private struct SignalBars: View {
    let bars: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level <= bars ? Theme.cyan : Theme.hairline)
                    .frame(width: 4, height: CGFloat(4 + level * 3))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PeripheralRow: View {
    let device: DiscoveredPeripheral
    let isPreview: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(device.displayName)
                    .font(.headline)
                    .foregroundColor(device.localName == nil && device.name == nil ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(2)
                if isPreview { StatusPill(text: "Demo", tone: .accent) }
                Spacer(minLength: 6)
                SignalBars(bars: device.signalBars)
                Text(device.rssi.map { "\($0) dBm" } ?? "— dBm")
                    .font(Theme.mono(.subheadline))
                    .foregroundColor(Theme.textPrimary)
            }
            Text(device.id.uuidString)
                .font(Theme.mono(.caption2))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 6) {
                Text(device.serviceUUIDs.isEmpty ? "No advertised services" : "Services: \(device.serviceUUIDs.prefix(4).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("Seen \(Formatters.time.string(from: device.lastSeen))")
                    .font(Theme.mono(.caption))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct PeripheralDetailView: View {
    let device: DiscoveredPeripheral
    let isPreview: Bool

    var body: some View {
        Screen {
            if isPreview { PreviewBanner(detail: "This device is fabricated sample data.") }
            SentinelCard {
                SectionLabel(text: "Identity")
                InfoRow(label: "Advertised name", value: device.localName ?? "Not advertised")
                InfoRow(label: "Name known to iOS", value: device.name ?? "None")
                InfoRow(label: "Identifier", value: device.id.uuidString, mono: true)
                Explanation("This identifier is generated by iOS for Sentinel on this device. It is not the Bluetooth hardware address and differs on other phones.")
            }
            SentinelCard {
                SectionLabel(text: "Signal")
                InfoRow(label: "RSSI", value: device.rssi.map { "\($0) dBm" } ?? "No reading", mono: true)
                InfoRow(label: "Strength", value: device.signalDescription)
                InfoRow(label: "Advertised TX power", value: device.txPower.map { "\($0) dBm" } ?? "Not advertised", mono: true)
                Explanation("Signal strength is not a distance. Sentinel deliberately shows no range estimate.")
            }
            SentinelCard {
                SectionLabel(text: "Advertisement")
                InfoRow(label: "Connectable", value: device.isConnectable.map { $0 ? "Yes" : "No" } ?? "Not stated")
                InfoRow(label: "Manufacturer ID", value: device.manufacturerID.map { String(format: "0x%04X", $0) } ?? "None", mono: true)
                InfoRow(label: "Manufacturer data", value: device.manufacturerDataLength.map { "\($0) bytes" } ?? "None")
                if device.serviceUUIDs.isEmpty {
                    InfoRow(label: "Services", value: "None advertised")
                } else {
                    ForEach(device.serviceUUIDs, id: \.self) { uuid in
                        InfoRow(label: "Service", value: uuid, mono: true)
                    }
                }
                Explanation("The manufacturer ID is the company number the device chose to broadcast; it is not proof of who made it.")
            }
            SentinelCard {
                SectionLabel(text: "Observed")
                InfoRow(label: "First seen", value: Formatters.time.string(from: device.firstSeen), mono: true)
                InfoRow(label: "Last seen", value: Formatters.time.string(from: device.lastSeen), mono: true)
                InfoRow(label: "Advertisements received", value: "\(device.sightings)")
            }
        }
        .navigationBarTitle(Text(device.displayName), displayMode: .inline)
    }
}
