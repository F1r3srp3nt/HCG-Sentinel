import SentinelCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Screen {
            Explanation("Every form of active collection is off until you turn it on. Sentinel never installs certificates, changes system networking or starts persistent background services.")
            StopAllCard()
            DisplaySettingsCard()
            BluetoothSettingsCard()
            RetentionSettingsCard()
            EndpointSettingsCard()
            NodeSettingsCard()
            HelperSettingsCard()
            DiagnosticsSettingsCard()
        }
        .navigationBarTitle("Settings", displayMode: .inline)
    }
}

// MARK: - Stop all

private struct StopAllCard: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        SentinelCard(highlight: app.activeOperations.isEmpty ? nil : Theme.danger) {
            SectionLabel(text: "Operational control", tone: .danger)
            Text(app.activeOperations.isEmpty ? "Nothing is running." : "Running: \(app.activeOperations.joined(separator: ", "))")
                .font(.subheadline)
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { app.stopAllOperations() }) {
                Label("Stop All Operations", systemImage: "stop.circle.fill")
            }
            .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
            Explanation("Stops the Bluetooth scan, cancels the in-flight test request, closes the radio node and helper sessions, and abandons a capture import. It does not delete saved captures, change any setting, or affect Bluetooth, Wi-Fi or other apps.")
        }
    }
}

// MARK: - Display

private struct DisplaySettingsCard: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SentinelCard {
            SectionLabel(text: "Display")
            SettingToggle(title: "Animation",
                          detail: "Turns the status pulses and the moving light line on or off. Nothing else changes."
                            + (reduceMotion ? " iOS Reduce Motion is on, so animation stays off regardless of this switch." : ""),
                          isOn: $app.settings.animationsEnabled)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            SettingToggle(title: "Preview mode",
                          detail: "Fills the tools with fabricated sample data under a clear banner, for looking around without hardware. Turning it on stops running operations and pauses live scanning, sending and connecting until it is turned off. Sample data is never logged or saved.",
                          isOn: $app.settings.previewMode)
        }
    }
}

// MARK: - Bluetooth

private struct BluetoothSettingsCard: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        SentinelCard {
            SectionLabel(text: "Bluetooth scanning")
            SettingToggle(title: "Allow Bluetooth scanning",
                          detail: "Lets you start a scan in Bluetooth Explorer. It does not start one. The first scan makes iOS ask for Bluetooth permission. Turning this off stops a running scan.",
                          isOn: $app.settings.bluetoothScanningEnabled)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            SettingToggle(title: "Continuous signal updates",
                          detail: "Off: each device is reported about once per scan. On: every advertisement is reported so RSSI and last-seen keep updating, which uses more battery.",
                          isOn: $app.settings.bluetoothContinuousUpdates)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                Text("Stop scanning after").font(.body).foregroundColor(Theme.textPrimary)
                Picker("Stop scanning after", selection: $app.settings.bluetoothAutoStopSeconds) {
                    Text("30 s").tag(30)
                    Text("1 min").tag(60)
                    Text("2 min").tag(120)
                    Text("5 min").tag(300)
                    Text("Never").tag(0)
                }
                .pickerStyle(SegmentedPickerStyle())
                Explanation("A scan ends by itself after this long. “Never” means it runs until you stop it or leave the app.")
            }
        }
    }
}

// MARK: - Retention

private struct RetentionSettingsCard: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var network: NetworkModel
    @State private var confirmDelete = false

    var body: some View {
        SentinelCard {
            SectionLabel(text: "Capture retention")
            VStack(alignment: .leading, spacing: 6) {
                Text("Keep imported captures").font(.body).foregroundColor(Theme.textPrimary)
                Picker("Keep imported captures", selection: $app.settings.captureRetention) {
                    ForEach(RetentionPolicy.allCases, id: \.self) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(minHeight: 44)
                Text("Current: \(app.settings.captureRetention.title)")
                    .font(Theme.mono(.caption))
                    .foregroundColor(Theme.textSecondary)
                Explanation(retentionDetail)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            InfoRow(label: "Saved now", value: network.saved.isEmpty ? "None" : "\(network.saved.count) file(s), \(Formatters.bytes(network.savedByteCount))")
            Button(action: { confirmDelete = true }) {
                Label("Delete all saved captures", systemImage: "trash")
            }
            .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
            .disabled(network.saved.isEmpty)
            .alert(isPresented: $confirmDelete) {
                Alert(title: Text("Delete all saved captures?"),
                      message: Text("\(network.saved.count) capture file(s) will be permanently removed from Sentinel. Your original files elsewhere are not affected."),
                      primaryButton: .destructive(Text("Delete all")) { network.deleteAll() },
                      secondaryButton: .cancel())
            }
            Explanation("Captures are stored only in Sentinel’s sandbox, are excluded from device backups, and are never uploaded. Individual captures can be deleted in Network Inspector.")
        }
    }

    private var retentionDetail: String {
        switch app.settings.captureRetention {
        case .sessionOnly:
            return "New imports are inspected in memory and not saved. Captures already saved stay until you delete them."
        case .untilDeleted:
            return "Imports are saved until you delete them. Nothing is removed automatically."
        case .oneDay, .sevenDays, .thirtyDays:
            return "Imports are saved, and captures older than this are deleted the next time Sentinel starts."
        }
    }
}

// MARK: - Test endpoint

private struct EndpointSettingsCard: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var requests: RequestModel
    @State private var draft = ""
    @State private var problem: String?

    var body: some View {
        SentinelCard {
            SectionLabel(text: "Request testing")
            Text("HCG test endpoint").font(.body).foregroundColor(Theme.textPrimary)
            TextField("https://test.example or http://192.168.1.20:8080", text: $draft)
                .technicalInput()
                .keyboardType(.URL)
                .sentinelField()
            if let problem = problem {
                NoticeBanner(icon: "exclamationmark.triangle.fill", text: problem, tone: .warning)
            }
            HStack(spacing: 10) {
                Button("Use this endpoint") { save() }
                    .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                Button("Clear") {
                    draft = ""
                    problem = nil
                    app.settings.testEndpoint = ""
                }
                .buttonStyle(SentinelButtonStyle(kind: .secondary))
            }
            InfoRow(label: "Selected", value: requests.endpoint?.displayString ?? "None", mono: true)
            Explanation("The only place the Request Composer may send to. Enter scheme, host and optional port for a service you are authorised to test. Changing it cancels a request in progress. Selecting an endpoint sends nothing.")
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Stepper(value: $app.settings.requestTimeoutSeconds, in: 5...120, step: 5) {
                Text("Timeout: \(app.settings.requestTimeoutSeconds) s").font(.body).foregroundColor(Theme.textPrimary)
            }
            Explanation("How long a test request waits for the endpoint before it is abandoned.")
        }
        .onAppear { draft = app.settings.testEndpoint }
    }

    private func save() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try TestEndpoint(string: text)
            problem = nil
            app.settings.testEndpoint = text
        } catch {
            problem = (error as? RequestValidationError)?.userMessage ?? "That endpoint is not valid."
        }
    }
}

// MARK: - External node

private struct NodeSettingsCard: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var radio: RadioModel
    @State private var address = ""
    @State private var token = ""
    @State private var problem: String?

    var body: some View {
        SentinelCard {
            SectionLabel(text: "External analysis node")
            SettingToggle(title: "Allow node connection",
                          detail: "Lets you connect from Radio Lab to a node you operate. It does not connect by itself. Turning this off closes an open node session.",
                          isOn: $app.settings.radioNodeEnabled)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text("Node address").font(.body).foregroundColor(Theme.textPrimary)
            TextField("ws://192.168.1.50:8765/ or wss://node.example/", text: $address)
                .technicalInput()
                .keyboardType(.URL)
                .sentinelField()
            if let problem = problem {
                NoticeBanner(icon: "exclamationmark.triangle.fill", text: problem, tone: .warning)
            }
            Button("Save address") { saveAddress() }
                .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
            Explanation("Use wss:// when the node is not on your own local network. Plain ws:// is only permitted by iOS for local addresses.")
            tokenControls
        }
        .onAppear { address = app.settings.radioNodeAddress }
    }

    private var tokenControls: some View {
        Group {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text("Access token (optional)").font(.body).foregroundColor(Theme.textPrimary)
            SecureField(radio.hasToken ? "Token stored — enter a new one to replace" : "Token configured on the node", text: $token)
                .technicalInput()
                .sentinelField()
            HStack(spacing: 10) {
                Button("Save token") {
                    radio.setToken(token)
                    token = ""
                }
                .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
                .disabled(token.isEmpty)
                Button("Remove") { radio.setToken("") }
                    .buttonStyle(SentinelButtonStyle(kind: .destructive))
                    .disabled(!radio.hasToken)
            }
            Explanation("Stored in this device’s Keychain, never in settings or logs, and sent only to the node in the protocol handshake.")
        }
    }

    private func saveAddress() {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || RadioNodeSession.validatedURL(text) != nil {
            problem = nil
            app.settings.radioNodeAddress = text
        } else {
            problem = RadioNodeError.invalidURL.userMessage
        }
    }
}

// MARK: - Helper

private struct HelperSettingsCard: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var helper: HelperModel
    @State private var key = ""
    @State private var keyProblem: String?

    var body: some View {
        SentinelCard {
            HStack {
                SectionLabel(text: "Privileged helper (optional)", tone: .accent)
                StatusPill(text: app.capabilityState(.helperLink)?.readiness == .verified ? "Verified" : "Deployment unverified",
                           tone: app.capabilityState(.helperLink)?.readiness == .verified ? .verified : .accent)
            }
            NoticeBanner(icon: "lock.shield",
                         text: "Sentinel includes no helper and no privileged backend. This only lets the app look for a helper you installed separately. A package repository can deliver a helper’s files, but it does not provide a jailbreak or its permissions, and nothing here counts as verified until an authenticated helper answers.",
                         tone: .accent)
            SettingToggle(title: "Allow helper probing",
                          detail: "Lets you run a one-off probe below. Sentinel never probes by itself and keeps no helper connection open.",
                          isOn: $app.settings.helperEnabled)
            if app.settings.helperEnabled {
                pairingControls
                probeControls
            }
        }
    }

    private var pairingControls: some View {
        Group {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Stepper(value: $app.settings.helperPort, in: 1024...65_535) {
                    Text("Loopback port: \(String(app.settings.helperPort))").font(.body).foregroundColor(Theme.textPrimary)
                }
                Explanation("The probe connects only to 127.0.0.1 on this device, at this port.")
                Text("Pairing key").font(.body).foregroundColor(Theme.textPrimary)
                SecureField(helper.hasPairingKey ? "Key stored — enter a new one to replace" : "64 or more hexadecimal digits", text: $key)
                    .technicalInput()
                    .sentinelField()
                if let keyProblem = keyProblem {
                    NoticeBanner(icon: "exclamationmark.triangle.fill", text: keyProblem, tone: .warning)
                }
                HStack(spacing: 10) {
                    Button("Save key") {
                        if helper.setPairingKey(key) {
                            key = ""
                            keyProblem = nil
                        } else {
                            keyProblem = "Enter the key as at least 64 hexadecimal digits (32 bytes)."
                        }
                    }
                    .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
                    .disabled(key.isEmpty)
                    Button("Remove") { helper.removePairingKey() }
                        .buttonStyle(SentinelButtonStyle(kind: .destructive))
                        .disabled(!helper.hasPairingKey)
                }
                Explanation("Both sides must prove they hold this key before any request is accepted. It is stored in the Keychain.")
        }
    }

    private var probeControls: some View {
        Group {
                Button(action: { helper.probe() }) {
                    Label(helper.state.isActive ? "Probing…" : "Probe for helper", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                .disabled(helper.state.isActive || app.settings.previewMode)
                if let message = helper.message {
                    NoticeBanner(icon: "info.circle", text: message, tone: helper.report == nil ? .warning : .verified)
                }
                if let report = helper.report {
                    InfoRow(label: "Helper version", value: report.helperVersion, mono: true)
                    InfoRow(label: "Packaging (self-reported)", value: report.packaging)
                    InfoRow(label: "Supported operations", value: report.supportedOperations.joined(separator: ", "))
                }
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSettingsCard: View {
    @EnvironmentObject private var app: AppModel
    @State private var showShare = false
    @State private var confirmDelete = false

    var body: some View {
        SentinelCard {
            SectionLabel(text: "Diagnostic logging")
            SettingToggle(title: "Write activity to a log file",
                          detail: "Off: activity is kept in memory only and disappears when Sentinel closes. On: the same redacted entries are also appended to a file in the app sandbox (capped at about 500 KB) so you can export them. Credentials, tokens, cookies and passwords are replaced with [REDACTED] before anything is recorded.",
                          isOn: $app.settings.diagnosticLoggingEnabled)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            InfoRow(label: "Log file", value: app.diagnosticLogBytes == 0 ? "Empty" : Formatters.bytes(app.diagnosticLogBytes))
            HStack(spacing: 10) {
                Button(action: { showShare = true }) { Label("Export", systemImage: "square.and.arrow.up") }
                    .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
                    .disabled(app.diagnosticLogBytes == 0)
                    .sheet(isPresented: $showShare) { ShareSheet(items: [app.diagnosticFile.url]) }
                Button(action: { confirmDelete = true }) { Label("Delete log", systemImage: "trash") }
                    .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
                    .disabled(app.diagnosticLogBytes == 0)
                    .alert(isPresented: $confirmDelete) {
                        Alert(title: Text("Delete the diagnostic log?"),
                              message: Text("The log file will be removed. Logging stays as it is set above."),
                              primaryButton: .destructive(Text("Delete")) { app.deleteDiagnosticLog() },
                              secondaryButton: .cancel())
                    }
            }
            Button("Clear in-app activity list") { app.clearActivity() }
                .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
                .disabled(app.activity.isEmpty)
            Explanation("Exporting opens the iOS share sheet; the log goes only where you send it.")
        }
    }
}
