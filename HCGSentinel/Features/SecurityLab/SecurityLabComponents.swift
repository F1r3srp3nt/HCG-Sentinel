import SentinelCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension FindingSeverity {
    var tone: Tone {
        switch self {
        case .critical, .high: return .danger
        case .medium: return .warning
        case .low: return .accent
        case .info: return .info
        }
    }
}

extension CheckOutcome {
    var tone: Tone {
        switch self {
        case .passed: return .verified
        case .finding: return .warning
        case .inconclusive: return .info
        case .unsupported: return .off
        case .failedToExecute: return .danger
        }
    }
}

extension AssessmentRunStatus {
    var tone: Tone {
        switch self {
        case .completed: return .ready
        case .running: return .accent
        case .cancelled, .timedOut: return .warning
        case .failedToExecute: return .danger
        case .unsupported: return .off
        }
    }
}

extension SecurityModule {
    var icon: String {
        switch self {
        case .secretScanner: return "key.fill"
        case .exposureCheck: return "globe"
        case .authDefenseLab: return "lock.shield"
        }
    }
}

/// Where the assessment runs. The server option is shown only as unavailable, with the reason; nothing is faked.
struct ExecutionLocationCard: View {
    var body: some View {
        SentinelCard {
            SectionLabel(text: "Execution location")
            AdaptiveStack {
                Image(systemName: "iphone").foregroundColor(Theme.cyan)
                Text("This device").font(.headline).foregroundColor(Theme.textPrimary)
                Spacer(minLength: 0)
                StatusPill(text: "Selected", tone: .ready)
            }
            Explanation("Runs inside Sentinel using public iOS APIs. No privileged or jailbreak features are used by Security Lab.")
            AdaptiveStack {
                Image(systemName: "server.rack").foregroundColor(Theme.textSecondary)
                Text("Paired HCG Server").font(.headline).foregroundColor(Theme.textSecondary)
                Spacer(minLength: 0)
                StatusPill(text: "Unavailable", tone: .off)
            }
            Explanation("HCG Server does not yet offer an assessment interface and cannot pair with an iPhone, so no server can be selected. The planned contract is in docs/SECURITY_LAB_SERVER.md.")
        }
    }
}

/// Start / Stop with progress based on the work actually done.
struct AssessmentRunControl: View {
    @EnvironmentObject private var lab: SecurityLabModel
    let module: SecurityModule
    let startTitle: String
    let canStart: Bool
    let blockedReason: String?
    let start: () -> Void

    var body: some View {
        SentinelCard(highlight: lab.running == module ? Theme.cyan : nil) {
            if lab.running == module {
                Text(lab.progress?.current ?? "Running")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fraction = lab.progress?.fraction {
                    ProgressView(value: fraction)
                        .accentColor(Theme.cyan)
                        .accessibilityLabel("Progress \(Int(fraction * 100)) percent")
                    if let progress = lab.progress {
                        Text("\(progress.completed) of \(progress.total) units of work")
                            .font(Theme.mono(.caption))
                            .foregroundColor(Theme.textSecondary)
                    }
                } else {
                    Text("Preparing…").font(.footnote).foregroundColor(Theme.textSecondary)
                }
                Button(action: { lab.stop() }) {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
                Explanation("Stopping keeps what was found so far in a report marked incomplete.")
            } else {
                Button(action: start) {
                    Label(startTitle, systemImage: "play.fill")
                }
                .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                .disabled(!canStart || lab.isRunning)
                if lab.isRunning, let other = lab.running {
                    Explanation("\(other.title) is running. One assessment runs at a time.")
                } else if let reason = blockedReason {
                    NoticeBanner(icon: "info.circle", text: reason, tone: .info)
                }
            }
        }
    }
}

struct LimitsCard: View {
    let lines: [String]

    var body: some View {
        SentinelCard {
            SectionLabel(text: "Limits")
            ForEach(lines, id: \.self) { line in
                Label(line, systemImage: "gauge")
                    .font(.footnote)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct CheckRow: View {
    let check: CheckResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AdaptiveStack {
                StatusPill(text: check.outcome.label, tone: check.outcome.tone)
                Text(check.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let target = check.target {
                Text(target).font(Theme.mono(.caption)).foregroundColor(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(check.detail)
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Evidence first; severity and confidence are separate labels.
struct SecurityFindingCard: View {
    let finding: SecurityFinding
    var onSuppress: ((String) -> Void)?

    var body: some View {
        SentinelCard(highlight: finding.severity >= .high ? Theme.warning : nil) {
            Text(finding.title)
                .font(.headline)
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            AdaptiveStack {
                StatusPill(text: "Severity: \(finding.severity.label)", tone: finding.severity.tone)
                StatusPill(text: "Confidence: \(finding.confidence.label)", tone: .info)
                StatusPill(text: finding.basis.label, tone: finding.basis == .verified ? .accent : .off)
                Spacer(minLength: 0)
            }
            if let location = finding.location {
                Text(location).font(Theme.mono(.caption)).foregroundColor(Theme.cyan).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Evidence").font(.caption).foregroundColor(Theme.textSecondary)
                ForEach(Array(finding.evidence.enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(Theme.mono(.footnote))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panelInset))
            Explanation(finding.explanation)
            NoticeBanner(icon: "wrench.and.screwdriver", text: finding.remediation, tone: finding.severity >= .high ? .warning : .ready)
            if let fingerprint = finding.fingerprint, let onSuppress = onSuppress {
                Button(action: { onSuppress(fingerprint) }) {
                    Label("Mark as false positive", systemImage: "eye.slash")
                }
                .buttonStyle(SentinelButtonStyle(kind: .secondary))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Picks folders and archives in place (no copy), so large folders are not duplicated. Access lasts only for a scan.
struct SourcePicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, .zip, .gzip, .data], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}
