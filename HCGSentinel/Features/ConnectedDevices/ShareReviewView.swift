import SentinelCore
import SwiftUI

/// The dedicated review screen every "Share with paired device" button opens.
///
/// Nothing is transmitted until the user presses Send and confirms. The screen
/// shows the exact redacted payload that will be sent (built and encoded once
/// when the screen opens, with its size and SHA-256 and what the redaction
/// removed), the strict check result, and the destination's identity as the
/// pinned HCG Server reports it. Send re-checks the destination first and
/// refuses if its key changed. Cancel sends nothing. A sent report can be
/// withdrawn until the recipient downloads it. No choice is remembered: the
/// next share starts from this screen again.
struct ShareReviewSheet: View {
    @EnvironmentObject private var devices: ConnectedDevicesModel
    @Environment(\.presentationMode) private var presentation
    /// Shown before the report is built.
    let title: String
    let makeReport: (ShareOrigin, ShareRedaction) -> DiagnosticReport

    private enum Phase: Equatable {
        case reviewing
        case sending
        case sent(messageId: String, recipientState: String, expiresAt: Date)
        case refused(String)
        case failed(String)
    }

    @State private var payload: SharePayload?
    @State private var selected: ShareDestination?
    @State private var phase: Phase = .reviewing
    @State private var messageId = LinkCrypto.uuid()
    @State private var confirmSend = false
    @State private var attempted = false
    @State private var closed = false
    @State private var withdrawing = false
    @State private var withdrawResult: String?
    @State private var readable = false

    var body: some View {
        NavContainer {
            Screen {
                statusBanner
                if devices.isLocalDevelopment { LocalDevelopmentBanner() }
                if let p = payload {
                    reportCard(p)
                    checkCard(p)
                    redactionCard(p)
                    payloadCard(p)
                    destinationCard
                    actions(p)
                } else {
                    SentinelCard {
                        StatusPill(text: "Nothing to review", tone: .off)
                        Explanation(devices.identityProblem ?? "This device is not paired with an HCG Server. Pair it in Connected Devices first.")
                    }
                }
            }
            .navigationBarTitle("Review before sharing", displayMode: .inline)
            .navigationBarItems(trailing: Button(isSent ? "Close" : "Cancel") { close() })
        }
        .onAppear(perform: prepareOnce)
        .onDisappear(perform: recordCancelIfUnsent)
        .alert(isPresented: $confirmSend) {
            Alert(title: Text("Send this report?"),
                  message: Text(confirmationText),
                  primaryButton: .default(Text("Send")) { send() },
                  secondaryButton: .cancel(Text("Don't send")))
        }
    }

    // MARK: sections

    @ViewBuilder private var statusBanner: some View {
        switch phase {
        case .reviewing:
            NoticeBanner(icon: "hand.raised",
                         text: "Nothing has been sent. Check the exact report below and the destination's key, then press Send. Sentinel never sends by itself and does not remember this choice.",
                         tone: .info)
        case .sending:
            NoticeBanner(icon: "paperplane", text: "Re-checking the destination with HCG Server, then sending…", tone: .info)
        case .sent(_, let state, let expires):
            NoticeBanner(icon: "checkmark.seal",
                         text: (state == "online" ? "Sent to \(selected?.name ?? "the device")." : "Queued for \(selected?.name ?? "the device"); it is offline and receives the report when it next connects.")
                            + " You can withdraw it until the device downloads it (it expires \(Formatters.preciseTime.string(from: expires))).",
                         tone: .info)
        case .refused(let why):
            NoticeBanner(icon: "xmark.octagon", text: "Not sent. \(why)", tone: .danger)
        case .failed(let why):
            NoticeBanner(icon: "exclamationmark.triangle", text: why, tone: .warning)
        }
    }

    private func reportCard(_ p: SharePayload) -> some View {
        SentinelCard {
            SectionLabel(text: "Report")
            Text(verbatim: p.title).font(.subheadline).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
            InfoRow(label: "Type", value: p.kind, mono: true)
            InfoRow(label: "Size", value: "\(p.size) bytes (\(ByteCountFormatter.string(fromByteCount: Int64(p.size), countStyle: .file)))")
            VStack(alignment: .leading, spacing: 2) {
                Text("SHA-256 of the payload").font(.caption).foregroundColor(Theme.textSecondary)
                Text(verbatim: LinkCrypto.displayFingerprint(p.sha256)).font(Theme.mono(.footnote)).foregroundColor(Theme.cyan)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func checkCard(_ p: SharePayload) -> some View {
        SentinelCard(highlight: p.isSendable ? nil : Theme.danger) {
            SectionLabel(text: "Strict check", tone: p.isSendable ? .verified : .danger)
            if p.isSendable {
                StatusPill(text: "Passed", tone: .verified)
                Explanation("No credentials, tokens, private keys, IP or MAC addresses, e-mail addresses, user names or home folders, serial numbers, or host names other than the server's display name were found in the payload.")
            } else {
                StatusPill(text: "Sending blocked", tone: .danger)
                ForEach(p.blockers, id: \.self) { Explanation("• " + $0) }
                Explanation("This report cannot be shared as it is. Nothing was sent.")
            }
        }
    }

    private func redactionCard(_ p: SharePayload) -> some View {
        SentinelCard {
            SectionLabel(text: "Removed before sharing")
            if p.redactions.isEmpty {
                Explanation("Nothing needed removing.")
            } else {
                ForEach(p.redactions, id: \.rule) { InfoRow(label: $0.rule, value: "\($0.count)") }
            }
            Explanation("Removed values appear as [REDACTED …] in the payload. Wi-Fi names and BSSIDs are never included.")
        }
    }

    private func payloadCard(_ p: SharePayload) -> some View {
        SentinelCard {
            SectionLabel(text: "Exact payload")
            Picker("View", selection: $readable) {
                Text("Exact bytes").tag(false)
                Text("Readable").tag(true)
            }
            .pickerStyle(SegmentedPickerStyle())
            ScrollView {
                Text(verbatim: readable ? ReportTextRenderer.text(p.report) : p.text)
                    .font(Theme.mono(.caption))
                    .foregroundColor(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
            }
            .frame(maxHeight: 320)
            .background(Theme.panelInset)
            .cornerRadius(8)
            Explanation(readable
                        ? "The same payload laid out as the receiving app shows it. What is sent is the exact bytes."
                        : "These UTF-8 bytes are sent unchanged, inside a Device Link envelope that adds only a message ID, the destination's installation ID, a creation time and an expiry.")
        }
    }

    private var destinationCard: some View {
        SentinelCard {
            SectionLabel(text: "Destination (remote device)")
            if devices.shareDestinations.isEmpty {
                Explanation(devices.record?.status == .approved
                            ? "No approved device of this HCG Server accepts reports right now. HCG Terminal and HCG Nexus can receive them once paired and approved."
                            : "Pair this device with an HCG Server in Connected Devices first.")
            }
            ForEach(devices.shareDestinations) { d in
                Button(action: { choose(d) }) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selected?.installationId == d.installationId ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(Theme.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: d.name).font(.headline).foregroundColor(Theme.textPrimary)
                            Text(verbatim: "\(d.appLabel) \(d.appVersion) · \(d.platform)").font(.footnote).foregroundColor(Theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                        StatusPill(text: "REMOTE", tone: .accent)
                    }
                }
                .disabled(isBusy || isSent)
            }
            if let d = selected {
                Divider()
                InfoRow(label: "Name", value: d.name)
                InfoRow(label: "App", value: "\(d.appLabel) \(d.appVersion)")
                if d.authority == DeviceLinkProtocol.Authority.localDevelopment {
                    StatusPill(text: SentinelLinkAuthority.localDevelopmentLabel, tone: .warning)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Key fingerprint (reported by HCG Server)").font(.caption).foregroundColor(Theme.textSecondary)
                    Text(verbatim: d.displayFingerprint).font(Theme.mono(.footnote)).foregroundColor(Theme.cyan).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                InfoRow(label: "Reported by", value: "\(d.serverName) · server key \(String(LinkCrypto.displayFingerprint(d.serverFingerprint).prefix(19)))…", mono: false)
                Explanation("Compare this fingerprint with the one the receiving app shows for itself (its Connected Devices screen, This device → Key fingerprint). The list comes only from the HCG Server pinned at pairing. Right before sending, Sentinel asks the server again and refuses if the device was removed or its key changed.")
            }
        }
    }

    private func actions(_ p: SharePayload) -> some View {
        VStack(spacing: 10) {
            if case .sent(let id, _, _) = phase {
                Button(action: { withdraw(id) }) { Label("Withdraw", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
                    .disabled(withdrawing || withdrawResult != nil)
                if let w = withdrawResult { NoticeBanner(icon: "arrow.uturn.backward", text: w, tone: .info) }
            } else {
                Button(action: { confirmSend = true }) {
                    Label(selected.map { "Send to \($0.name)" } ?? "Choose a destination", systemImage: "paperplane")
                }
                .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                .disabled(!p.isSendable || selected == nil || isBusy || !devices.remoteAllowed())
                Button(action: { close() }) { Label("Cancel — send nothing", systemImage: "xmark") }
                    .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
                    .disabled(isBusy)
                if !devices.remoteAllowed() {
                    Explanation("Remote connections are off in Settings, so nothing can be sent.")
                }
            }
        }
    }

    // MARK: behaviour

    private var isBusy: Bool { phase == .sending }
    private var isSent: Bool { if case .sent = phase { return true } else { return false } }

    private var confirmationText: String {
        guard let p = payload, let d = selected else { return "" }
        return "\(p.size) bytes, SHA-256 \(String(LinkCrypto.displayFingerprint(p.sha256).prefix(19)))…, to \(d.name) (\(d.appLabel)), key \(String(d.displayFingerprint.prefix(19)))…, through \(d.serverName). You can withdraw it until \(d.name) downloads it."
    }

    /// Builds the payload once; later redraws show the same bytes.
    private func prepareOnce() {
        guard payload == nil else { return }
        payload = devices.prepareShare(makeReport)
        // No destination is preselected: the user picks one and sees its key first.
    }

    private func choose(_ d: ShareDestination) {
        if selected?.installationId != d.installationId || selected?.keyFingerprint != d.keyFingerprint { messageId = LinkCrypto.uuid() }
        selected = d
        if case .refused = phase { phase = .reviewing }
    }

    private func send() {
        guard let p = payload, let d = selected, p.isSendable else { return }
        attempted = true
        phase = .sending
        let id = messageId
        Task {
            switch await devices.send(p, to: d, messageId: id) {
            case .sent(let messageId, let state, let expires):
                phase = .sent(messageId: messageId, recipientState: state, expiresAt: expires)
            case .refused(let why):
                phase = .refused(why)
                // The destination must be chosen (and its key compared) again.
                selected = nil
                messageId = LinkCrypto.uuid()
            case .failed(let why, _):
                phase = .failed(why)
            }
        }
    }

    private func withdraw(_ id: String) {
        withdrawing = true
        Task {
            withdrawResult = await devices.withdraw(messageId: id)
            withdrawing = false
        }
    }

    private func close() {
        recordCancelIfUnsent()
        presentation.wrappedValue.dismiss()
    }

    /// Closing without sending is recorded as cancelled before sending (no network call).
    private func recordCancelIfUnsent() {
        guard !closed else { return }
        closed = true
        guard let p = payload, !attempted, !isSent else { return }
        devices.cancelShare(p, destination: selected)
    }
}
