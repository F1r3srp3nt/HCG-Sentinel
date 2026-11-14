import SentinelCore
import SwiftUI

struct CapabilitiesView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var radio: RadioModel
    @EnvironmentObject private var helper: HelperModel

    var body: some View {
        Screen {
            Explanation("Each capability is tracked on four separate facts. “Verified” is set only when a real operation succeeds during this session — never by assumption, and never from a package manager, sideloading or a file on disk.")
            SectionLabel(text: "Backends")
            BackendCard(title: "Standard iOS", tone: .verified, status: "Always present",
                        detail: "Supported public APIs in the app sandbox: this app’s connection details, Check My Network, capture-file inspection, Bluetooth LE discovery and test requests.")
            BackendCard(title: "Jailbreak helper", tone: helperTone, status: helperStatus,
                        detail: "A separately installed privileged helper, reached on 127.0.0.1 after mutual authentication. Controls such as own-device filtering appear only for operations an authenticated helper reports. Monitor mode, packet injection and radio control are never inferred from jailbreak markers and are not part of the helper interface.")
            BackendCard(title: "External node", tone: nodeTone, status: nodeStatus,
                        detail: "A Mac or analysis node you operate, reached over the authenticated node protocol. Nearby Wi-Fi discovery and spectrum appear only when an authenticated node offers them, and count as verified only when a non-simulated node returns valid results.")
            ForEach(CapabilityTier.allCases, id: \.self) { tier in
                SectionLabel(text: tier.title, tone: tier == .onDevice ? .ready : tier == .externalNode ? .info : tier == .feasibility ? .off : .accent)
                Explanation(tierNote(tier))
                ForEach(app.capabilities.filter { $0.descriptor.tier == tier }) { state in
                    CapabilityCard(state: state)
                }
            }
        }
        .navigationBarTitle("Capabilities", displayMode: .inline)
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

private struct CapabilityCard: View {
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
