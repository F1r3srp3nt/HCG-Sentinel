import SentinelCore
import SwiftUI
import UIKit

// MARK: - Security Intelligence Center (hub)

/// Every destination in Sentinel, grouped into the twelve areas. Generated from the same registry HCG Nexus links
/// use, so anything a link can open can also be opened here, without Nexus.
struct SecurityCenterView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Screen {
            VStack(alignment: .leading, spacing: 8) {
                ScaledHCGLockup(word: "SENTINEL", maxScale: 1.2)
                SweepLine()
                Text("SECURITY INTELLIGENCE CENTER")
                    .font(.custom(HCGLockup.fontName, size: 11, relativeTo: .caption))
                    .kerning(2.5)
                    .foregroundColor(Theme.cyan.opacity(0.9))
                    .accessibilityAddTraits(.isHeader)
            }
            Explanation("Every Sentinel screen, in one place. Opening a screen never starts anything: each tool runs only when you start it there.")
            ForEach(SentinelArea.allCases) { area in
                SectionLabel(text: area.title, tone: area == .externalNodes ? .info : .ready)
                ForEach(area.sections) { section in
                    NavigationLink(destination: SectionContent(section: section)) {
                        CenterRow(section: section, status: status(section))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .navigationBarTitle("Center", displayMode: .inline)
    }

    /// A short live status for a destination, from the capabilities it serves. Never more than the registry says.
    private func status(_ section: SentinelSection) -> String? {
        let states = app.capabilities.filter { $0.profile.section == section }
        guard !states.isEmpty else { return nil }
        if states.contains(where: { $0.classification == .verified }) { return "Verified this session" }
        if states.allSatisfy({ $0.classification == .interfaceOnly || $0.classification == .research }) { return "Not available yet" }
        if states.contains(where: { $0.classification == .disabled }) { return "Off until enabled" }
        return nil
    }
}

private struct CenterRow: View {
    let section: SentinelSection
    let status: String?

    var body: some View {
        SentinelCard {
            HStack(spacing: 12) {
                Image(systemName: section.icon).foregroundColor(Theme.cyan).frame(width: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title).font(.headline).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    Text(section.summary).font(.caption).foregroundColor(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    if let status = status {
                        Text(status).font(.caption2.weight(.semibold)).foregroundColor(status.hasPrefix("Verified") ? Theme.ok : Theme.textSecondary)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption).foregroundColor(Theme.textSecondary).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Device Security

struct DeviceSecurityView: View {
    @EnvironmentObject private var intelligence: IntelligenceModel
    @State private var sharing = false

    var body: some View {
        Screen {
            SentinelCard(highlight: intelligence.deviceSecurityRunning ? Theme.cyan : nil) {
                SectionLabel(text: "Read-only checks of this iPhone")
                Explanation("Passcode and biometrics, system version, Sentinel's own data protection and transport security, the device environment, and — when Sentinel was installed by a package manager — whether its package record and files are intact. Nothing is changed, installed or disabled.")
                Button(action: { intelligence.runDeviceSecurity() }) {
                    Label(intelligence.deviceSecurityRunning ? "Checking…" : (intelligence.deviceSecurity == nil ? "Run checks" : "Run again"), systemImage: "checkmark.shield")
                }
                .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                .disabled(intelligence.deviceSecurityRunning)
            }
            if let report = intelligence.deviceSecurity {
                SentinelCard {
                    AdaptiveStack {
                        Text(report.edition).font(.headline).foregroundColor(Theme.textPrimary)
                        Spacer(minLength: 0)
                        Text("Checked \(Formatters.time.string(from: report.generatedAt))").font(.caption).foregroundColor(Theme.textSecondary)
                    }
                    Text(summary(report)).font(.subheadline).foregroundColor(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Button(action: { sharing = true }) { Label("Export report", systemImage: "square.and.arrow.up") }
                        .font(.footnote)
                }
                ForEach(report.checks) { check in CheckCard(check: check) }
            }
        }
        .navigationBarTitle("Device Security", displayMode: .inline)
        .sheet(isPresented: $sharing) {
            if let report = intelligence.deviceSecurity { ShareSheet(items: [report.text()]) }
        }
    }

    private func summary(_ report: DeviceSecurityReport) -> String {
        let c = report.counts
        return "\(c[.pass] ?? 0) pass · \((c[.fail] ?? 0) + (c[.warning] ?? 0)) need attention · \(c[.info] ?? 0) information · \(c[.unavailable] ?? 0) not readable"
    }
}

private struct CheckCard: View {
    let check: DeviceSecurityCheck

    private var tone: Tone {
        switch check.outcome {
        case .pass: return .verified
        case .warning: return .warning
        case .fail: return .danger
        case .info: return .info
        case .unavailable: return .off
        }
    }

    var body: some View {
        SentinelCard(highlight: check.outcome == .fail ? Theme.danger : nil) {
            AdaptiveStack {
                Text(check.title).font(.headline).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                StatusPill(text: check.outcome.rawValue, tone: tone)
            }
            Text(check.detail).font(.subheadline).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
            Text("Evidence: \(check.evidence)").font(Theme.mono(.caption)).foregroundColor(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let fix = check.remediation { NoticeBanner(icon: "arrow.right.circle", text: fix, tone: .ready) }
        }
    }
}

// MARK: - Security Reports

struct SecurityReportsView: View {
    @EnvironmentObject private var intelligence: IntelligenceModel
    @EnvironmentObject private var lab: SecurityLabModel
    @State private var picking = false
    @State private var exportText: String?

    var body: some View {
        Screen {
            SectionLabel(text: "Security Laboratory reports")
            if lab.reports.isEmpty {
                Explanation("None yet. Run Secret Scanner, Exposure Check or the Authentication Defense Lab.")
            }
            ForEach(lab.reports.prefix(10)) { record in
                NavigationLink(destination: SecurityReportView(recordID: record.id)) { ReportRow(record: record) }
                    .buttonStyle(PlainButtonStyle())
            }

            SectionLabel(text: "Device security")
            if let report = intelligence.deviceSecurity {
                NavigationLink(destination: DeviceSecurityView()) {
                    SentinelCard { Text("\(report.edition) · \(Formatters.time.string(from: report.generatedAt))").font(.subheadline).foregroundColor(Theme.textPrimary) }
                }.buttonStyle(PlainButtonStyle())
            } else {
                Explanation("Not run this session. Open Device Security to run the checks.")
            }

            SectionLabel(text: "Imported diagnostic reports")
            SentinelCard {
                Explanation("Import hcg.diagnostic-report/1 files, for example HCG System Tester's connection-security findings (System Tester › Ecosystem › Export security findings for Sentinel). Reports are shown as text; nothing in them is opened or run, and Sentinel does not contact the app that made them.")
                Button(action: { picking = true }) { Label("Import a report file…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
                if let message = intelligence.importMessage {
                    Text(message).font(.footnote).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(intelligence.importedReports) { entry in
                NavigationLink(destination: ImportedReportView(entry: entry)) {
                    SentinelCard {
                        AdaptiveStack {
                            Text(entry.report.title).font(.headline).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            StatusPill(text: "Imported", tone: .accent)
                        }
                        Text("\(entry.report.origin.app) \(entry.report.origin.appVersion) · \(entry.report.summary.findingCount) finding(s)\(entry.report.summary.highestSeverity.map { " · highest \($0)" } ?? "")")
                            .font(.caption).foregroundColor(Theme.textSecondary)
                    }
                }.buttonStyle(PlainButtonStyle())
            }

            SectionLabel(text: "Network diagnostic history")
            if intelligence.history.isEmpty {
                Explanation("Check My Network runs and finished pings are kept here (addresses masked), so you can compare them over time.")
            }
            ForEach(intelligence.history.prefix(20)) { entry in
                SentinelCard {
                    AdaptiveStack {
                        Text(entry.kind.rawValue).font(.subheadline.weight(.semibold)).foregroundColor(Theme.textPrimary)
                        Spacer(minLength: 0)
                        Text(Formatters.time.string(from: entry.at) + " · " + DateFormatter.localizedString(from: entry.at, dateStyle: .short, timeStyle: .none))
                            .font(Theme.mono(.caption)).foregroundColor(Theme.textSecondary)
                    }
                    Text(entry.headline).font(.footnote).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    Text(entry.facts.joined(separator: " · ")).font(.caption).foregroundColor(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Button("Export") { exportText = entry.text }.font(.footnote)
                }
            }
            if !intelligence.history.isEmpty {
                Button("Clear history") { intelligence.clearHistory() }.font(.footnote)
            }
        }
        .navigationBarTitle("Security Reports", displayMode: .inline)
        .sheet(isPresented: $picking) {
            DocumentPicker { url in intelligence.importReport(from: url) }.ignoresSafeArea()
        }
        .sheet(item: Binding(get: { exportText.map(ExportItem.init) }, set: { exportText = $0?.text })) { item in
            ShareSheet(items: [item.text])
        }
    }
}

struct ExportItem: Identifiable {
    let text: String
    var id: Int { text.hashValue }
}

private struct ImportedReportView: View {
    let entry: ImportedReportStore.Entry

    var body: some View {
        Screen {
            NoticeBanner(icon: "tray.and.arrow.down", text: "IMPORTED REPORT — produced by \(entry.report.origin.app), not by Sentinel. Shown as text only.", tone: .ready)
            ForEach(Array(ReportTextRenderer.sections(entry.report).enumerated()), id: \.offset) { item in
                SentinelCard {
                    SectionLabel(text: item.element.title)
                    ForEach(Array(item.element.lines.enumerated()), id: \.offset) { line in
                        Text(line.element).font(.footnote).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .navigationBarTitle("Imported report", displayMode: .inline)
    }
}

// MARK: - External nodes

struct ExternalNodesView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var radio: RadioModel
    @EnvironmentObject private var helper: HelperModel
    @EnvironmentObject private var devices: ConnectedDevicesModel

    var body: some View {
        Screen {
            Explanation("Hardware and services Sentinel can work with. Each one is shown as available only after it answered; the iPhone itself has no spectrum or monitor-mode radio.")
            node(title: "HCG Server (Device Link)", system: "server.rack", status: serverStatus, tone: serverTone,
                 detail: "Pair from Connected Devices to share redacted reports and read the server's health. The server receives only reports you choose to share; it cannot run anything on this iPhone.",
                 destinations: [.devices, .serverHealth])
            node(title: "Radio analysis node (HCG Signal Contractor)", system: "antenna.radiowaves.left.and.right", status: radioStatus, tone: radio.state.isAuthenticated ? .verified : .off,
                 detail: "Receive-only spectrum and nearby Wi-Fi scans come from an external node that speaks the authenticated Sentinel Node Protocol v2. HCG Signal Contractor owns that hardware; it has no published node implementation yet, so a mock node (labelled simulated) is the only one available for development.",
                 destinations: [.radio])
            node(title: "HCG System Tester (Mac)", system: "desktopcomputer", status: "Files only: \(app.importedReportCount) report(s) imported", tone: app.importedReportCount > 0 ? .verified : .off,
                 detail: "System Tester owns device connectivity on the Mac and exports hcg.diagnostic-report/1 files; Sentinel evaluates them. Import them in Security Reports. There is no live connection between the two apps.",
                 destinations: [.reports])
            node(title: "Mac debugging proxy", system: "laptopcomputer", status: "Interface only — no Mac companion exists", tone: .off,
                 detail: "The adapter interface is specified (docs/MAC_PROXY_ADAPTER.md), but nothing implements it, so nothing is intercepted.",
                 destinations: [])
            node(title: "Privileged helper (Unleashed)", system: "lock.shield", status: helperStatus, tone: helperTone,
                 detail: "An optional helper on a jailbroken iPhone, reached on 127.0.0.1 after mutual authentication. Sentinel ships no helper; any new privileged component needs its own security review and your explicit approval.",
                 destinations: [.settings])
        }
        .navigationBarTitle("External Nodes", displayMode: .inline)
    }

    private func node(title: String, system: String, status: String, tone: Tone, detail: String, destinations: [SentinelSection]) -> some View {
        SentinelCard {
            AdaptiveStack {
                Image(systemName: system).foregroundColor(Theme.cyan).accessibilityHidden(true)
                Text(title).font(.headline).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Circle().fill(tone.color).frame(width: 8, height: 8)
                Text(status).font(.subheadline).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
            }
            Explanation(detail)
            ForEach(destinations) { section in
                NavigationLink(destination: SectionContent(section: section)) { Label("Open \(section.title)", systemImage: "arrow.right.circle") }
                    .font(.footnote)
            }
        }
    }

    private var serverStatus: String {
        switch devices.link {
        case .connected: return "Connected"
        case .notPaired: return "Not paired"
        case .pairing: return "Pairing — waiting for the server owner"
        case .offline(let reason, _): return "Offline: \(reason)"
        case .ended(let reason), .paused(let reason): return reason
        }
    }

    private var serverTone: Tone {
        if case .connected = devices.link { return .verified }
        if case .offline = devices.link { return .warning }
        return .off
    }

    private var radioStatus: String {
        guard radio.state.isAuthenticated, let node = radio.node else { return radio.state.isActive ? radio.state.title : "Not connected" }
        return "Authenticated: \(node.nodeName)\(node.simulated ? " (simulated)" : "")"
    }

    private var helperStatus: String {
        switch helper.probeResult {
        case .notProbed: return helper.hasPairingKey ? "Not probed" : "Not set up"
        case .noAnswer: return "No helper answered"
        case .verified: return "Authenticated helper answered"
        }
    }

    private var helperTone: Tone {
        if case .verified = helper.probeResult { return .verified }
        return .off
    }
}

// MARK: - HCG Ecosystem

struct EcosystemView: View {
    private struct Product: Identifiable {
        let id: String
        let role: String
        let contract: String
        let status: String
    }

    private let products: [Product] = [
        Product(id: "HCG Nexus", role: "Control hub and shortcut panel on the jailbroken iPhone",
                contract: "Opens Sentinel screens with hcgsentinel://open/<screen> and hcgsentinel://report/<id>. Links only navigate.",
                status: "Working: every screen it can open is also in Sentinel's own Center"),
        Product(id: "HCG Server", role: "Your server: pairing, report sharing, health",
                contract: "HCG Device Link (hcg.diagnostic-report/1); HCG Connect sign-in or local-development pairing.",
                status: "Pairing and health implemented; Security Lab execution on the server not yet available"),
        Product(id: "HCG System Tester", role: "Device connectivity and hardware diagnostics on the Mac",
                contract: "Exports hcg.diagnostic-report/1; opens Sentinel with hcgsentinel://open/<screen>.",
                status: "Import of its reports implemented (files you choose)"),
        Product(id: "HCG Signal Contractor", role: "Hardware and signal research",
                contract: "Radio nodes speak Sentinel Node Protocol v2 (receive-only).",
                status: "No published interface yet; Sentinel uses the node protocol when one exists"),
        Product(id: "HCG Halo", role: "Edge glow for the HCG panel",
                contract: "Visual only.", status: "No data exchanged with Sentinel"),
        Product(id: "HCG Repo", role: "Package distribution (Candidate, Stable)",
                contract: "Sentinel's product page link in Settings › About.", status: "Sentinel Unleashed is distributed as a Candidate beta"),
    ]

    var body: some View {
        Screen {
            Explanation("How Sentinel works with other HCG products. Each line is what exists today; nothing here connects by itself.")
            ForEach(products) { product in
                SentinelCard {
                    Text(product.id).font(.headline).foregroundColor(Theme.textPrimary)
                    Text(product.role).font(.subheadline).foregroundColor(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    InfoRow(label: "Contract", value: product.contract)
                    InfoRow(label: "Status", value: product.status)
                }
            }
        }
        .navigationBarTitle("HCG Ecosystem", displayMode: .inline)
    }
}

// MARK: - Capture statistics

struct CaptureStatisticsCard: View {
    let capture: ParsedCapture
    @State private var sharing = false

    var body: some View {
        let stats = CaptureStatistics.compute(capture)
        SentinelCard {
            SectionLabel(text: "Traffic statistics")
            InfoRow(label: "Bytes on the wire", value: Formatters.bytes(stats.originalBytes))
            if stats.truncatedPackets > 0 { InfoRow(label: "Truncated packets", value: "\(stats.truncatedPackets)") }
            InfoRow(label: "Endpoints", value: "\(stats.distinctEndpoints)")
            if let duration = stats.duration {
                InfoRow(label: "Duration", value: String(format: "%.3f s", duration), mono: true)
                if let rate = stats.packetsPerSecond { InfoRow(label: "Average rate", value: String(format: "%.1f packets/s", rate), mono: true) }
            }
            ForEach(stats.protocols.prefix(6), id: \.name) { item in
                InfoRow(label: item.name, value: "\(item.packets) packets · \(Formatters.bytes(item.bytes))", mono: true)
            }
            if !stats.timeline.isEmpty {
                Text(String(format: "Timeline · %g s per bar", stats.bucketSeconds)).font(.caption).foregroundColor(Theme.textSecondary)
                TimelineBars(values: stats.timeline.map { $0.packets })
                    .frame(height: 44)
                    .accessibilityLabel("Packets over time, \(stats.timeline.count) intervals, peak \(stats.timeline.map { $0.packets }.max() ?? 0)")
            }
            if !stats.conversations.isEmpty {
                Text("Top conversations").font(.caption).foregroundColor(Theme.textSecondary)
                ForEach(Array(stats.conversations.prefix(5).enumerated()), id: \.offset) { item in
                    Text("\(item.element.a) ↔ \(item.element.b) · \(item.element.protocolName) · \(item.element.packets)")
                        .font(Theme.mono(.caption)).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: { sharing = true }) { Label("Share privacy-preserving report", systemImage: "square.and.arrow.up") }
                .font(.footnote)
            Explanation("The report replaces every address with host-1, host-2… and contains no payloads, ports beyond service names, or the file name.")
        }
        .sheet(isPresented: $sharing) { ShareSheet(items: [CaptureReport.text(capture)]) }
    }
}

private struct TimelineBars: View {
    let values: [Int]

    var body: some View {
        GeometryReader { proxy in
            let peak = max(values.max() ?? 1, 1)
            let width = proxy.size.width / CGFloat(max(values.count, 1))
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.offset) { item in
                    Rectangle()
                        .fill(Theme.cyan.opacity(item.element == 0 ? 0.15 : 0.8))
                        .frame(width: max(width - 1, 1), height: max(proxy.size.height * CGFloat(item.element) / CGFloat(peak), 1))
                        .frame(width: width, alignment: .bottom)
                }
            }
        }
    }
}
