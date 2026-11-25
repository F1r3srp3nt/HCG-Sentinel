import SentinelCore
import SwiftUI
import UIKit

private func ms(_ value: Double?) -> String {
    guard let value = value else { return "—" }
    return value < 10 ? String(format: "%.2f ms", value) : String(format: "%.1f ms", value)
}

/// Entry card at the top of the Network tab: the live network tools.
struct NetworkToolsCard: View {
    @EnvironmentObject private var connection: ConnectionMonitor
    @EnvironmentObject private var ping: PingModel
    @EnvironmentObject private var local: LocalNetworkModel
    @State private var open: String?

    var body: some View {
        SentinelCard {
            SectionLabel(text: "Network tools")
            NavigationLink(destination: WiFiView(), tag: "wifi", selection: $open) {
                ToolRow(icon: "wifi", title: "Wi-Fi", detail: wifiDetail, status: nil)
            }
            NavigationLink(destination: LocalNetworkView(), tag: "local", selection: $open) {
                ToolRow(icon: "network", title: "Local Network", detail: "Bonjour services and an authorised sweep of your own network", status: local.status)
            }
            NavigationLink(destination: PingView(), tag: "ping", selection: $open) {
                ToolRow(icon: "waveform.path.ecg", title: "Ping", detail: "ICMP echo, or a labelled TCP connect test", status: ping.status)
            }
            NavigationLink(destination: NetworkCheckView()) {
                ToolRow(icon: "checkmark.shield", title: "Check My Network", detail: "DNS, captive portal, proxy and HTTPS checks", status: nil)
            }
        }
        .onAppear {
            #if DEBUG
            // Screenshot checks in CI: -SentinelNetworkTool <wifi|local|ping> opens that tool; with -SentinelRunPing a real
            // 5-probe ICMP test to 127.0.0.1 runs (the Simulator's own loopback), so the screenshot shows real results.
            if open == nil, let tool = UserDefaults.standard.string(forKey: "SentinelNetworkTool") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { open = tool }
                if tool == "ping", ProcessInfo.processInfo.arguments.contains("-SentinelRunPing"), !ping.isRunning, ping.current == nil {
                    ping.input = "127.0.0.1"
                    ping.count = 5
                    ping.start()
                }
            }
            #endif
        }
    }

    private var wifiDetail: String {
        guard let snapshot = connection.snapshot else { return "Waiting for iOS to report the connection" }
        if snapshot.usesWiFi, let v4 = snapshot.ipv4Networks.first(where: { $0.interface.hasPrefix("en") }) {
            return "Connected · \(v4.address) on \(v4.network)"
        }
        return snapshot.usesWiFi ? "Connected" : "Not using Wi-Fi now"
    }
}

private struct ToolRow: View {
    let icon: String
    let title: String
    let detail: String
    let status: ToolStatus?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(Theme.cyan).frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundColor(Theme.textPrimary)
                Text(detail).font(.caption).foregroundColor(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let status = status, status != .idle { StatusPill(text: status.title, tone: status.tone) }
            Image(systemName: "chevron.right").font(.caption).foregroundColor(Theme.textSecondary).accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Wi-Fi

struct WiFiView: View {
    @EnvironmentObject private var connection: ConnectionMonitor
    @State private var identity: WiFiFacts?
    @State private var readingIdentity = false

    var body: some View {
        Screen {
            currentCard
            identityCard
            changesCard
            nearbyCard
        }
        .navigationBarTitle("Wi-Fi", displayMode: .inline)
        .onAppear { connection.refreshAddresses() }
    }

    private var snapshot: ConnectionSnapshot? { connection.snapshot }
    private var wifiNetworks: [LocalInterfaceNetwork] {
        (snapshot?.ipv4Networks ?? []).filter { $0.interface.hasPrefix("en") }
    }

    private var currentCard: some View {
        SentinelCard(highlight: snapshot?.usesWiFi == true ? Theme.cyan : nil) {
            AdaptiveStack {
                SectionLabel(text: "Current connection")
                Spacer(minLength: 0)
                StatusPill(text: snapshot == nil ? "Waiting" : (snapshot!.usesWiFi ? "Wi-Fi" : "Not on Wi-Fi"),
                           tone: snapshot?.usesWiFi == true ? .verified : .off)
            }
            if let snapshot = snapshot {
                InfoRow(label: "Status", value: snapshot.headline)
                InfoRow(label: "Interface", value: snapshot.interfaceNames.isEmpty ? "Not reported" : snapshot.interfaceNames.joined(separator: ", "), mono: true)
                if wifiNetworks.isEmpty {
                    InfoRow(label: "IPv4 address", value: snapshot.usesWiFi ? "None assigned" : "—")
                }
                ForEach(wifiNetworks, id: \.address) { net in
                    InfoRow(label: "IPv4 address", value: "\(net.address) (\(net.interface))", mono: true)
                    InfoRow(label: "Subnet", value: "\(net.network) · mask \(net.network.netmask)", mono: true)
                }
                ForEach(snapshot.addresses.filter { $0.family == "IPv6" && $0.interface.hasPrefix("en") }) { address in
                    InfoRow(label: "IPv6 address", value: address.address, mono: true)
                }
                InfoRow(label: "Default gateway", value: snapshot.gateways.isEmpty ? "Not reported by iOS" : snapshot.gateways.joined(separator: ", "), mono: true)
                InfoRow(label: "iOS path report", value: "IPv4 route \(snapshot.supportsIPv4 ? "yes" : "no") · IPv6 route \(snapshot.supportsIPv6 ? "yes" : "no") · DNS \(snapshot.supportsDNS ? "yes" : "no")")
                Explanation("The path report is iOS's own view of which routes it considers usable for this app; it can say \"no\" (for example in the Simulator) even when an address is assigned. iOS does not give apps the DNS server addresses; Check My Network tests whether DNS answers correctly instead.")
                Text("Updated \(Formatters.time.string(from: snapshot.updatedAt))").font(.caption).foregroundColor(Theme.textSecondary)
            } else {
                Explanation("iOS has not reported the connection yet.")
            }
            Button("Refresh addresses") { connection.refreshAddresses() }.font(.footnote)
        }
    }

    private var identityCard: some View {
        SentinelCard {
            SectionLabel(text: "Network name (SSID) and BSSID")
            if let facts = identity {
                if let reason = facts.unavailableReason {
                    StatusPill(text: "Permission required", tone: .warning)
                    Explanation(reason)
                } else {
                    InfoRow(label: "SSID", value: facts.ssid ?? "Not provided", mono: true)
                    InfoRow(label: "BSSID", value: facts.bssid ?? "Not provided", mono: true)
                    if let security = facts.security { InfoRow(label: "Security", value: security.title) }
                }
            } else {
                Explanation("iOS shows the joined network's name only to apps with Apple's Access Wi-Fi Information entitlement and location permission. This build has neither, so the request below is expected to report that it is unavailable.")
            }
            Button(readingIdentity ? "Asking iOS…" : "Ask iOS for the network name") {
                readingIdentity = true
                PlatformNetworkProbe().wifiFacts { facts in
                    identity = facts
                    readingIdentity = false
                }
            }
            .disabled(readingIdentity)
            .font(.footnote)
        }
    }

    private var changesCard: some View {
        SentinelCard {
            SectionLabel(text: "Connection changes (this session)")
            if connection.changes.isEmpty {
                Explanation("No changes recorded yet.")
            }
            ForEach(connection.changes.prefix(10)) { change in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Formatters.time.string(from: change.at)).font(Theme.mono(.caption)).foregroundColor(Theme.textSecondary)
                    Text(change.text).font(.footnote).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var nearbyCard: some View {
        SentinelCard {
            AdaptiveStack {
                SectionLabel(text: "Nearby Wi-Fi networks")
                Spacer(minLength: 0)
                StatusPill(text: "Unsupported", tone: .off)
            }
            Explanation("iOS has no public interface that lets an app list nearby Wi-Fi networks. Apple's NEHotspotHelper can see them only with a special entitlement that Apple grants to hotspot operators, and macOS's CoreWLAN does not exist on iOS. Sentinel does not show nearby networks rather than invent them.")
            Explanation("On a jailbroken iPhone a separately installed, privileged helper could read scan results from iOS's private Wi-Fi framework. That helper is not part of this beta: it would need its own review and your approval before installation.")
        }
    }
}

private extension WiFiSecurity {
    var title: String {
        switch self {
        case .open: return "Open (no encryption)"
        case .wep: return "WEP (obsolete)"
        case .personal: return "WPA/WPA2/WPA3 Personal"
        case .enterprise: return "WPA/WPA2/WPA3 Enterprise"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Ping

struct PingView: View {
    @EnvironmentObject private var ping: PingModel

    var body: some View {
        Screen {
            formCard
            if let run = ping.current { RunCard(run: run, live: ping.isRunning) }
            historyCard
        }
        .navigationBarTitle("Ping", displayMode: .inline)
    }

    private var formCard: some View {
        SentinelCard(highlight: ping.isRunning ? Theme.cyan : nil) {
            SectionLabel(text: "Target")
            TextField("IP address or host name", text: $ping.input)
                .technicalInput()
                .keyboardType(.URL)
                .sentinelField()
                .disabled(ping.isRunning)
                .accessibilityLabel("Target IP address or host name")
            Picker("Method", selection: $ping.useTCP) {
                Text("ICMP Echo").tag(false)
                Text("TCP connect").tag(true)
            }
            .pickerStyle(SegmentedPickerStyle())
            .disabled(ping.isRunning)
            if ping.useTCP {
                HStack {
                    Text("Port").foregroundColor(Theme.textSecondary)
                    TextField("443", text: $ping.tcpPort).keyboardType(.numberPad).sentinelField().frame(maxWidth: 110)
                }
                Explanation("A TCP connect test is not a ping. It measures how long the device takes to accept (or refuse) a connection on that port; firewalls often treat it differently from ICMP.")
            } else {
                Explanation("Sends real ICMP Echo Requests from this iPhone, one at a time. No helper or special privilege is used.")
            }
            Stepper("Probes: \(ping.count)", value: $ping.count, in: PingConfiguration.countRange)
                .foregroundColor(Theme.textPrimary).disabled(ping.isRunning)
            HStack {
                Text("Interval").foregroundColor(Theme.textSecondary)
                Picker("Interval", selection: $ping.interval) {
                    Text("1 s").tag(TimeInterval(1))
                    Text("2 s").tag(TimeInterval(2))
                    Text("5 s").tag(TimeInterval(5))
                }.pickerStyle(SegmentedPickerStyle())
            }.disabled(ping.isRunning)
            HStack {
                Text("Timeout").foregroundColor(Theme.textSecondary)
                Picker("Timeout", selection: $ping.timeout) {
                    Text("1 s").tag(TimeInterval(1))
                    Text("2 s").tag(TimeInterval(2))
                    Text("5 s").tag(TimeInterval(5))
                }.pickerStyle(SegmentedPickerStyle())
            }.disabled(ping.isRunning)
            if let error = ping.inputError {
                Text(error).font(.footnote).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            if ping.isRunning {
                Button(action: { ping.stop() }) { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
            } else {
                Button(action: { ping.start() }) { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
            }
            Explanation("At most 100 probes, at least 1 s apart, one in flight at a time. Stops when you press Stop or leave Sentinel.")
        }
    }

    private var historyCard: some View {
        SentinelCard {
            AdaptiveStack {
                SectionLabel(text: "History (this session only)")
                Spacer(minLength: 0)
                if !ping.history.isEmpty { Button("Clear") { ping.clearHistory() }.font(.footnote) }
            }
            if ping.history.isEmpty { Explanation("Finished tests appear here until Sentinel quits. Nothing is stored.") }
            ForEach(ping.history) { run in
                let stats = run.statistics
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Formatters.time.string(from: run.startedAt)) · \(run.host)").font(Theme.mono(.footnote)).foregroundColor(Theme.textPrimary)
                    Text(run.failure ?? "\(run.configuration.method.title): \(stats.received)/\(stats.sent) answered · avg \(ms(stats.average))\(run.cancelled ? " · stopped" : "")")
                        .font(.caption).foregroundColor(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct RunCard: View {
    let run: PingModel.Run
    let live: Bool

    var body: some View {
        let stats = run.statistics
        SentinelCard {
            AdaptiveStack {
                SectionLabel(text: run.configuration.method.title)
                Spacer(minLength: 0)
                StatusPill(text: live ? "Running" : (run.failure != nil && run.results.isEmpty ? "Failed" : (run.cancelled ? "Stopped" : "Completed")),
                           tone: live ? .ready : (run.failure != nil && run.results.isEmpty ? .danger : .info))
            }
            InfoRow(label: "Host", value: run.host, mono: true)
            if let target = run.target {
                InfoRow(label: "Address used", value: "\(target.text) (\(target.family.rawValue))", mono: true)
                if run.resolved.count > 1 {
                    InfoRow(label: "Other addresses", value: run.resolved.dropFirst().map { $0.text }.joined(separator: ", "), mono: true)
                }
            }
            if let failure = run.failure {
                Text(failure).font(.footnote).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            if stats.sent > 0 {
                InfoRow(label: "Answered", value: "\(stats.received) of \(stats.sent)")
                InfoRow(label: "Packet loss", value: stats.lossPercent.map { String(format: "%.0f %%", $0) } ?? "—")
                InfoRow(label: "Min / avg / max", value: "\(ms(stats.minimum)) / \(ms(stats.average)) / \(ms(stats.maximum))", mono: true)
            }
            ForEach(run.results.suffix(12).reversed()) { result in
                HStack {
                    Text("#\(result.sequence)").font(Theme.mono(.caption)).foregroundColor(Theme.textSecondary).frame(width: 40, alignment: .leading)
                    Text(text(result.outcome)).font(Theme.mono(.caption)).foregroundColor(color(result.outcome))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(Formatters.time.string(from: result.at)).font(Theme.mono(.caption2)).foregroundColor(Theme.textSecondary)
                }
            }
        }
    }

    private func text(_ outcome: PingProbeOutcome) -> String {
        switch outcome {
        case .reply(let value):
            if case .tcpConnect = run.configuration.method { return "connected in \(ms(value))" }
            return "reply in \(ms(value))"
        case .refused(let value): return "refused in \(ms(value)) (host answered, port closed)"
        case .timeout: return "no answer within \(Int(run.configuration.timeout)) s"
        case .error(let reason): return reason
        }
    }

    private func color(_ outcome: PingProbeOutcome) -> Color {
        switch outcome {
        case .reply, .refused: return Theme.textPrimary
        case .timeout: return Theme.warning
        case .error: return Theme.danger
        }
    }
}

// MARK: - Local network

struct LocalNetworkView: View {
    @EnvironmentObject private var local: LocalNetworkModel
    @EnvironmentObject private var connection: ConnectionMonitor
    @State private var showSilent = false

    private var networks: [LocalInterfaceNetwork] { connection.snapshot?.ipv4Networks ?? [] }

    var body: some View {
        Screen {
            bonjourCard
            ForEach(local.services) { service in ServiceRow(service: service) }
            sweepCard
            sweepResults
        }
        .navigationBarTitle("Local Network", displayMode: .inline)
        .onAppear {
            connection.refreshAddresses()
            if local.rangeInput.isEmpty, let suggestion = local.suggestedRange(networks: ConnectionMonitor.ipv4Networks()) {
                local.rangeInput = suggestion
            }
        }
    }

    private var bonjourCard: some View {
        SentinelCard(highlight: local.isBrowsing ? Theme.cyan : nil) {
            AdaptiveStack {
                SectionLabel(text: "Bonjour services")
                Spacer(minLength: 0)
                StatusPill(text: bonjourStatus.title, tone: bonjourStatus.tone)
            }
            Explanation("Lists services that devices on this network announce over Bonjour (mDNS): printers, AirPlay and Cast receivers, file shares, smart-home hubs. Listening only; Sentinel does not connect to them. The first time, iOS asks for local network permission.")
            switch local.browseState {
            case .permissionDenied(let text), .failed(let text):
                Text(text).font(.footnote).foregroundColor(Theme.warning).fixedSize(horizontal: false, vertical: true)
                if case .permissionDenied = local.browseState, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open iOS Settings for Sentinel") { UIApplication.shared.open(url) }.font(.footnote)
                }
            case .finished(let at):
                Explanation(local.services.isEmpty
                            ? "Nothing announced in \(Int(LocalNetworkModel.browseDuration)) s (finished \(Formatters.time.string(from: at))). Devices that do not use Bonjour, or that are asleep, do not appear; that does not mean the network is empty."
                            : "Finished \(Formatters.time.string(from: at)): \(local.services.count) service(s).")
            default:
                EmptyView()
            }
            if local.isBrowsing {
                Button(action: { local.stopBrowsing() }) { Label("Stop browsing", systemImage: "stop.fill") }
                    .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
            } else {
                Button(action: { local.startBrowsing() }) { Label("Browse for \(Int(LocalNetworkModel.browseDuration)) s", systemImage: "dot.radiowaves.right") }
                    .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
            }
        }
    }

    private var bonjourStatus: ToolStatus {
        switch local.browseState {
        case .idle: return .idle
        case .browsing: return .running
        case .finished: return .completed
        case .permissionDenied: return .permissionRequired
        case .failed: return .failed
        }
    }

    private var sweepCard: some View {
        SentinelCard(highlight: local.sweepRunning ? Theme.cyan : nil) {
            SectionLabel(text: "Authorised sweep of your network")
            Explanation("Checks which addresses in a range answer: one ICMP echo per address, then one connection attempt to ports 80, 443, 22 and 445 until one answers. Private ranges only, at most 254 addresses, inside a network this iPhone is on, 4 addresses at a time.")
            if networks.isEmpty {
                Explanation("This iPhone has no private IPv4 network right now (for example, it is on cellular data only).")
            } else {
                ForEach(networks, id: \.address) { net in
                    InfoRow(label: net.interface, value: "\(net.address) on \(net.network)", mono: true)
                }
            }
            TextField("Range, e.g. 192.168.1.0/24", text: $local.rangeInput)
                .technicalInput().keyboardType(.numbersAndPunctuation).sentinelField()
                .disabled(local.sweepRunning)
                .accessibilityLabel("Address range to sweep")
            Toggle(isOn: $local.authorizationConfirmed) {
                Text("This network is mine, or I am authorised to test it")
                    .font(.subheadline).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(SwitchToggleStyle(tint: Theme.cyan))
            .disabled(local.sweepRunning)
            if let message = local.sweepMessage {
                Text(message).font(.footnote).foregroundColor(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
            if local.sweepRunning {
                if let progress = local.sweepProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).accentColor(Theme.cyan)
                    Text("\(progress.done) of \(progress.total) addresses probed").font(.caption).foregroundColor(Theme.textSecondary)
                }
                Button(action: { local.stopSweep() }) { Label("Stop sweep", systemImage: "stop.fill") }
                    .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
            } else {
                Button(action: { local.startSweep(networks: ConnectionMonitor.ipv4Networks()) }) { Label("Start sweep", systemImage: "play.fill") }
                    .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                    .disabled(!local.authorizationConfirmed)
            }
        }
    }

    @ViewBuilder private var sweepResults: some View {
        let answered = local.sweepResults.filter { $0.responded }
        let silent = local.sweepResults.filter { !$0.responded }
        if !local.sweepResults.isEmpty {
            SectionLabel(text: "Answered (\(answered.count))")
            ForEach(answered) { host in HostRow(host: host) }
            SentinelCard {
                AdaptiveStack {
                    Text("No response: \(silent.count) address(es)").font(.subheadline).foregroundColor(Theme.textPrimary)
                    Spacer(minLength: 0)
                    if !silent.isEmpty { Button(showSilent ? "Hide" : "Show") { showSilent.toggle() }.font(.footnote) }
                }
                Explanation("No response is not proof that nothing is there: phones, laptops and many smart devices ignore all unsolicited traffic.")
                if showSilent {
                    Text(silent.map { $0.address.description }.joined(separator: ", ")).font(Theme.mono(.caption)).foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ServiceRow: View {
    let service: BonjourService

    var body: some View {
        SentinelCard {
            AdaptiveStack(alignment: .firstTextBaseline) {
                Text(service.name).font(.headline).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                StatusPill(text: "Bonjour", tone: .accent)
            }
            InfoRow(label: "Service", value: "\(BonjourCatalog.meaning(of: service.type)) · \(service.type)")
            InfoRow(label: "Host name", value: service.hostName ?? (service.resolveError ?? "Resolving…"), mono: true)
            if !service.addresses.isEmpty { InfoRow(label: "Addresses", value: service.addresses.joined(separator: ", "), mono: true) }
            InfoRow(label: "Last seen", value: Formatters.time.string(from: service.lastSeen))
            Explanation("The name and service type are what the device announces about itself; Sentinel has not verified them.")
        }
    }
}

private struct HostRow: View {
    let host: DiscoveredHost

    var body: some View {
        SentinelCard {
            AdaptiveStack(alignment: .firstTextBaseline) {
                Text(host.address.description).font(Theme.mono(.headline)).foregroundColor(Theme.textPrimary)
                Spacer(minLength: 0)
                StatusPill(text: "Answered", tone: .verified)
            }
            if case .responded(let response) = host.status {
                InfoRow(label: "How", value: response.methodText)
                InfoRow(label: "Response time", value: ms(response.milliseconds), mono: true)
            }
            InfoRow(label: "Reverse DNS", value: host.reverseName ?? "No name", mono: true)
            InfoRow(label: "Last seen", value: Formatters.time.string(from: host.probedAt))
            if host.reverseName != nil {
                Explanation("The name comes from your network's DNS, not from the device itself.")
            }
        }
    }
}
