import SentinelCore
import SwiftUI

struct CapabilitiesView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var radio: RadioModel
    @EnvironmentObject private var helper: HelperModel
    @State private var filter: CapabilityFilter = .all

    private var shown: [CapabilityState] { app.capabilities.filter(filter.matches) }

    var body: some View {
        Screen {
            Explanation("Every capability Sentinel knows about, from the code itself. “Verified” is set only when a real operation succeeds in this session — never by assumption, and never from a package manager, sideloading or a file on disk. The last successful operation is kept as history.")
            Picker("Filter", selection: $filter) {
                ForEach(CapabilityFilter.allCases) { f in Text("\(f.rawValue) (\(app.capabilities.filter(f.matches).count))").tag(f) }
            }
            .pickerStyle(MenuPickerStyle())
            classSummary
            ForEach(CapabilityTier.allCases, id: \.self) { tier in
                let states = shown.filter { $0.descriptor.tier == tier }
                if !states.isEmpty {
                    SectionLabel(text: tier.title, tone: tier == .onDevice ? .ready : tier == .externalNode ? .info : tier == .feasibility ? .off : .accent)
                    Explanation(tierNote(tier))
                    ForEach(states) { state in
                        NavigationLink(destination: CapabilityDetailView(id: state.id)) { CapabilityCard(state: state) }
                            .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            if shown.isEmpty {
                EmptyState(icon: "line.horizontal.3.decrease.circle", title: "Nothing in this filter", message: "Choose another filter to see the other capabilities.")
            }
            SectionLabel(text: "Backends")
            BackendCard(title: "Standard iOS", tone: .verified, status: "Always present",
                        detail: "Supported public APIs: connection, Wi-Fi details, ping, local discovery, Check My Network, capture files, Bluetooth LE, test requests, Security Laboratory and device security checks.")
            BackendCard(title: "Jailbreak helper", tone: helperTone, status: helperStatus,
                        detail: "A separately installed privileged helper, reached on 127.0.0.1 after mutual authentication. Sentinel ships none. Monitor mode, packet injection and radio control are never inferred from jailbreak markers and are not part of the helper interface.")
            BackendCard(title: "External node", tone: nodeTone, status: nodeStatus,
                        detail: "A Mac, HCG Server or radio node you operate. Its features count as verified only after a non-simulated node returns valid results.")
            if app.capabilities.contains(where: { $0.lastSuccess != nil || $0.lastFailure != nil }) {
                Button("Forget stored evidence history") { app.registry.clearHistory() }.font(.footnote)
            }
        }
        .navigationBarTitle("Capability Center", displayMode: .inline)
    }

    private var classSummary: some View {
        SentinelCard {
            SectionLabel(text: "By implementation state")
            ForEach(CapabilityClass.allCases, id: \.self) { cls in
                let count = app.capabilities.filter { $0.classification == cls }.count
                if count > 0 { InfoRow(label: cls.rawValue, value: "\(count)") }
            }
        }
    }

    private var helperStatus: String {
        switch helper.probeResult {
        case .notProbed:
            if !helper.hasPairingKey { return "Not set up: no pairing key" }
            return helper.remoteConnectionsEnabled ? "Not probed yet" : "Not probed (Remote connections is off)"
        case .noAnswer: return "No helper answered"
        case .verified(let report, let date):
            let operations = report.recognizedOperations.map { $0.rawValue }.sorted().joined(separator: ", ")
            return "Authenticated at \(Formatters.time.string(from: date)) · \(operations.isEmpty ? "no recognised operations" : operations)"
        }
    }

    private var helperTone: Tone {
        if case .verified = helper.probeResult { return .verified }
        if case .noAnswer = helper.probeResult { return .warning }
        return .off
    }

    private var nodeStatus: String {
        guard radio.state.isAuthenticated, let node = radio.node else {
            if case .failed = radio.state { return "Last connection failed" }
            return radio.state.isActive ? radio.state.title : "Not connected"
        }
        let features = radio.capabilities?.recognizedFeatures.sorted().joined(separator: ", ") ?? ""
        return "Authenticated: \(node.nodeName)\(node.simulated ? " (simulated)" : "") · \(features.isEmpty ? "no recognised features" : features)"
    }

    private var nodeTone: Tone {
        if radio.state.isAuthenticated { return radio.isSimulatedNode ? .accent : .verified }
        if case .failed = radio.state { return .warning }
        return .off
    }

    private func tierNote(_ tier: CapabilityTier) -> String {
        switch tier {
        case .onDevice:
            return "Built on supported iOS APIs inside the app sandbox."
        case .externalNode:
            return "The real work happens on a Mac or radio node you operate. Sentinel only connects to it."
        case .privilegedHelper:
            return "Needs a separately installed helper on a compatible device. Sentinel includes none, and installing a package does not grant these permissions by itself."
        case .feasibility:
            return "Ideas under investigation, listed so their status is clear. None is implemented, none can be turned on, and Sentinel shows no data for them."
        }
    }
}

struct CapabilityCard: View {
    let state: CapabilityState

    var body: some View {
        SentinelCard(highlight: state.readiness == .verified ? Theme.ok : nil) {
            AdaptiveStack {
                Text(state.descriptor.title)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                StatusPill(text: state.readiness.label, tone: state.readiness.tone)
            }
            Explanation(state.descriptor.summary)
            Text(state.classification.rawValue).font(.caption.weight(.semibold)).foregroundColor(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                fact("Implementation", implementationText, implementationTone)
                fact("Environment", environmentText, environmentTone)
                fact("Enabled by you", state.userEnabled ? "Yes" : "No", state.userEnabled ? .ready : .off)
                fact("Verified", verificationText, verificationTone)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panelInset))
            Text(state.explanation)
                .font(.footnote)
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let action = state.action {
                NoticeBanner(icon: "arrow.right.circle", text: action, tone: .ready)
            }
            Explanation("Limits: \(state.descriptor.limits)")
        }
    }

    private func fact(_ label: String, _ value: String, _ tone: Tone) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(tone.color).frame(width: 8, height: 8)
            Text(label)
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.footnote, design: .default).weight(.semibold))
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var implementationText: String {
        switch state.descriptor.implementation {
        case .included: return "Included"
        case .interfaceOnly: return "Interface only"
        case .notIncluded: return "Not included"
        }
    }

    private var implementationTone: Tone {
        switch state.descriptor.implementation {
        case .included: return .ready
        case .interfaceOnly: return .accent
        case .notIncluded: return .off
        }
    }

    private var environmentText: String {
        switch state.environment {
        case .supported: return "Supported"
        case .unsupported: return "Not supported"
        case .unknown: return "Not determined"
        }
    }

    private var environmentTone: Tone {
        switch state.environment {
        case .supported: return .ready
        case .unsupported: return .warning
        case .unknown: return .off
        }
    }

    private var verificationText: String {
        switch state.verification {
        case .unverified: return "No"
        case .verified(let date, _): return "Yes, at \(Formatters.time.string(from: date))"
        case .failed(let date, _): return "Failed at \(Formatters.time.string(from: date))"
        }
    }

    private var verificationTone: Tone {
        switch state.verification {
        case .unverified: return .off
        case .verified: return .verified
        case .failed: return .danger
        }
    }
}

private struct BackendCard: View {
    let title: String
    let tone: Tone
    let status: String
    let detail: String

    var body: some View {
        SentinelCard {
            AdaptiveStack {
                Text(title)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Spacer(minLength: 0)
                StatusPill(text: tone == .verified ? "Verified" : tone == .off ? "Unverified" : tone == .accent ? "Simulated" : "Problem", tone: tone)
            }
            Text(status)
                .font(.subheadline)
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Explanation(detail)
        }
        .accessibilityElement(children: .combine)
    }
}


/// Everything Sentinel knows about one capability, with a way to open it and, where one exists, a bounded
/// self-test that records verification only if it really succeeds.
struct CapabilityDetailView: View {
    let id: CapabilityID
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var intelligence: IntelligenceModel

    var body: some View {
        Screen {
            if let state = app.capabilityState(id) {
                CapabilityCard(state: state)
                let profile = state.profile
                SentinelCard {
                    SectionLabel(text: "Requirements")
                    InfoRow(label: "Implementation", value: state.classification.rawValue)
                    InfoRow(label: "Platforms", value: profile.platforms)
                    InfoRow(label: "Hardware", value: profile.hardware)
                    InfoRow(label: "Permissions", value: profile.permissions.isEmpty ? "—" : profile.permissions.joined(separator: "\n"))
                    InfoRow(label: "Available now", value: availability(state))
                    InfoRow(label: "Enabled", value: state.userEnabled ? "Yes" : "No")
                }
                SentinelCard {
                    SectionLabel(text: "Evidence")
                    InfoRow(label: "This session", value: sessionText(state))
                    InfoRow(label: "Last success", value: state.lastSuccess.map { "\(stamp($0.at)) — \($0.text)" } ?? "Never recorded")
                    InfoRow(label: "Last failure", value: state.lastFailure.map { "\(stamp($0.at)) — \($0.text)" } ?? "None recorded")
                    Explanation("How it is verified: \(state.descriptor.verificationMethod)")
                }
                if let test = profile.selfTest { selfTestCard(test) }
                if let section = profile.section {
                    NavigationLink(destination: SectionContent(section: section)) {
                        Label("Open \(section.title)", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
                }
            }
        }
        .navigationBarTitle(app.capabilityState(id)?.descriptor.title ?? "Capability", displayMode: .inline)
    }

    private func selfTestCard(_ test: CapabilitySelfTest) -> some View {
        let state = intelligence.selfTests[test] ?? .idle
        return SentinelCard(highlight: state == .running ? Theme.cyan : nil) {
            SectionLabel(text: "Verification test")
            Text(test.title).font(.headline).foregroundColor(Theme.textPrimary)
            Explanation(test.scope)
            switch state {
            case .idle: EmptyView()
            case .running: Text("Running…").font(.footnote).foregroundColor(Theme.textSecondary)
            case .passed(let text): NoticeBanner(icon: "checkmark.seal", text: text, tone: .verified)
            case .failed(let text): NoticeBanner(icon: "exclamationmark.triangle", text: text, tone: .danger)
            }
            Button(action: { intelligence.run(test) }) { Label("Run test", systemImage: "play.fill") }
                .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                .disabled(state == .running || !(app.capabilityState(id)?.userEnabled ?? false))
            if !(app.capabilityState(id)?.userEnabled ?? false) {
                Explanation("Turn the capability on first (see Permissions). A test never turns anything on.")
            }
        }
    }

    private func availability(_ state: CapabilityState) -> String {
        switch state.environment {
        case .supported: return "Yes"
        case .unsupported(let reason): return "No — \(reason)"
        case .unknown(let reason): return "Not determined — \(reason)"
        }
    }

    private func sessionText(_ state: CapabilityState) -> String {
        switch state.verification {
        case .unverified: return "Not verified yet"
        case .verified(let at, let evidence): return "Verified at \(Formatters.time.string(from: at)) — \(evidence)"
        case .failed(let at, let reason): return "Failed at \(Formatters.time.string(from: at)) — \(reason)"
        }
    }

    private func stamp(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }
}
