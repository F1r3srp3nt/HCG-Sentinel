import SentinelCore
import SwiftUI

/// Connected devices: HCG Connect account, this device, pairing with an HCG
/// Server, paired devices with presence and capabilities, shared reports and
/// pending approvals. Every row says whether it is this device (local) or
/// another one (remote).
struct ConnectedDevicesView: View {
    @EnvironmentObject private var devices: ConnectedDevicesModel
    @EnvironmentObject private var app: AppModel
    @State private var code = ""
    @State private var confirmRemove = false

    var body: some View {
        Screen {
            Explanation("Pair Sentinel with an HCG Server you own to see your other HCG devices and send them redacted reports. HCG Connect identifies you and HCG decides what your account may do; the server owner approves every device. Sentinel never sends anything by itself: every share is reviewed and confirmed by you, one report at a time.")
            if !app.settings.remoteConnectionsEnabled {
                NoticeBanner(icon: "wifi.slash", text: "Remote connections are off in Settings, so Sentinel does not contact any HCG Server. Everything on this device keeps working.", tone: .warning)
            }
            if let m = devices.message {
                NoticeBanner(icon: "exclamationmark.triangle", text: m, tone: .warning)
            }
            AccountCard()
            ThisDeviceCard()
            switch devices.link {
            case .notPaired, .ended:
                PairCard(code: $code)
            default:
                ServerCard(confirmRemove: $confirmRemove)
            }
            if devices.record?.status == .approved {
                ServerHealthCard()
                PairedDevicesCard()
                SharedReportsCard()
                ApprovalsCard()
            }
            ShareHistoryCard()
        }
        .navigationBarTitle("Connected Devices", displayMode: .inline)
        .onAppear { devices.appeared() }
        .onDisappear { devices.disappeared() }
        .alert(isPresented: $confirmRemove) {
            Alert(title: Text("Remove this device from the server?"),
                  message: Text("The server stops accepting this device at once. To connect again you need a new invitation and the owner's approval."),
                  primaryButton: .destructive(Text("Remove")) { devices.removeFromServer() }, secondaryButton: .cancel())
        }
    }
}

private struct AccountCard: View {
    @EnvironmentObject private var devices: ConnectedDevicesModel

    var body: some View {
        SentinelCard {
            SectionLabel(text: "HCG Connect account")
            if devices.isLocalDevelopment {
                Explanation("The current pairing does not use this account: it is \(SentinelLinkAuthority.localDevelopmentLabel).")
            }
            switch devices.signIn {
            case .notConfigured(let why):
                StatusPill(text: "Not configured", tone: .off)
                Explanation(why)
            case .signedOut:
                StatusPill(text: "Signed out", tone: .off)
                Button(action: { devices.startSignIn() }) { Label("Sign in with HCG Connect", systemImage: "person.crop.circle") }
                    .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
            case .signedIn(let email):
                StatusPill(text: "Signed in", tone: .verified)
                InfoRow(label: "Account", value: email ?? "HCG account")
                Button(action: { devices.signOut() }) { Label("Sign out on this device", systemImage: "rectangle.portrait.and.arrow.right") }
                    .buttonStyle(SentinelButtonStyle(kind: .secondary))
            case .ended(let why):
                StatusPill(text: "Session ended", tone: .warning)
                Explanation(why)
                Button(action: { devices.startSignIn() }) { Label("Sign in again", systemImage: "person.crop.circle") }
                    .buttonStyle(SentinelButtonStyle(kind: .primary))
            }
        }
    }
}

private struct ThisDeviceCard: View {
    @EnvironmentObject private var devices: ConnectedDevicesModel

    var body: some View {
        SentinelCard {
            AdaptiveStack {
                SectionLabel(text: "This device")
                Spacer(minLength: 0)
                StatusPill(text: "LOCAL", tone: .ready)
            }
            InfoRow(label: "Name", value: devices.deviceName)
            InfoRow(label: "App", value: "HCG Sentinel \(devices.appVersion)")
            if let id = devices.identity {
                InfoRow(label: "Installation", value: String(id.installationId.prefix(8)), mono: true)
                InfoRow(label: "Key", value: id.keyKind == "secure-enclave" ? "Secure Enclave" : "Keychain (software)")
                InfoRow(label: "Key fingerprint", value: LinkCrypto.displayFingerprint(id.fingerprint), mono: true)
                InfoRow(label: "Shares", value: "Reports you choose (report.send)")
            } else if let p = devices.identityProblem {
                Explanation(p)
            }
        }
    }
}

private struct PairCard: View {
    @EnvironmentObject private var devices: ConnectedDevicesModel
    @Binding var code: String

    private var endedReason: String? {
        if case .ended(let why) = devices.link { return why }
        return nil
    }

    var body: some View {
        SentinelCard {
            SectionLabel(text: "Pair device")
            if let why = endedReason { NoticeBanner(icon: "xmark.octagon", text: why, tone: .danger) }
            Explanation("On the computer running HCG Server, create an invitation and paste its code here (it starts with hcg1-). The code names the server and its key; the server owner then approves this device after comparing the key fingerprint below.")
            TextField("hcg1-…", text: $code)
                .font(Theme.mono(.footnote))
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .padding(10)
                .background(Theme.panelInset)
                .cornerRadius(8)
            Button(action: { devices.pair(code: code) }) { Label("Request pairing", systemImage: "link") }
                .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                .disabled(code.isEmpty || devices.busy)
        }
    }
}

private struct ServerCard: View {
    @EnvironmentObject private var devices: ConnectedDevicesModel
    @Binding var confirmRemove: Bool

    var body: some View {
        SentinelCard {
            AdaptiveStack {
                SectionLabel(text: "HCG Server")
                Spacer(minLength: 0)
                status
            }
            if let r = devices.record {
                if r.isLocalDevelopment { LocalDevelopmentBanner() }
                InfoRow(label: "Authority", value: r.isLocalDevelopment ? SentinelLinkAuthority.localDevelopmentLabel : "HCG Connect")
                InfoRow(label: "Server", value: r.serverName)
                InfoRow(label: "Address", value: r.serverAddress, mono: true)
                InfoRow(label: "Server key", value: LinkCrypto.displayFingerprint(r.serverFingerprint), mono: true)
            }
            switch devices.link {
            case .pairing:
                Explanation("Waiting for the owner to approve this device on the server. They should see this key fingerprint:")
                if let id = devices.identity { Text(LinkCrypto.displayFingerprint(id.fingerprint)).font(Theme.mono(.footnote)).foregroundColor(Theme.cyan) }
            case .offline(let reason, let retry):
                Explanation("\(reason) Retrying in \(Int(retry)) s.")
            case .paused(let why):
                Explanation(why)
            default:
                if let t = devices.lastSync { InfoRow(label: "Last sync", value: Formatters.preciseTime.string(from: t), mono: true) }
            }
            Button(action: { confirmRemove = true }) { Label("Disconnect and remove this device", systemImage: "xmark.circle") }
                .buttonStyle(SentinelButtonStyle(kind: .destructive))
                .disabled(devices.busy)
        }
    }

    @ViewBuilder private var status: some View {
        switch devices.link {
        case .connected: StatusPill(text: "Connected", tone: .verified)
        case .pairing: StatusPill(text: "Awaiting approval", tone: .warning)
        case .offline: StatusPill(text: "Offline", tone: .warning)
        case .paused: StatusPill(text: "Paused", tone: .off)
        case .ended: StatusPill(text: "Disconnected", tone: .danger)
        case .notPaired: StatusPill(text: "Not paired", tone: .off)
        }
    }
}

struct LinkDeviceRow: View {
    let device: LinkInstallation
    let isSelf: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AdaptiveStack {
                Image(systemName: device.app == "hcg.terminal" ? "terminal" : device.app == "hcg.nexus" ? "square.grid.3x3" : "shield.lefthalf.fill")
                    .foregroundColor(Theme.cyan)
                Text(device.name).font(.headline).foregroundColor(Theme.textPrimary)
                Spacer(minLength: 0)
                StatusPill(text: isSelf ? "LOCAL" : "REMOTE", tone: isSelf ? .ready : .accent)
                StatusPill(text: presence, tone: device.state == .online ? .verified : .off)
            }
            if SentinelLinkAuthority.isLocalDevelopment(device) {
                StatusPill(text: SentinelLinkAuthority.localDevelopmentLabel, tone: .warning)
            }
            Text(appLabel).font(.footnote).foregroundColor(Theme.textSecondary)
            if let seen = device.lastSeenAt, device.state != .online {
                Text("Last seen \(Formatters.preciseTime.string(from: seen))").font(Theme.mono(.caption)).foregroundColor(Theme.textSecondary)
            }
            ForEach(device.capabilities, id: \.id) { cap in
                HStack(spacing: 6) {
                    Circle().fill(cap.state.isUsable ? Theme.ok : Theme.textSecondary).frame(width: 6, height: 6)
                    Text(cap.id).font(Theme.mono(.caption)).foregroundColor(Theme.textPrimary)
                    Text(cap.state.rawValue + (cap.reason.map { " — \($0)" } ?? "")).font(.caption).foregroundColor(Theme.textSecondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var presence: String {
        switch device.state {
        case .online: return "Online"
        case .offline: return "Offline"
        case .neverSeen: return "Not seen yet"
        case .revoked: return "Removed"
        }
    }

    private var appLabel: String {
        let app: String
        switch device.app {
        case "hcg.terminal": app = "HCG Terminal" + (device.variant == "unleashed" ? " Unleashed" : " (Vanilla)")
        case "hcg.sentinel": app = "HCG Sentinel"
        case "hcg.nexus": app = "HCG Nexus"
        default: app = device.app
        }
        return "\(app) \(device.appVersion) · \(device.platform)"
    }
}

private struct PairedDevicesCard: View {
    @EnvironmentObject private var devices: ConnectedDevicesModel

    var body: some View {
        SentinelCard {
            SectionLabel(text: "Paired devices")
            if let d = devices.devices {
                ForEach(d.installations) { LinkDeviceRow(device: $0, isSelf: $0.installationId == d.selfInstallationId) }
                Explanation("Online means seen by the server in the last \(d.onlineWindowSeconds) seconds. Capabilities are what each device says about itself; they never grant anything.")
            } else {
                Explanation("Not loaded yet.")
            }
        }
    }
}

private struct SharedReportsCard: View {
    @EnvironmentObject private var devices: ConnectedDevicesModel
    @State private var withdrawing: String?
    @State private var result: String?

    var body: some View {
        SentinelCard {
            SectionLabel(text: "Shared reports")
            if devices.outbox.isEmpty {
                Explanation("Nothing waiting on the server. Open a Security Lab report, a finished network check or HCG Server health and choose Share with paired device; you review the exact report before anything is sent.")
            }
            ForEach(devices.outbox) { m in
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.title).font(.subheadline).foregroundColor(Theme.textPrimary)
                    Text("To \(m.to.name) (remote) · \(m.status) · expires \(Formatters.preciseTime.string(from: m.expiresAt))")
                        .font(.caption).foregroundColor(Theme.textSecondary)
                    if m.status == "queued" {
                        Button(action: { withdraw(m.messageId) }) { Label("Withdraw", systemImage: "arrow.uturn.backward") }
                            .buttonStyle(SentinelButtonStyle(kind: .destructive))
                            .disabled(withdrawing != nil)
                    }
                }
            }
            if let r = result { NoticeBanner(icon: "arrow.uturn.backward", text: r, tone: .info) }
            Explanation("A queued report has not been downloaded yet and can be withdrawn; HCG Server then deletes its copy. Once the device downloads it, it can no longer be recalled.")
        }
    }

    private func withdraw(_ id: String) {
        withdrawing = id
        Task {
            result = await devices.withdraw(messageId: id)
            withdrawing = nil
        }
    }
}

/// The local share history: every send, cancellation, failure and withdrawal.
/// It holds no report content, only titles, types, sizes and SHA-256 values.
private struct ShareHistoryCard: View {
    @EnvironmentObject private var devices: ConnectedDevicesModel

    var body: some View {
        SentinelCard {
            SectionLabel(text: "Share history (this device)")
            if devices.shareHistory.isEmpty {
                Explanation("No reports shared or cancelled yet.")
            }
            ForEach(devices.shareHistory.prefix(100)) { e in
                VStack(alignment: .leading, spacing: 3) {
                    AdaptiveStack {
                        StatusPill(text: (e.action == .withdraw ? "Withdraw: " : "") + e.outcome.label, tone: tone(e))
                        Text(Formatters.preciseTime.string(from: e.time)).font(Theme.mono(.caption)).foregroundColor(Theme.textSecondary)
                    }
                    Text(verbatim: e.reportTitle).font(.subheadline).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: "\(e.reportKind) · \(e.payloadSize) bytes" + (e.payloadSha256.isEmpty ? "" : " · SHA-256 \(e.payloadSha256.prefix(16))…"))
                        .font(Theme.mono(.caption)).foregroundColor(Theme.textSecondary)
                    Text(verbatim: "To " + (e.destinationName ?? "no device chosen")
                         + (e.destinationFingerprint.map { $0.isEmpty ? "" : " · key \(LinkCrypto.displayFingerprint(String($0.prefix(16))))…" } ?? ""))
                        .font(.caption).foregroundColor(Theme.textSecondary)
                    if let d = e.detail { Text(verbatim: d).font(.caption).foregroundColor(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(.vertical, 2)
            }
            Explanation("Kept only on this device. It records what was shared, with whom and how it ended, never the report itself.")
        }
    }

    private func tone(_ e: ShareAuditEntry) -> Tone {
        switch e.outcome {
        case .sent: return .verified
        case .withdrawn: return .accent
        case .failed: return .danger
        case .cancelledBeforeSend: return .off
        }
    }
}

private struct ApprovalsCard: View {
    @EnvironmentObject private var devices: ConnectedDevicesModel

    var body: some View {
        SentinelCard {
            SectionLabel(text: "Pending approvals")
            if let a = devices.approvals, !a.approvals.isEmpty {
                ForEach(a.approvals, id: \.action.actionId) { Explanation("\($0.action.type) from \($0.origin.name)") }
            } else {
                Explanation(devices.approvals?.note ?? "Nothing is waiting for your approval.")
            }
        }
    }
}

/// Shown wherever a local-development connection appears.
struct LocalDevelopmentBanner: View {
    var body: some View {
        NoticeBanner(icon: "hammer",
                     text: SentinelLinkAuthority.localDevelopmentLabel + ". " + SentinelLinkAuthority.localDevelopmentExplanation,
                     tone: .warning)
    }
}
