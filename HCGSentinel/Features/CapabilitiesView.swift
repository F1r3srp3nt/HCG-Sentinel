import SentinelCore
import SwiftUI

struct CapabilitiesView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Screen {
            Explanation("Each capability is tracked on four separate facts. “Verified” is set only when a real operation succeeds during this session — never by assumption, and never from a package manager, sideloading or a file on disk.")
            ForEach(CapabilityTier.allCases, id: \.self) { tier in
                SectionLabel(text: tier.title, tone: tier == .onDevice ? .ready : tier == .externalNode ? .info : .accent)
                Explanation(tierNote(tier))
                ForEach(app.capabilities.filter { $0.descriptor.tier == tier }) { state in
                    CapabilityCard(state: state)
                }
            }
        }
        .navigationBarTitle("Capabilities", displayMode: .inline)
    }

    private func tierNote(_ tier: CapabilityTier) -> String {
        switch tier {
        case .onDevice:
            return "Built on supported iOS APIs inside the app sandbox."
        case .externalNode:
            return "The real work happens on a Mac or radio node you operate. Sentinel only connects to it."
        case .privilegedHelper:
            return "Needs a separately installed helper on a compatible device. Sentinel includes none, and installing a package does not grant these permissions by itself."
        }
    }
}

private struct CapabilityCard: View {
    let state: CapabilityState

    var body: some View {
        SentinelCard(highlight: state.readiness == .verified ? Theme.ok : nil) {
            HStack(alignment: .top) {
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
