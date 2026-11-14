import SentinelCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var connection: ConnectionMonitor
    @EnvironmentObject private var bluetooth: BluetoothModel
    @EnvironmentObject private var network: NetworkModel
    @EnvironmentObject private var radio: RadioModel
    @EnvironmentObject private var requests: RequestModel
    @EnvironmentObject private var check: NetworkCheckModel
    @EnvironmentObject private var lab: SecurityLabModel
    @EnvironmentObject private var devices: ConnectedDevicesModel
    @Environment(\.sizeCategory) private var sizeCategory

    private let statusColumns = [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)]

    /// Two tiles per row on phones at normal sizes; one per row at accessibility sizes so titles never collide.
    private var tileColumns: [GridItem] {
        let minimum: CGFloat = sizeCategory.isAccessibilityCategory ? 280 : 150
        return [GridItem(.adaptive(minimum: minimum), spacing: 12, alignment: .top)]
    }

    var body: some View {
        Screen {
            header
            if app.settings.previewMode {
                PreviewBanner(detail: "Tools show fabricated sample data and live operations are paused. The status on this screen is still real.")
            }
            LazyVGrid(columns: statusColumns, spacing: 14) {
                deviceCard
                connectionCard
                capabilityCard
                operationsCard
            }
            SectionLabel(text: "Quick access")
            LazyVGrid(columns: tileColumns, spacing: 12) {
                tile(.networkCheck, status: checkStatus)
                tile(.securityLab, status: securityLabStatus)
                tile(.network, status: networkStatus)
                tile(.bluetooth, status: bluetoothStatus)
                tile(.radio, status: radioStatus)
                tile(.requests, status: requestStatus)
                tile(.devices, status: devicesStatus)
                tile(.settings, status: "Controls and retention")
            }
            SectionLabel(text: "Recent activity")
            activityCard
        }
        .navigationBarTitle("Dashboard", displayMode: .inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { router.open(.settings) }) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image("SentinelHeader")
                .resizable()
                .aspectRatio(contentMode: .fit)
                // Capped so the status cards stay in view on small iPhones and in landscape.
                .frame(maxWidth: 520, maxHeight: 150)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("HCG Sentinel")
                .accessibilityAddTraits(.isHeader)
            SweepLine()
            AdaptiveStack {
                StatusPill(text: app.activeOperations.isEmpty ? "Idle" : "\(app.activeOperations.count) running",
                           tone: app.activeOperations.isEmpty ? .off : .ready)
                Text(app.activeOperations.isEmpty ? "Nothing is scanning or connected." : app.activeOperations.joined(separator: " · "))
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text("Authorised testing of your own devices, networks and services. Standard iOS features work on their own; helper and node features appear only after they verify.")
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }

    // MARK: Status cards

    private var deviceCard: some View {
        SentinelCard {
            SectionLabel(text: "This device", tone: .info)
            InfoRow(label: "Model", value: DeviceInfo.modelIdentifier, mono: true)
            InfoRow(label: "System", value: DeviceInfo.systemDescription)
            InfoRow(label: "Layout", value: DeviceInfo.idiomDescription + (DeviceInfo.isSimulator ? " (Simulator)" : ""))
            InfoRow(label: "Sentinel", value: DeviceInfo.appVersion)
            if DeviceInfo.isSimulator {
                Explanation("The Simulator has no Bluetooth radio, so Bluetooth discovery can only be checked on a physical device.")
            }
        }
    }

    private var connectionCard: some View {
        SentinelCard {
            SectionLabel(text: "Connection", tone: .info)
            if let snapshot = connection.snapshot {
                HStack(spacing: 8) {
                    PulseDot(color: snapshot.isOnline ? Theme.ok : Theme.warning, active: false)
                    Text(snapshot.headline)
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                }
                InfoRow(label: "IPv4 / IPv6 / DNS",
                        value: "\(yesNo(snapshot.supportsIPv4)) / \(yesNo(snapshot.supportsIPv6)) / \(yesNo(snapshot.supportsDNS))")
                InfoRow(label: "Metered or Low Data", value: "\(yesNo(snapshot.isExpensive)) / \(yesNo(snapshot.isConstrained))")
                InfoRow(label: "Updated", value: Formatters.time.string(from: snapshot.updatedAt), mono: true)
            } else {
                Text("Waiting for iOS to report the network path…")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
            }
            Explanation("This is Sentinel’s own network path as reported by iOS. It is not a view of other apps or devices.")
        }
    }

    private var capabilityCard: some View {
        Button(action: { router.open(.capabilities) }) {
            SentinelCard {
                HStack(alignment: .top) {
                    SectionLabel(text: "Verified capabilities", tone: .verified)
                    Image(systemName: "chevron.right").font(.footnote).foregroundColor(Theme.textSecondary)
                }
                AdaptiveStack(spacing: 6) {
                    Text("\(app.verifiedCapabilityCount)")
                        .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                        .foregroundColor(app.verifiedCapabilityCount > 0 ? Theme.ok : Theme.textPrimary)
                    Text("of \(app.operationalCapabilityCount) confirmed by a real operation this session")
                        .font(.footnote)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(CapabilityTier.operational, id: \.self) { tier in
                    tierRow(tier)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityHint("Opens the capability list")
    }

    private func tierRow(_ tier: CapabilityTier) -> some View {
        let states = app.capabilities.filter { $0.descriptor.tier == tier }
        return VStack(alignment: .leading, spacing: 6) {
            Text(tier.title)
                .font(.subheadline)
                .foregroundColor(Theme.textPrimary)
            HStack(spacing: 6) {
                ForEach(states) { state in
                    Circle()
                        .fill(state.readiness.tone.color)
                        .frame(width: 10, height: 10)
                        .opacity(state.readiness == .verified ? 1 : 0.55)
                }
                Spacer(minLength: 6)
                Text("\(states.filter { $0.readiness == .verified }.count)/\(states.count) verified")
                    .font(Theme.mono(.caption))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var operationsCard: some View {
        SentinelCard(highlight: app.activeOperations.isEmpty ? nil : Theme.cyan) {
            SectionLabel(text: "Active operations")
            if app.activeOperations.isEmpty {
                Text("Nothing is running.")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Explanation("Sentinel starts scans, requests and sessions only when you ask it to.")
            } else {
                ForEach(app.activeOperations, id: \.self) { title in
                    HStack(spacing: 8) {
                        PulseDot(color: Theme.cyan, active: true)
                        Text(title).font(.body).foregroundColor(Theme.textPrimary)
                    }
                }
            }
            Button(action: { app.stopAllOperations() }) {
                Label("Stop All Operations", systemImage: "stop.circle.fill")
            }
            .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
            Explanation("Stops Sentinel’s own scans, requests and sessions. Saved captures, settings and system services are not touched.")
        }
    }

    // MARK: Quick access

    private func tile(_ section: SentinelSection, status: String) -> some View {
        Button(action: { router.open(section) }) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(Theme.cyan)
                Text(section.title)
                    .font(.system(.subheadline, design: .default).weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(status)
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.metalEdge, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var checkStatus: String {
        if check.isRunning { return "Checking…" }
        if let report = check.report { return report.headline }
        return "Not run yet"
    }

    private var securityLabStatus: String {
        if let module = lab.running { return "\(module.title) running…" }
        if let latest = lab.reports.first { return "\(latest.module.title): \(latest.headline)" }
        return "Secrets, exposure and login defences"
    }

    private var networkStatus: String {
        network.isParsing ? "Reading a capture file…" : "\(network.saved.count) saved capture(s)"
    }

    private var bluetoothStatus: String {
        if app.settings.previewMode { return "Preview data" }
        switch bluetooth.state {
        case .scanning: return "Scanning · \(bluetooth.peripherals.count) listed"
        case .waitingForRadio: return "Waiting for Bluetooth"
        case .blocked(let blocker): return blocker.title
        case .idle: return bluetooth.enabledInSettings ? "Ready to scan" : "Scanning off"
        }
    }

    private var radioStatus: String {
        if app.settings.previewMode { return "Preview data" }
        return radio.remoteConnectionsEnabled ? radio.state.title : "Disconnected · remote connections off"
    }

    private var devicesStatus: String {
        switch devices.link {
        case .notPaired: return "Not paired"
        case .pairing: return "Awaiting approval"
        case .connected: return "\(devices.devices?.installations.count ?? 0) paired"
        case .offline: return "Server offline"
        case .paused: return "Paused"
        case .ended: return "Disconnected"
        }
    }

    private var requestStatus: String {
        if let endpoint = requests.endpoints.first {
            return requests.endpoints.count == 1 ? endpoint.host : "\(endpoint.host) +\(requests.endpoints.count - 1)"
        }
        return "No test endpoint added"
    }

    // MARK: Activity

    private var activityCard: some View {
        SentinelCard {
            if app.activity.isEmpty {
                EmptyState(icon: "clock", title: "No activity yet", message: "Actions Sentinel takes appear here, with credentials redacted.")
            } else {
                ForEach(app.activity.prefix(8)) { entry in
                    ActivityRow(entry: entry)
                }
            }
        }
    }

    private func yesNo(_ value: Bool) -> String { value ? "Yes" : "No" }
}

struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        AdaptiveStack(alignment: .top, spacing: 10) {
            Text(Formatters.time.string(from: entry.date))
                .font(Theme.mono(.caption))
                .foregroundColor(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.category.rawValue.uppercased())
                    .font(.system(.caption2, design: .default).weight(.bold))
                    .foregroundColor(entry.severity.tone.color)
                Text(entry.message)
                    .font(.footnote)
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

extension ActivitySeverity {
    var tone: Tone {
        switch self {
        case .info: return .ready
        case .notice: return .accent
        case .warning: return .warning
        case .error: return .danger
        }
    }
}

extension CapabilityReadiness {
    var tone: Tone {
        switch self {
        case .verified: return .verified
        case .ready, .environmentUnknown: return .ready
        case .disabled, .notIncluded: return .off
        case .interfaceOnly: return .accent
        case .unsupported: return .warning
        case .failed: return .danger
        }
    }
}
