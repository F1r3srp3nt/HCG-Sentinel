import SentinelCore
import SwiftUI

struct NetworkCheckView: View {
    @EnvironmentObject private var check: NetworkCheckModel

    var body: some View {
        Screen {
            if check.previewMode {
                PreviewBanner(detail: "Check My Network is paused in Preview mode. It never shows sample results: every finding comes from a real check.")
            }
            introCard
            controlCard
            if let report = check.report {
                summaryCard(report)
                ForEach(sortedFindings(report)) { finding in
                    FindingCard(finding: finding)
                }
            }
        }
        .navigationBarTitle("Check My Network", displayMode: .inline)
        .onAppear {
            #if DEBUG
            // Screenshot checks in CI launch with -SentinelRunNetworkCheck to capture a finished report.
            if ProcessInfo.processInfo.arguments.contains("-SentinelRunNetworkCheck"), check.report == nil { check.start() }
            #endif
        }
    }

    private var introCard: some View {
        SentinelCard {
            SectionLabel(text: "What this checks")
            Explanation("Looks for observable problems on the network this device is using right now: the connection itself, Wi-Fi security (when iOS reveals it), proxy and VPN settings, DNS answers, captive portals, and whether HTTPS certificates are trusted.")
            Explanation("When you press Start it contacts example.com, captive.apple.com and www.apple.com, each with a time limit. Nothing runs in the background and results stay on this device.")
            Explanation("It does not scan other devices, attack anything, or change any setting.")
        }
    }

    @ViewBuilder private var controlCard: some View {
        SentinelCard(highlight: check.isRunning ? Theme.cyan : nil) {
            switch check.state {
            case .running(let step, let completed, let total):
                AdaptiveStack {
                    Text("Checking: \(step.title)")
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text("\(completed + 1) of \(total)")
                        .font(Theme.mono(.subheadline))
                        .foregroundColor(Theme.textSecondary)
                }
                ProgressView(value: Double(completed), total: Double(total))
                    .accentColor(Theme.cyan)
                    .accessibilityLabel("Progress: step \(completed + 1) of \(total)")
                Button(action: { check.cancel() }) {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
                Explanation("Cancelling stops the request in flight immediately and keeps whatever was found so far.")
            default:
                Button(action: { check.start() }) {
                    Label(check.report == nil ? "Start check" : "Run again", systemImage: "play.fill")
                }
                .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                .disabled(check.previewMode)
                Explanation("Takes up to about a minute on a slow network. Each step has its own time limit.")
            }
        }
    }

    private func summaryCard(_ report: AssessmentReport) -> some View {
        let concerns = report.count(.securityConcern)
        return SentinelCard(highlight: concerns > 0 ? Theme.warning : nil) {
            SectionLabel(text: report.cancelled ? "Incomplete results" : "Results", tone: concerns > 0 ? .warning : .ready)
            Text(report.headline)
                .font(.headline)
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            InfoRow(label: "Security concerns", value: "\(concerns)")
            InfoRow(label: "Notices", value: "\(report.count(.notice))")
            InfoRow(label: "Connectivity problems", value: "\(report.count(.connectivityProblem))")
            InfoRow(label: "Unavailable or not checked", value: "\(report.count(.unavailable) + report.count(.notChecked))")
            InfoRow(label: "Finished", value: Formatters.preciseTime.string(from: report.finishedAt), mono: true)
            NoticeBanner(icon: "info.circle", text: report.disclaimer, tone: .info)
        }
    }

    private func sortedFindings(_ report: AssessmentReport) -> [AssessmentFinding] {
        let order: [AssessmentFinding.Kind] = [.securityConcern, .notice, .connectivityProblem, .unavailable, .notChecked, .observation]
        return report.findings.enumerated().sorted { lhs, rhs in
            let l = order.firstIndex(of: lhs.element.kind) ?? 99, r = order.firstIndex(of: rhs.element.kind) ?? 99
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map { $0.element }
    }
}

private struct FindingCard: View {
    let finding: AssessmentFinding

    var body: some View {
        SentinelCard(highlight: finding.kind == .securityConcern ? Theme.warning : nil) {
            AdaptiveStack {
                StatusPill(text: finding.kind.label, tone: finding.kind.tone)
                Text(finding.step.title)
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(finding.title)
                .font(.headline)
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Evidence").font(.caption).foregroundColor(Theme.textSecondary)
                ForEach(Array(finding.evidence.enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(Theme.mono(.footnote))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Observed \(Formatters.preciseTime.string(from: finding.observedAt))")
                    .font(Theme.mono(.caption))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panelInset))
            if let remediation = finding.remediation {
                NoticeBanner(icon: "wrench.and.screwdriver", text: remediation, tone: finding.kind == .securityConcern ? .warning : .ready)
            }
            Explanation("Limitations: \(finding.limitations)")
        }
        .accessibilityElement(children: .contain)
    }
}

extension AssessmentFinding.Kind {
    var label: String {
        switch self {
        case .securityConcern: return "Security concern"
        case .notice: return "Notice"
        case .connectivityProblem: return "Connectivity"
        case .unavailable: return "Unavailable"
        case .notChecked: return "Not checked"
        case .observation: return "Observed"
        }
    }

    var tone: Tone {
        switch self {
        case .securityConcern: return .warning
        case .notice: return .accent
        case .connectivityProblem: return .info
        case .unavailable, .notChecked: return .off
        case .observation: return .ready
        }
    }
}
