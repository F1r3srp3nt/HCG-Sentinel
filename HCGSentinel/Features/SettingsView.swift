import SentinelCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        Screen {
            Explanation("Every scan and every outside connection is off until you turn it on, and nothing starts by itself even then. Sentinel never installs certificates or profiles, changes system networking, or starts background services.")
            StopAllCard()
            MasterSwitchesCard()
            PreviewSettingsCard()
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

// MARK: - Master switches

private struct MasterSwitchesCard: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SentinelCard {
            SectionLabel(text: "Main switches")
            SettingToggle(title: "Scanning",
                          detail: "Enables: starting Bluetooth LE scans in Bluetooth Explorer and requesting nearby Wi-Fi scans from your node. Turning it off stops any Bluetooth scan at once and cancels a pending Wi-Fi scan request. It never starts a scan by itself.",
                          isOn: $app.settings.scanningEnabled)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            SettingToggle(title: "Remote connections",
                          detail: "Enables: connecting to your external analysis node, probing your privileged helper on this device, and sending test requests to your endpoints. Turning it off closes node and helper sessions and cancels a request in flight. Check My Network is separate and only runs when you press Start.",
                          isOn: $app.settings.remoteConnectionsEnabled)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            SettingToggle(title: "Animation",
                          detail: "Enables: the status pulses and the moving light line. Turning it off makes them static; nothing else changes."
                            + (reduceMotion ? " iOS Reduce Motion is on, so animation stays off regardless of this switch." : ""),
                          isOn: $app.settings.animationsEnabled)
        }
    }
}

// MARK: - Preview

private struct PreviewSettingsCard: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        SentinelCard {
            SectionLabel(text: "Display")
            SettingToggle(title: "Preview mode",
                          detail: "Fills some tools with fabricated sample data under a clear banner, for looking around without hardware. Turning it on stops running operations and pauses scanning, sending and connecting until it is turned off. Sample data is never logged or saved, and Check My Network never shows sample results.",
                          isOn: $app.settings.previewMode)
        }
    }
}

// MARK: - Bluetooth

private struct BluetoothSettingsCard: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        SentinelCard {
            SectionLabel(text: "Bluetooth scan options")
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

// MARK: - Test endpoints

private struct EndpointSettingsCard: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var requests: RequestModel
    @State private var draft = ""
    @State private var problem: String?

    var body: some View {
        SentinelCard {
            SectionLabel(text: "Request testing")
            Text("Allowed test endpoints").font(.body).foregroundColor(Theme.textPrimary)
            if app.settings.testEndpoints.isEmpty {
                Explanation("None yet. The Request Composer can only send to endpoints listed here.")
            }
            ForEach(Array(app.settings.testEndpoints.enumerated()), id: \.offset) { item in
                AdaptiveStack {
                    Text(item.offset == 0 ? "\(item.element)  (primary)" : item.element)
                        .font(Theme.mono(.subheadline))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(action: { remove(at: item.offset) }) {
                        Label("Remove", systemImage: "minus.circle").foregroundColor(Theme.danger)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .frame(minHeight: 44)
                    .accessibilityLabel("Remove \(item.element)")
                }
            }
            TextField("https://test.example or http://192.168.1.20:8080", text: $draft)
                .technicalInput()
                .keyboardType(.URL)
                .sentinelField()
            if let problem = problem {
                NoticeBanner(icon: "exclamationmark.triangle.fill", text: problem, tone: .warning)
            }
            Button("Add endpoint") { add() }
                .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || app.settings.testEndpoints.count >= TestEndpoint.maxEndpoints)
            Explanation("Enter scheme, host and optional port of services you are authorised to test (up to \(TestEndpoint.maxEndpoints)). Requests may only go to these. Adding one sends nothing; removing one cancels a request in progress.")
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Stepper(value: $app.settings.requestTimeoutSeconds, in: 5...120, step: 5) {
                Text("Timeout: \(app.settings.requestTimeoutSeconds) s").font(.body).foregroundColor(Theme.textPrimary)
            }
            Explanation("How long a test request waits for the endpoint before it is abandoned.")
        }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let endpoint = try TestEndpoint(string: text)
            problem = nil
            if !app.settings.testEndpoints.contains(where: { (try? TestEndpoint(string: $0)) == endpoint }) {
                app.settings.testEndpoints.append(endpoint.displayString)
            }
            draft = ""
        } catch {
            problem = (error as? RequestValidationError)?.userMessage ?? "That endpoint is not valid."
        }
    }

    private func remove(at index: Int) {
        guard app.settings.testEndpoints.indices.contains(index) else { return }
        app.settings.testEndpoints.remove(at: index)
    }
}

// MARK: - External node

private struct NodeSettingsCard: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var radio: RadioModel
    @State private var address = ""
    @State private var key = ""
    @State private var problem: String?

    var body: some View {
        SentinelCard {
            SectionLabel(text: "External analysis node")
            Explanation(app.settings.remoteConnectionsEnabled
                        ? "Remote connections are on. Radio Lab connects only when you tap Connect."
                        : "Remote connections are off, so Radio Lab stays disconnected. You can still prepare the address and key.")
            Text("Node address").font(.body).foregroundColor(Theme.textPrimary)
            TextField("ws://192.168.1.50:8765/ or wss://node.example/", text: $address)
                .technicalInput()
                .keyboardType(.URL)
                .sentinelField()
            Button("Save address") { saveAddress() }
                .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
            Explanation("Use wss:// when the node is not on your own local network. Plain ws:// is only permitted by iOS for local addresses.")
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text("Pairing key").font(.body).foregroundColor(Theme.textPrimary)
            SecureField(radio.hasPairingKey ? "Key stored — enter a new one to replace" : "64 or more hexadecimal digits from the node", text: $key)
                .technicalInput()
                .sentinelField()
            AdaptiveStack(spacing: 10) {
                Button("Save key") {
                    if radio.setPairingKey(key) {
                        key = ""
                        problem = nil
                    } else {
                        problem = "Enter the key as at least 64 hexadecimal digits (32 bytes)."
                    }
                }
                .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
                .disabled(key.isEmpty)
                Button("Remove") { radio.removePairingKey() }
                    .buttonStyle(SentinelButtonStyle(kind: .destructive))
                    .disabled(!radio.hasPairingKey)
            }
            if let problem = problem {
                NoticeBanner(icon: "exclamationmark.triangle.fill", text: problem, tone: .warning)
            }
            Explanation("The node and Sentinel each prove they hold this key before the node’s capabilities are accepted, and every later message is integrity-checked. The key is stored in this device’s Keychain and never sent.")
        }
        .onAppear { address = app.settings.radioNodeAddress }
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
            AdaptiveStack {
                SectionLabel(text: "Privileged helper (optional)", tone: .accent)
                StatusPill(text: helperVerified ? "Verified" : "Deployment unverified", tone: helperVerified ? .verified : .accent)
            }
            NoticeBanner(icon: "lock.shield",
                         text: "Sentinel includes no helper and no privileged backend. This only lets the app look for a helper you installed separately. Jailbreak markers, package managers and sideloading are not checked and would prove nothing; only an authenticated helper that answers a capability report counts.",
                         tone: .accent)
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
            AdaptiveStack(spacing: 10) {
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
            Button(action: { helper.probe() }) {
                Label(helper.state.isActive ? "Probing…" : "Probe for helper", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
            .disabled(helper.state.isActive || !app.settings.remoteConnectionsEnabled || app.settings.previewMode)
            if !app.settings.remoteConnectionsEnabled {
                Explanation("Turn on Remote connections to probe. Sentinel never probes by itself and keeps no helper connection open.")
            }
            if let message = helper.message {
                NoticeBanner(icon: "info.circle", text: message, tone: helper.report == nil ? .warning : .verified)
            }
            if let report = helper.report {
                InfoRow(label: "Helper version", value: report.helperVersion, mono: true)
                InfoRow(label: "Packaging (self-reported)", value: report.packaging)
                InfoRow(label: "Recognised operations", value: report.recognizedOperations.map { $0.rawValue }.sorted().joined(separator: ", "))
                let ignored = report.supportedOperations.filter { HelperOperation(rawValue: $0) == nil }
                if !ignored.isEmpty {
                    Explanation("Ignored (not in the allowlist, never enabled): \(ignored.joined(separator: ", "))")
                }
            }
        }
    }

    private var helperVerified: Bool { app.capabilityState(.helperLink)?.readiness == .verified }
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
                          detail: "Logs never leave this device unless you export them. Off: activity is kept in memory only and disappears when Sentinel closes. On: the same redacted entries are also appended to a file in the app sandbox (capped at about 500 KB) so you can export them. Credentials, tokens, cookies and passwords are replaced with [REDACTED] before anything is recorded.",
                          isOn: $app.settings.diagnosticLoggingEnabled)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            InfoRow(label: "Log file", value: app.diagnosticLogBytes == 0 ? "Empty" : Formatters.bytes(app.diagnosticLogBytes))
            AdaptiveStack(spacing: 10) {
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
