import SentinelCore
import SwiftUI

private struct LatestReportLink: View {
    @EnvironmentObject private var lab: SecurityLabModel
    let module: SecurityModule

    var body: some View {
        if let id = lab.lastResult[module] ?? lab.reports.first(where: { $0.module == module })?.id, let record = lab.report(id) {
            SectionLabel(text: "Latest report")
            NavigationLink(destination: SecurityReportView(recordID: id)) { ReportRow(record: record) }
                .buttonStyle(PlainButtonStyle())
        }
    }
}

// MARK: Secret Scanner

struct SecretScannerView: View {
    @EnvironmentObject private var lab: SecurityLabModel
    @State private var showPicker = false

    var body: some View {
        Screen {
            SentinelCard {
                SectionLabel(text: "What this does")
                Explanation("Reads the folders and archives you select, on this device, and looks for private keys, known API credential formats, passwords in configuration or URLs, and random-looking values next to credential names.")
                Explanation("Nothing is uploaded and no credential is ever tried against a service. A match shows a likely exposure; it cannot prove the credential still works.")
            }
            SentinelCard {
                SectionLabel(text: "Scope")
                if lab.sources.isEmpty {
                    Explanation("Nothing selected yet. Archives (.zip, .tar, .tar.gz) are read in memory and never extracted.")
                }
                ForEach(lab.sources, id: \.self) { url in
                    AdaptiveStack {
                        Image(systemName: url.hasDirectoryPath ? "folder" : "doc.zipper").foregroundColor(Theme.cyan)
                        Text(url.lastPathComponent).font(Theme.mono(.subheadline)).foregroundColor(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(action: { lab.removeSource(url) }) {
                            Image(systemName: "xmark.circle.fill").foregroundColor(Theme.textSecondary)
                        }
                        .accessibilityLabel("Remove \(url.lastPathComponent)")
                        .disabled(lab.isRunning)
                    }
                }
                Button(action: { showPicker = true }) {
                    Label("Choose folders or archives", systemImage: "folder.badge.plus")
                }
                .buttonStyle(SentinelButtonStyle(kind: .secondary))
                .disabled(lab.isRunning)
                SectionLabel(text: "Exclusions")
                TextEditor(text: $lab.exclusionsText)
                    .frame(minHeight: 70)
                    .sentinelField()
                    .technicalInput()
                    .accessibilityLabel("Exclusion patterns, one per line")
                Explanation("One pattern per line, for example *.min.js, docs/ or tests/fixtures/**. Version-control, dependency and build folders are always skipped. Symbolic links are never followed.")
                if !lab.suppressed.isEmpty {
                    AdaptiveStack {
                        Text("\(lab.suppressed.count) finding(s) marked as false positives")
                            .font(.footnote).foregroundColor(Theme.textSecondary)
                        Spacer(minLength: 0)
                        Button("Clear") { lab.clearSuppressions() }
                    }
                    if !lab.fingerprintKeyPersistent {
                        Explanation("The keychain was unavailable, so false-positive marks last only until Sentinel quits.")
                    }
                }
            }
            LimitsCard(lines: SecretScanConfiguration(fingerprintKey: []).limits.lines)
            AssessmentRunControl(module: .secretScanner, startTitle: "Start scan", canStart: !lab.sources.isEmpty && !lab.previewMode,
                                 blockedReason: lab.previewMode ? "Paused in Preview mode." : (lab.sources.isEmpty ? "Choose at least one folder or archive." : nil)) {
                lab.startSecretScan()
            }
            LatestReportLink(module: .secretScanner)
        }
        .navigationBarTitle("Secret Scanner", displayMode: .inline)
        .sheet(isPresented: $showPicker) {
            SourcePicker { urls in lab.addSources(urls) }
        }
    }
}

// MARK: Exposure Check

struct ExposureCheckView: View {
    @EnvironmentObject private var lab: SecurityLabModel
    @EnvironmentObject private var app: AppModel

    private var scopeProblem: String? {
        do {
            let scope = try lab.exposureScope()
            return scope.targets.isEmpty ? "Enter at least one http:// or https:// URL." : nil
        } catch {
            return "\(error)"
        }
    }

    /// Binding by identity, so removing a row can never leave a stale index behind (works on iOS 14).
    private func binding(_ id: UUID) -> Binding<ExposureEntry> {
        Binding(get: { lab.exposureEntries.first { $0.id == id } ?? ExposureEntry(text: "", localNetwork: false) },
                set: { value in
                    if let index = lab.exposureEntries.firstIndex(where: { $0.id == id }) { lab.exposureEntries[index] = value }
                })
    }

    private var blockedReason: String? {
        if lab.previewMode { return "Paused in Preview mode." }
        if !lab.remoteConnectionsEnabled { return "Turn on Remote connections in Settings. Exposure Check contacts the services you enter." }
        if let problem = scopeProblem { return problem }
        if !lab.authorizationConfirmed { return "Confirm that you own or are authorised to test every target." }
        return nil
    }

    var body: some View {
        Screen {
            SentinelCard {
                SectionLabel(text: "What this does")
                Explanation("Sends a few plain GET requests, with no credentials, to each URL you enter and reports reachability and status, TLS certificate validity and host name, HTTP-to-HTTPS behaviour, security headers and version banners.")
                Explanation("Banners and missing headers are observations, not confirmed vulnerabilities. Normal certificate validation stays on; failures are reported, never bypassed.")
            }
            SentinelCard {
                SectionLabel(text: "Scope — up to \(TargetScope.maxTargets) URLs")
                ForEach(lab.exposureEntries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("https://service.example.com", text: binding(entry.id).text)
                            .keyboardType(.URL)
                            .technicalInput()
                            .sentinelField()
                            .accessibilityLabel("Target URL")
                        Toggle(isOn: binding(entry.id).localNetwork) {
                            Text("Local-network target").font(.footnote).foregroundColor(Theme.textSecondary)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Theme.cyan))
                    }
                }
                AdaptiveStack {
                    Button(action: { lab.exposureEntries.append(ExposureEntry(text: "", localNetwork: false)) }) {
                        Label("Add URL", systemImage: "plus")
                    }
                    .disabled(lab.exposureEntries.count >= TargetScope.maxTargets || lab.isRunning)
                    if lab.exposureEntries.count > 1 {
                        Button(action: { lab.exposureEntries.removeLast() }) {
                            Label("Remove last", systemImage: "minus")
                        }
                        .disabled(lab.isRunning)
                    }
                }
                .buttonStyle(SentinelButtonStyle(kind: .secondary))
                Explanation("Only these hosts are contacted. Redirects to other hosts are reported, never followed, and discovered hosts are never added. Names that resolve to private or loopback addresses are blocked unless you mark the target as local; cloud metadata addresses are always blocked.")
                Toggle(isOn: $lab.authorizationConfirmed) {
                    Text("I own these services or am authorised to test them")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(SwitchToggleStyle(tint: Theme.cyan))
            }
            LimitsCard(lines: ExposureCheckConfiguration().limits(targets: max(1, lab.exposureEntries.count)).lines)
            AssessmentRunControl(module: .exposureCheck, startTitle: "Start check", canStart: blockedReason == nil,
                                 blockedReason: blockedReason) {
                lab.startExposureCheck()
            }
            if let message = lab.message {
                NoticeBanner(icon: "exclamationmark.triangle", text: message, tone: .warning)
            }
            LatestReportLink(module: .exposureCheck)
        }
        .navigationBarTitle("Exposure Check", displayMode: .inline)
    }
}

// MARK: Authentication Defense Lab

struct AuthLabView: View {
    @EnvironmentObject private var lab: SecurityLabModel

    var body: some View {
        Screen {
            SentinelCard {
                SectionLabel(text: "What this does")
                Explanation("Starts a small login service inside Sentinel, reachable only from this device at 127.0.0.1, with synthetic accounts. The assessment sends a few incorrect passwords to one designated test account and compares what the service does with what you expect.")
                Explanation("It never runs against a real service. No credential stuffing, parallel or distributed guessing, proxy rotation, CAPTCHA or MFA bypass, and no retries after throttling.")
            }
            SentinelCard {
                SectionLabel(text: "Lab service")
                AdaptiveStack {
                    Text(lab.labURL?.absoluteString ?? "Stopped").font(Theme.mono(.subheadline)).foregroundColor(Theme.textPrimary)
                    Spacer(minLength: 0)
                    StatusPill(text: lab.labURL == nil ? "Stopped" : "Running", tone: lab.labURL == nil ? .off : .ready)
                }
                if lab.labURL == nil {
                    Button(action: { lab.startLab() }) { Label("Start lab service", systemImage: "play.circle") }
                        .buttonStyle(SentinelButtonStyle(kind: .secondary))
                        .disabled(lab.previewMode)
                } else {
                    Button(action: { lab.stopLab() }) { Label("Stop lab service", systemImage: "stop.circle") }
                        .buttonStyle(SentinelButtonStyle(kind: .secondary))
                }
                SettingToggle(title: "Rate limiting", detail: "HTTP 429 after \(lab.labConfiguration.rateLimitAttempts) attempts per account per minute.",
                              isOn: $lab.labConfiguration.rateLimitEnabled)
                Stepper("Attempts before throttling: \(lab.labConfiguration.rateLimitAttempts)", value: $lab.labConfiguration.rateLimitAttempts, in: 1...20)
                    .font(.footnote).foregroundColor(Theme.textSecondary)
                SettingToggle(title: "Temporary lockout", detail: "HTTP 423 for five minutes after \(lab.labConfiguration.lockoutThreshold) consecutive failures.",
                              isOn: $lab.labConfiguration.lockoutEnabled)
                Stepper("Failures before lockout: \(lab.labConfiguration.lockoutThreshold)", value: $lab.labConfiguration.lockoutThreshold, in: 1...20)
                    .font(.footnote).foregroundColor(Theme.textSecondary)
                SettingToggle(title: "Generic login errors", detail: "Off makes the service reveal whether an account exists (a deliberate weakness).",
                              isOn: Binding(get: { lab.labConfiguration.errorMode == .generic },
                                            set: { lab.labConfiguration.errorMode = $0 ? .generic : .revealing }))
                SettingToggle(title: "Authentication event logging", detail: "Records each attempt in the lab's event log, which the assessment reads back.",
                              isOn: $lab.labConfiguration.loggingEnabled)
                Explanation("Changing a setting resets the lab's counters, lockouts and log. Expectations below follow these settings; edit them to see how a mismatch is reported.")
            }
            SentinelCard {
                SectionLabel(text: "Scope")
                InfoRow(label: "Test account", value: "\(AuthLabService.designatedTestAccounts[0]) (synthetic)", mono: true)
                InfoRow(label: "Target", value: lab.labURL.map { $0.absoluteString + " (bundled lab)" } ?? "Start the lab service", mono: true)
                Text("Incorrect passwords, one per line (at most \(AuthDefensePlan.maxPasswords))").font(.footnote).foregroundColor(Theme.textSecondary)
                TextEditor(text: $lab.wrongPasswordsText)
                    .frame(minHeight: 80)
                    .sentinelField()
                    .technicalInput()
                    .accessibilityLabel("Incorrect passwords, one per line")
                Explanation("They are used in order and repeated if the list is shorter than the cap. Reports show only their length, never the passwords.")
                Stepper("Attempt cap: \(lab.attemptCap) requests", value: $lab.attemptCap, in: 2...AuthDefensePlan.maxAttemptCap)
                    .font(.subheadline).foregroundColor(Theme.textPrimary)
                Explanation("Includes one request for a non-existent synthetic account, used to compare error messages. Requests are 1.5 s apart.")
            }
            SentinelCard {
                SectionLabel(text: "Expected behaviour")
                Stepper("Lockout after: \(lab.expectations.lockoutAfter.map { String($0) } ?? "none")",
                        onIncrement: { lab.expectations.lockoutAfter = min((lab.expectations.lockoutAfter ?? 0) + 1, 20) },
                        onDecrement: { lab.expectations.lockoutAfter = (lab.expectations.lockoutAfter ?? 1) <= 1 ? nil : lab.expectations.lockoutAfter! - 1 })
                    .font(.footnote).foregroundColor(Theme.textSecondary)
                Stepper("Throttling after: \(lab.expectations.throttleAfter.map { String($0) } ?? "none")",
                        onIncrement: { lab.expectations.throttleAfter = min((lab.expectations.throttleAfter ?? 0) + 1, 20) },
                        onDecrement: { lab.expectations.throttleAfter = (lab.expectations.throttleAfter ?? 1) <= 1 ? nil : lab.expectations.throttleAfter! - 1 })
                    .font(.footnote).foregroundColor(Theme.textSecondary)
                Toggle("Generic errors expected", isOn: $lab.expectations.genericErrors).font(.footnote).foregroundColor(Theme.textSecondary)
                    .toggleStyle(SwitchToggleStyle(tint: Theme.cyan))
                Toggle("Event logging expected", isOn: $lab.expectations.eventsLogged).font(.footnote).foregroundColor(Theme.textSecondary)
                    .toggleStyle(SwitchToggleStyle(tint: Theme.cyan))
            }
            if let plan = lab.labPlan() {
                LimitsCard(lines: AssessmentLimits(maxAttempts: plan.attemptCap, minRequestInterval: plan.interval,
                                                   requestTimeout: plan.requestTimeout, overallTimeout: plan.overallTimeout).lines)
            }
            AssessmentRunControl(module: .authDefenseLab, startTitle: "Start assessment", canStart: lab.labPlanProblem == nil && !lab.previewMode,
                                 blockedReason: lab.previewMode ? "Paused in Preview mode." : lab.labPlanProblem) {
                lab.startAuthAssessment()
            }
            if let message = lab.message {
                NoticeBanner(icon: "exclamationmark.triangle", text: message, tone: .warning)
            }
            LatestReportLink(module: .authDefenseLab)
            SentinelCard {
                SectionLabel(text: "Lab event log (\(lab.labEvents.count))")
                if lab.labEvents.isEmpty { Explanation("No authentication events recorded.") }
                ForEach(Array(lab.labEvents.suffix(12).enumerated()), id: \.offset) { item in
                    Text("\(Formatters.preciseTime.string(from: item.element.time))  \(item.element.account)  \(item.element.outcome.rawValue)")
                        .font(Theme.mono(.caption)).foregroundColor(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .navigationBarTitle("Authentication Defense Lab", displayMode: .inline)
    }
}
