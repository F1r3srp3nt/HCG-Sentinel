import SentinelCore
import SwiftUI

struct SecurityLabView: View {
    @EnvironmentObject private var lab: SecurityLabModel
    @EnvironmentObject private var router: Router
    @State private var confirmDeleteAll = false

    var body: some View {
        Screen {
            if lab.previewMode {
                PreviewBanner(detail: "Security Lab is paused in Preview mode. It never shows sample findings: every report comes from a real run.")
            }
            SentinelCard {
                SectionLabel(text: "Practical checks for systems you own")
                Explanation("Each module works only on what you select or enter, within visible limits, and produces a report with its scope, evidence, limitations and next steps. Results are kept on this device.")
            }
            ExecutionLocationCard()
            SectionLabel(text: "Modules")
            ForEach(SecurityModule.allCases) { module in
                NavigationLink(destination: destination(module)) {
                    moduleRow(module)
                }
                .buttonStyle(PlainButtonStyle())
            }
            SectionLabel(text: "Reports")
            if lab.reports.isEmpty {
                EmptyState(icon: "doc.text.magnifyingglass", title: "No reports yet",
                           message: "Reports appear here after you run a module. They stay on this device until you delete them.")
            } else {
                ForEach(lab.reports) { record in
                    NavigationLink(destination: SecurityReportView(recordID: record.id)) {
                        ReportRow(record: record)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Button(action: { confirmDeleteAll = true }) {
                    Label("Delete all reports", systemImage: "trash")
                }
                .buttonStyle(SentinelButtonStyle(kind: .destructive))
            }
        }
        .navigationBarTitle("Security Lab", displayMode: .inline)
        .alert(isPresented: $confirmDeleteAll) {
            Alert(title: Text("Delete all reports?"), message: Text("This removes every Security Lab report from this device."),
                  primaryButton: .destructive(Text("Delete")) { lab.deleteAllReports() }, secondaryButton: .cancel())
        }
        .sheet(item: $router.pendingReport) { item in
            NavContainer {
                SecurityReportView(recordID: item.id)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") { router.pendingReport = nil }
                        }
                    }
            }
            .environmentObject(lab)
            .preferredColorScheme(.dark)
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-SentinelRunAuthLab"), !lab.isRunning, !lab.labIsRunning {
                lab.startLab()
                lab.wrongPasswordsText = "Winter2026!\nletmein-01\nhunter22"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { lab.startAuthAssessment() }
            }
            #endif
        }
    }

    @ViewBuilder private func destination(_ module: SecurityModule) -> some View {
        switch module {
        case .secretScanner: SecretScannerView()
        case .exposureCheck: ExposureCheckView()
        case .authDefenseLab: AuthLabView()
        }
    }

    private func moduleRow(_ module: SecurityModule) -> some View {
        SentinelCard(highlight: lab.running == module ? Theme.cyan : nil) {
            AdaptiveStack {
                Image(systemName: module.icon).foregroundColor(Theme.cyan).frame(width: 24)
                Text(module.title).font(.headline).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if lab.running == module {
                    StatusPill(text: "Running", tone: .accent)
                } else {
                    StatusPill(text: "v\(module.version)", tone: .off)
                }
                Image(systemName: "chevron.right").foregroundColor(Theme.textSecondary)
            }
            Explanation(module.summary)
        }
        .contentShape(Rectangle())
    }
}

struct ReportRow: View {
    let record: SecurityAssessmentRecord

    var body: some View {
        SentinelCard {
            AdaptiveStack {
                Image(systemName: record.module.icon).foregroundColor(Theme.cyan)
                Text(record.module.title).font(.subheadline.weight(.semibold)).foregroundColor(Theme.textPrimary)
                Spacer(minLength: 0)
                StatusPill(text: record.status.label, tone: record.status.tone)
            }
            Text(record.headline).font(.footnote).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
            Text(Formatters.preciseTime.string(from: record.startedAt)).font(Theme.mono(.caption)).foregroundColor(Theme.textSecondary)
        }
        .contentShape(Rectangle())
    }
}

/// The readable report: scope and limits first, then checks, evidence-first findings, gaps and next steps.
struct SecurityReportView: View {
    @EnvironmentObject private var lab: SecurityLabModel
    @EnvironmentObject private var devices: ConnectedDevicesModel
    let recordID: UUID
    @State private var shareURL: URL?
    @State private var shareToDevice = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let record = lab.report(recordID) {
                content(record)
            } else {
                Screen {
                    EmptyState(icon: "questionmark.folder", title: "Report not found",
                               message: "This report is not stored on this device. It may have been deleted. Opening a link never runs an assessment.")
                }
            }
        }
        .navigationBarTitle("Report", displayMode: .inline)
    }

    private func content(_ record: SecurityAssessmentRecord) -> some View {
        Screen {
            SentinelCard(highlight: record.highestSeverity.map { $0 >= .high ? Theme.warning : Theme.cyan }) {
                AdaptiveStack {
                    Image(systemName: record.module.icon).foregroundColor(Theme.cyan)
                    Text("\(record.module.title) v\(record.moduleVersion)").font(.headline).foregroundColor(Theme.textPrimary)
                    Spacer(minLength: 0)
                    StatusPill(text: record.status.label, tone: record.status.tone)
                }
                Text(record.headline).font(.headline).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                InfoRow(label: "Executed on", value: record.location.label)
                InfoRow(label: "Started", value: Formatters.preciseTime.string(from: record.startedAt), mono: true)
                if let duration = record.duration {
                    InfoRow(label: "Duration", value: String(format: "%.1f s", duration), mono: true)
                }
                InfoRow(label: "Work completed", value: "\(record.workCompleted) of \(record.workTotal)", mono: true)
                ForEach(CheckOutcome.allCases, id: \.self) { outcome in
                    InfoRow(label: outcome.label, value: "\(record.count(outcome))")
                }
            }
            SentinelCard {
                SectionLabel(text: "Scope")
                ForEach(record.scope) { item in
                    InfoRow(label: item.kind.label, value: item.value + (item.localNetwork ? " (local)" : ""), mono: true)
                }
                SectionLabel(text: "Permissions for this run")
                ForEach(record.permissions, id: \.self) { Explanation($0) }
            }
            LimitsCard(lines: record.limits.lines)
            SentinelCard {
                SectionLabel(text: "Checks")
                ForEach(record.checks) { CheckRow(check: $0) }
                if record.checks.isEmpty { Explanation("No check reached a result.") }
            }
            SectionLabel(text: record.findings.isEmpty ? "Findings: none" : "Findings (\(record.findings.count))")
            if record.findings.isEmpty {
                Explanation("These checks found nothing to report. That is not proof that nothing is wrong; see the limitations below.")
            }
            ForEach(record.findings.sorted { $0.severity > $1.severity }) { finding in
                SecurityFindingCard(finding: finding, onSuppress: record.module == .secretScanner ? { lab.suppress($0) } : nil)
            }
            if record.suppressedCount > 0 {
                Explanation("\(record.suppressedCount) finding(s) were hidden because they were marked as false positives.")
            }
            SentinelCard {
                SectionLabel(text: "Not tested", tone: record.notTested.isEmpty ? .ready : .warning)
                if record.notTested.isEmpty { Explanation("Nothing in scope was skipped.") }
                ForEach(record.notTested, id: \.self) { Explanation($0) }
                SectionLabel(text: "Execution errors", tone: record.errors.isEmpty ? .ready : .warning)
                if record.errors.isEmpty { Explanation("None.") }
                ForEach(record.errors, id: \.self) { Explanation($0) }
            }
            SentinelCard {
                SectionLabel(text: "Limitations")
                ForEach(record.limitations, id: \.self) { Explanation($0) }
                SectionLabel(text: "Recommended next steps")
                ForEach(SecurityReportRenderer.nextSteps(record), id: \.self) { Explanation("• " + $0) }
            }
            AdaptiveStack {
                Button(action: { shareURL = lab.exportFile(for: record) }) {
                    Label("Export redacted report", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SentinelButtonStyle(kind: .primary))
                Button(action: { confirmDelete = true }) {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(SentinelButtonStyle(kind: .destructive))
            }
            Button(action: { shareToDevice = true }) {
                Label("Share with paired device", systemImage: "laptopcomputer.and.iphone")
            }
            .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
            .disabled(!SentinelReportSharing.canShare(record))
            .sheet(isPresented: $shareToDevice) {
                ShareWithDeviceSheet(title: "\(record.module.title) — \(record.headline)") { id, name, version in
                    SentinelReportSharing.report(from: record, installationId: id, appVersion: version, deviceName: name)
                }
                .environmentObject(devices)
            }
            Explanation("Exports are Markdown with secret values redacted. Sharing with a paired device sends the same redacted content through your HCG Server to the device you pick. Sharing is always your choice; nothing is sent automatically.")
        }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init(url:)) }, set: { shareURL = $0?.url })) { item in
            ShareSheet(items: [item.url])
        }
        .alert(isPresented: $confirmDelete) {
            Alert(title: Text("Delete this report?"), primaryButton: .destructive(Text("Delete")) { lab.delete(record.id) },
                  secondaryButton: .cancel())
        }
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
