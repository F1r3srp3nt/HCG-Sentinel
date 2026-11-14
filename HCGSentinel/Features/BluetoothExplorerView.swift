import Combine
import SentinelCore
import SwiftUI
import UIKit

/// "12 s ago", "4 min ago", "2 h ago" — paired with the absolute time wherever it is shown.
enum RelativeAge {
    static func text(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3600) h ago"
    }
}

struct BluetoothExplorerView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var bluetooth: BluetoothModel
    @EnvironmentObject private var router: Router
    @State private var now = Date()
    @State private var showFilters = false
    private let clock = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var isPreview: Bool { bluetooth.previewMode }
    private var allDevices: [DiscoveredPeripheral] { isPreview ? PreviewData.peripherals(now: now) : bluetooth.peripherals }
    private var devices: [DiscoveredPeripheral] {
        isPreview ? allDevices : bluetooth.visiblePeripherals
    }

    var body: some View {
        Screen {
            if isPreview { PreviewBanner(detail: "These three devices are fabricated. No Bluetooth scan is running and none can be started in Preview mode.") }
            controlCard
            knowledgeCard
            filterCard
            AdaptiveStack {
                SectionLabel(text: listTitle)
                Spacer(minLength: 0)
                if !isPreview && !bluetooth.peripherals.isEmpty {
                    Button("Clear list") { bluetooth.clear() }
                        .font(.footnote)
                        .disabled(bluetooth.state.isActive)
                }
            }
            if devices.isEmpty {
                SentinelCard {
                    EmptyState(icon: "dot.radiowaves.left.and.right", title: emptyTitle, message: emptyMessage)
                }
            } else {
                ForEach(devices) { device in
                    NavigationLink(destination: PeripheralDetailView(deviceID: device.id, isPreview: isPreview)) {
                        PeripheralRow(device: device, name: isPreview ? device.nameSource(label: nil) : bluetooth.nameSource(device),
                                      currentScan: isPreview ? 1 : bluetooth.scanNumber, now: now, isPreview: isPreview)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .navigationBarTitle("Bluetooth Explorer", displayMode: .inline)
        .onReceive(clock) { now = $0 }
    }

    // MARK: Scan control

    private var controlCard: some View {
        SentinelCard(highlight: isScanning ? Theme.cyan : nil) {
            AdaptiveStack(spacing: 8) {
                PulseDot(color: stateTone.color, active: isScanning)
                Text(stateTitle)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                StatusPill(text: statePill, tone: stateTone)
            }
            stateDetail
            if !isPreview {
                InfoRow(label: "Heard in this scan", value: "\(heardThisScan)")
                InfoRow(label: "Listed in total", value: "\(bluetooth.peripherals.count)")
                if bluetooth.state.isActive {
                    Button(action: { bluetooth.stop() }) {
                        Label("Stop scanning", systemImage: "stop.fill")
                    }
                    .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
                } else {
                    Button(action: { bluetooth.start() }) {
                        Label(bluetooth.scanNumber > 0 ? "Scan again" : "Start scanning", systemImage: "play.fill")
                    }
                    .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                }
            }
        }
    }

    private var heardThisScan: Int {
        guard bluetooth.scanNumber > 0 else { return 0 }
        return bluetooth.peripherals.filter { $0.lastScan == bluetooth.scanNumber }.count
    }

    private var isScanning: Bool {
        if case .scanning = bluetooth.state, !isPreview { return true }
        return false
    }

    private var stateTitle: String {
        if isPreview { return "Scanning unavailable in Preview mode" }
        switch bluetooth.state {
        case .idle: return bluetooth.scanNumber > 0 ? "Not scanning — list shows earlier results" : "Not scanning"
        case .waitingForRadio: return "Waiting for Bluetooth…"
        case .scanning: return "Scanning for advertisements"
        case .blocked(let blocker): return blocker.title
        }
    }

    private var statePill: String {
        if isPreview { return "Preview" }
        switch bluetooth.state {
        case .idle: return "Stopped"
        case .waitingForRadio: return "Starting"
        case .scanning: return "Scan \(bluetooth.scanNumber) live"
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
                            ? "A scan runs only after you start it, and stops when you stop it or at its time limit. Devices stay listed until you clear the list."
                            : "Scanning is turned off in Settings. Starting a scan will explain how to enable it.")
            case .waitingForRadio:
                Explanation("iOS may be asking for Bluetooth permission. The scan starts as soon as Bluetooth reports that it is ready.")
            case .scanning(let since):
                Explanation("Started \(Formatters.time.string(from: since)) (\(RelativeAge.text(since, now: now))). \(deadlineText)")
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

    // MARK: What the scan can and cannot tell

    private var knowledgeCard: some View {
        SentinelCard {
            SectionLabel(text: "What this list can tell you")
            Label("Names, services, manufacturer data and signal strength that devices choose to advertise.", systemImage: "checkmark.circle")
                .font(.footnote).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
            Label("Not who owns a device, what it really is, or where it is. Any device can advertise any name or company number.", systemImage: "xmark.circle")
                .font(.footnote).foregroundColor(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Label("Not distance. Signal strength (RSSI) changes with walls, bodies, orientation and transmit power.", systemImage: "xmark.circle")
                .font(.footnote).foregroundColor(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Label("Not continuity. iOS gives each device an identifier for this app; devices that change their address can appear as new entries.", systemImage: "xmark.circle")
                .font(.footnote).foregroundColor(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Explanation("Unnamed or unknown devices are normal and are not a sign of anything malicious. Sentinel does not connect to devices.")
        }
    }

    // MARK: Filters

    private var filterCard: some View {
        SentinelCard {
            AdaptiveStack {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.textSecondary)
                TextField("Search names, labels, services, identifiers", text: $bluetooth.filter.text)
                    .technicalInput()
                    .sentinelField()
                    .accessibilityLabel("Search devices")
            }
            Picker("Sort", selection: $bluetooth.filter.sort) {
                ForEach(BluetoothSortOrder.allCases, id: \.self) { order in Text(order.title).tag(order) }
            }
            .pickerStyle(SegmentedPickerStyle())
            .accessibilityLabel("Sort devices")
            Button(action: { showFilters.toggle() }) {
                Label(showFilters ? "Hide filters" : (bluetooth.filter.isActive ? "Filters on" : "Filters"),
                      systemImage: "line.horizontal.3.decrease.circle")
            }
            .font(.subheadline)
            if showFilters {
                Toggle("Only devices that broadcast a name", isOn: $bluetooth.filter.namedOnly)
                Toggle("Only devices you labelled", isOn: $bluetooth.filter.labelledOnly)
                Toggle("Only devices heard in the current scan", isOn: $bluetooth.filter.currentScanOnly)
                Toggle("Only connectable devices", isOn: $bluetooth.filter.connectableOnly)
                Toggle("Only devices advertising services", isOn: $bluetooth.filter.withServicesOnly)
                Picker("Signal at least", selection: $bluetooth.filter.minimumRSSI) {
                    Text("Any signal").tag(Int?.none)
                    Text("−70 dBm or stronger").tag(Int?.some(-70))
                    Text("−85 dBm or stronger").tag(Int?.some(-85))
                }
                .pickerStyle(SegmentedPickerStyle())
                if bluetooth.filter.isActive {
                    Button("Reset filters") { bluetooth.filter = BluetoothDeviceFilter() }
                        .font(.footnote)
                }
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: Theme.cyan))
        .font(.footnote)
        .foregroundColor(Theme.textPrimary)
        .disabled(isPreview)
    }

    private var listTitle: String {
        if isPreview { return "Discovered devices (demo)" }
        let shown = devices.count, total = bluetooth.peripherals.count
        return shown == total ? "Discovered devices (\(total))" : "Showing \(shown) of \(total) devices"
    }

    private var emptyTitle: String {
        bluetooth.peripherals.isEmpty ? "No devices listed" : "No devices match the filters"
    }

    private var emptyMessage: String {
        if !bluetooth.peripherals.isEmpty { return "Change the search or filters to see the other devices." }
        if bluetooth.state.isActive { return "Listening. Devices appear when an advertisement is received. Many devices advertise only every few seconds." }
        return "Start a scan to list Bluetooth LE devices that are advertising nearby."
    }
}

struct SignalBars: View {
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
    let name: BluetoothNameSource
    let currentScan: Int
    let now: Date
    let isPreview: Bool

    private var unnamed: Bool { name == .notBroadcast }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AdaptiveStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name.text)
                    .font(unnamed ? .subheadline.italic() : .headline)
                    .foregroundColor(unnamed ? Theme.textSecondary : Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .userLabel = name { StatusPill(text: "Your label", tone: .accent) }
                if isPreview { StatusPill(text: "Demo", tone: .accent) }
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    SignalBars(bars: device.signalBars)
                    Text(device.rssi.map { "\($0) dBm" } ?? "no reading")
                        .font(Theme.mono(.subheadline))
                        .foregroundColor(Theme.textPrimary)
                }
            }
            AdaptiveStack(spacing: 6) {
                StatusPill(text: device.lastScan == currentScan ? "This scan" : "Earlier scan",
                           tone: device.lastScan == currentScan ? .ready : .off)
                Text("Last heard \(RelativeAge.text(device.lastSeen, now: now)) · \(Formatters.time.string(from: device.lastSeen))")
                    .font(Theme.mono(.caption))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(summary)
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name.text). Signal strength \(device.rssi.map { "\($0) dBm" } ?? "no reading"). Last heard \(RelativeAge.text(device.lastSeen, now: now)). \(summary)")
    }

    private var summary: String {
        var parts: [String] = []
        let services = device.allServiceUUIDs
        parts.append(services.isEmpty ? "No services advertised" : services.prefix(3).map(BluetoothAssignedNumbers.serviceLabel).joined(separator: ", ") + (services.count > 3 ? " +\(services.count - 3)" : ""))
        if let company = device.manufacturerID { parts.append("Manufacturer data: \(BluetoothAssignedNumbers.companyLabel(company))") }
        if device.isConnectable == true { parts.append("Connectable") }
        return parts.joined(separator: " · ")
    }
}

struct PeripheralDetailView: View {
    @EnvironmentObject private var bluetooth: BluetoothModel
    let deviceID: UUID
    let isPreview: Bool
    @State private var labelText = ""
    @State private var now = Date()
    private let clock = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var device: DiscoveredPeripheral? {
        isPreview ? PreviewData.peripherals(now: now).first { $0.id == deviceID } : bluetooth.peripherals.first { $0.id == deviceID }
    }

    var body: some View {
        Group {
            if let device = device {
                content(device)
            } else {
                Screen {
                    EmptyState(icon: "questionmark.circle", title: "No longer listed",
                               message: "This device was removed when the list was cleared or became full.")
                }
            }
        }
        .navigationBarTitle("Device", displayMode: .inline)
        .onReceive(clock) { now = $0 }
        .onAppear { labelText = bluetooth.labels[deviceID] ?? "" }
    }

    private func content(_ device: DiscoveredPeripheral) -> some View {
        let name = isPreview ? device.nameSource(label: nil) : bluetooth.nameSource(device)
        return Screen {
            if isPreview { PreviewBanner(detail: "This device is fabricated sample data.") }
            SentinelCard {
                SectionLabel(text: "Name")
                Text(name.text)
                    .font(name == .notBroadcast ? .title3.italic() : .title3.weight(.semibold))
                    .foregroundColor(name == .notBroadcast ? Theme.textSecondary : Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Explanation(name.explanation)
                InfoRow(label: "Advertised name", value: device.localName ?? "Not broadcast")
                InfoRow(label: "Name iOS reports", value: device.name ?? "None")
                if !isPreview {
                    Text("Your label (stored on this phone only)").font(.caption).foregroundColor(Theme.textSecondary)
                    TextField("For example: Office speaker", text: $labelText)
                        .sentinelField()
                        .accessibilityLabel("Your label for this device")
                    AdaptiveStack {
                        Button("Save label") { bluetooth.setLabel(labelText, for: device.id) }
                            .buttonStyle(SentinelButtonStyle(kind: .secondary))
                        if bluetooth.labels[device.id] != nil {
                            Button("Remove label") {
                                labelText = ""
                                bluetooth.setLabel("", for: device.id)
                            }
                            .buttonStyle(SentinelButtonStyle(kind: .secondary))
                        }
                    }
                    Explanation("A label follows this identifier. If the device changes its address and iOS assigns a new identifier, the label does not carry over.")
                }
            }
            SentinelCard {
                SectionLabel(text: "Signal strength")
                InfoRow(label: "Latest RSSI", value: device.rssi.map { "\($0) dBm" } ?? "No reading", mono: true)
                if let at = device.rssiAt {
                    InfoRow(label: "Measured", value: "\(Formatters.time.string(from: at)) (\(RelativeAge.text(at, now: now)))", mono: true)
                }
                if let range = device.rssiRange, device.recentRSSI.count > 1 {
                    InfoRow(label: "Last \(device.recentRSSI.count) readings", value: "\(range.lowerBound) to \(range.upperBound) dBm", mono: true)
                }
                InfoRow(label: "Strength", value: device.signalDescription)
                InfoRow(label: "Advertised TX power", value: device.txPower.map { "\($0) dBm" } ?? "Not advertised", mono: true)
                Explanation("Signal strength is not distance. Sentinel shows no range estimate, because one cannot be derived reliably from RSSI.")
            }
            SentinelCard {
                SectionLabel(text: "Advertisement evidence")
                InfoRow(label: "Connectable", value: device.isConnectable.map { $0 ? "Yes" : "No" } ?? "Not stated")
                if let company = device.manufacturerID {
                    InfoRow(label: "Manufacturer data company", value: BluetoothAssignedNumbers.companyLabel(company))
                }
                if let data = device.manufacturerData {
                    InfoRow(label: "Manufacturer data (\(device.manufacturerDataLength ?? data.count) bytes)", value: BluetoothAssignedNumbers.hex(data), mono: true)
                } else {
                    InfoRow(label: "Manufacturer data", value: "None advertised")
                }
                if device.allServiceUUIDs.isEmpty {
                    InfoRow(label: "Services", value: "None advertised")
                    Explanation("Devices often have services they do not advertise. Seeing none here does not mean the device has none.")
                }
                ForEach(device.serviceUUIDs, id: \.self) { InfoRow(label: "Service", value: BluetoothAssignedNumbers.serviceLabel($0), mono: true) }
                ForEach(device.overflowServiceUUIDs, id: \.self) { InfoRow(label: "Service (overflow area)", value: BluetoothAssignedNumbers.serviceLabel($0), mono: true) }
                ForEach(device.solicitedServiceUUIDs, id: \.self) { InfoRow(label: "Service it looks for", value: BluetoothAssignedNumbers.serviceLabel($0), mono: true) }
                ForEach(device.serviceData.keys.sorted(), id: \.self) { uuid in
                    InfoRow(label: "Service data \(BluetoothAssignedNumbers.serviceLabel(uuid))", value: BluetoothAssignedNumbers.hex(device.serviceData[uuid] ?? []), mono: true)
                }
                Explanation("The company number names whose data format the device uses. It is not proof of who made the device, and Sentinel does not decode it into a device identity.")
            }
            SentinelCard {
                SectionLabel(text: "Observed")
                InfoRow(label: "Identifier (iOS, this app)", value: device.id.uuidString, mono: true)
                InfoRow(label: "First heard", value: "\(Formatters.time.string(from: device.firstSeen)) (\(RelativeAge.text(device.firstSeen, now: now)))", mono: true)
                InfoRow(label: "Last heard", value: "\(Formatters.time.string(from: device.lastSeen)) (\(RelativeAge.text(device.lastSeen, now: now)))", mono: true)
                InfoRow(label: "Advertisements received", value: "\(device.sightings) in total, \(device.sightingsInLastScan) in scan \(device.lastScan)")
                Explanation("The identifier is generated by iOS for Sentinel on this phone. It is not the Bluetooth hardware address and differs on other phones.")
            }
        }
    }
}
