import SentinelCore
import SwiftUI

struct RequestComposerView: View {
    @EnvironmentObject private var requests: RequestModel
    @EnvironmentObject private var router: Router
    @State private var showPreview = false

    var body: some View {
        Screen {
            if requests.previewMode {
                PreviewBanner(detail: "Sending is paused in Preview mode. You can still edit a request and review it. No response data is fabricated.")
            }
            NoticeBanner(icon: "paperplane",
                         text: "This composer edits and sends requests that Sentinel itself creates, to the test endpoints you listed in Settings. It does not intercept other apps’ traffic and cannot decrypt captured HTTPS.")
            endpointCard
            requestCard
            headersCard
            bodyCard
            actionCard
            responseSection
            RequestHistoryCard()
            FilteringCard()
        }
        .navigationBarTitle("Request Composer", displayMode: .inline)
        .sheet(isPresented: $showPreview) {
            RequestPreviewSheet(isPresented: $showPreview)
                .environmentObject(requests)
                .accentColor(Theme.cyan)
                .preferredColorScheme(.dark)
        }
    }

    // MARK: Endpoint

    private var endpointCard: some View {
        SentinelCard {
            SectionLabel(text: "Allowed test endpoints")
            if requests.endpoints.isEmpty {
                Text("No endpoint added")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Explanation("Add the services you are authorised to test in Settings. Nothing can be sent until you do.")
            } else {
                ForEach(Array(requests.endpoints.enumerated()), id: \.offset) { item in
                    Text(item.offset == 0 ? "\(item.element.displayString)  (primary)" : item.element.displayString)
                        .font(Theme.mono(.subheadline))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Explanation("A request URL must match one of these exactly in scheme, host and port. A URL starting with “/” uses the primary endpoint. Redirects are shown, never followed.")
                if requests.endpoints.contains(where: { $0.scheme == "http" }) {
                    Explanation("Plain HTTP is unencrypted. iOS only permits it for local-network and loopback addresses.")
                }
            }
            ForEach(requests.endpointProblems, id: \.self) { problem in
                NoticeBanner(icon: "exclamationmark.triangle.fill", text: problem, tone: .warning)
            }
            if !requests.remoteConnectionsEnabled {
                NoticeBanner(icon: "wifi.slash", text: "Remote connections are off, so nothing can be sent. Turn them on in Settings.", tone: .warning)
            }
            Button(requests.endpoints.isEmpty ? "Add endpoints in Settings" : "Change in Settings") { router.open(.settings) }
                .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
        }
    }

    // MARK: Editing

    private var requestCard: some View {
        SentinelCard {
            SectionLabel(text: "Method and URL")
            VStack(alignment: .leading, spacing: 10) {
                Picker("Method", selection: $requests.draft.method) {
                    ForEach(HTTPMethod.allCases, id: \.self) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(minWidth: 92, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.panelInset))
                .accessibilityLabel("HTTP method")
                TextField("https://test.example/path?query=value", text: $requests.draft.url)
                    .technicalInput()
                    .keyboardType(.URL)
                    .sentinelField()
                    .accessibilityLabel("Request URL")
            }
            Text("Method: \(requests.draft.method.rawValue)")
                .font(Theme.mono(.caption))
                .foregroundColor(Theme.textSecondary)
            Explanation("This edits a request that Sentinel itself creates. It does not intercept or modify other apps’ traffic and cannot decrypt captured HTTPS.")
        }
    }

    private var headersCard: some View {
        SentinelCard {
            SectionLabel(text: "Headers")
            ForEach(requests.draft.headers) { header in
                HeaderEditorRow(header: binding(for: header.id)) {
                    requests.draft.headers.removeAll { $0.id == header.id }
                }
            }
            Button(action: { requests.draft.headers.append(HeaderField(name: "", value: "")) }) {
                Label("Add header", systemImage: "plus.circle")
            }
            .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
            Explanation("Host, Content-Length and connection headers are set by iOS and cannot be edited here.")
        }
    }

    private func binding(for id: UUID) -> Binding<HeaderField> {
        Binding(
            get: { requests.draft.headers.first { $0.id == id } ?? HeaderField(id: id, name: "", value: "") },
            set: { updated in
                if let index = requests.draft.headers.firstIndex(where: { $0.id == id }) {
                    requests.draft.headers[index] = updated
                }
            })
    }

    private var bodyCard: some View {
        SentinelCard {
            SectionLabel(text: "Body")
            TextEditor(text: $requests.draft.body)
                .technicalInput()
                .font(Theme.mono(.footnote))
                .foregroundColor(Theme.textPrimary)
                .frame(minHeight: 120)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.panelInset))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                .accessibilityLabel("Request body")
            Explanation("\(requests.draft.body.utf8.count) bytes. GET and HEAD are sent without a body. Drafts are kept in memory only and are not saved.")
        }
    }

    private var actionCard: some View {
        SentinelCard {
            if requests.isSending {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for the endpoint…").font(.subheadline).foregroundColor(Theme.textPrimary)
                    Spacer()
                }
                Button(action: { requests.cancel() }) { Label("Cancel request", systemImage: "xmark.circle") }
                    .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
            } else {
                Button(action: { showPreview = true }) { Label("Review request…", systemImage: "eye") }
                    .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                Explanation("Nothing is sent from this screen. Review shows exactly what will go out; sending needs a separate tap there.")
                Button("Reset to template") { requests.resetDraft() }
                    .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
            }
        }
    }

    // MARK: Response

    @ViewBuilder private var responseSection: some View {
        switch requests.state {
        case .idle, .sending:
            EmptyView()
        case .failed(let failure):
            SectionLabel(text: "Result", tone: .warning)
            NoticeBanner(icon: "exclamationmark.triangle.fill", text: failure.userMessage, tone: .warning)
        case .completed(let response):
            SectionLabel(text: "Response", tone: .verified)
            ResponseCard(response: response, format: $requests.bodyFormat)
        }
    }
}

private struct HeaderEditorRow: View {
    @Binding var header: HeaderField
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            AdaptiveStack(spacing: 8) {
                Toggle("Send this header", isOn: $header.isEnabled)
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: Theme.cyan))
                TextField("Name", text: $header.name)
                    .technicalInput()
                    .sentinelField()
                    .accessibilityLabel("Header name")
                Button(action: onDelete) {
                    Image(systemName: "minus.circle").foregroundColor(Theme.danger).frame(width: 36, height: 44)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Remove header \(header.name)")
            }
            TextField("Value", text: $header.value)
                .technicalInput()
                .sentinelField()
                .accessibilityLabel("Header value")
        }
        .opacity(header.isEnabled ? 1 : 0.55)
        .padding(.bottom, 4)
    }
}

/// Shows the exact request and its differences from the template. Sending happens only from here.
private struct RequestPreviewSheet: View {
    @EnvironmentObject private var requests: RequestModel
    @Binding var isPresented: Bool

    var body: some View {
        NavContainer {
            Screen {
                switch requests.prepare() {
                case .failure(let error):
                    NoticeBanner(icon: "xmark.octagon.fill", text: error.userMessage, tone: .danger)
                    Explanation("Fix this in the composer. Nothing was sent.")
                case .success(let prepared):
                    SentinelCard {
                        SectionLabel(text: "Destination")
                        Text(prepared.url.absoluteString)
                            .font(Theme.mono(.footnote))
                            .foregroundColor(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        InfoRow(label: "Allowed by endpoint", value: prepared.endpoint, mono: true)
                    }
                    changesCard
                    SentinelCard {
                        SectionLabel(text: "Request as it will be sent", tone: .info)
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(RequestPreview.rawText(prepared))
                                .font(Theme.mono(.caption))
                                .foregroundColor(Theme.textPrimary)
                                .fixedSize()
                        }
                        Explanation("Shown in full here so you can check it. The activity log records only the method, the redacted URL and sizes.")
                    }
                    if requests.previewMode {
                        NoticeBanner(icon: "theatermasks.fill", text: "Sending is paused while Preview mode is on.", tone: .accent)
                    } else if !requests.remoteConnectionsEnabled {
                        NoticeBanner(icon: "wifi.slash", text: "Remote connections are off in Settings, so this request cannot be sent.", tone: .warning)
                    } else {
                        Button(action: {
                            requests.send()
                            isPresented = false
                        }) {
                            Label("Send request", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                        .disabled(requests.isSending)
                    }
                }
            }
            .navigationBarTitle("Review request", displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }

    private var changesCard: some View {
        let changes = requests.changes
        return SentinelCard {
            SectionLabel(text: "Changes from template", tone: .accent)
            if changes.isEmpty {
                Explanation("No changes. This is the unmodified template request.")
            } else {
                ForEach(changes) { change in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.title)
                            .font(.system(.footnote, design: .default).weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                        if let before = change.before {
                            Text("− \(before)").font(Theme.mono(.caption)).foregroundColor(Theme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let after = change.after {
                            Text("+ \(after)").font(Theme.mono(.caption)).foregroundColor(Theme.ok)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct ResponseCard: View {
    let response: HTTPResponseRecord
    @Binding var format: ResponseBodyFormat

    var body: some View {
        return VStack(alignment: .leading, spacing: 14) {
            SentinelCard(highlight: tone.color) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(response.statusCode)")
                        .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                        .foregroundColor(tone.color)
                    Text(HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized)
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                }
                InfoRow(label: "Total time", value: String(format: "%.0f ms", response.duration * 1000), mono: true)
                InfoRow(label: "Sent at", value: Formatters.preciseTime.string(from: response.startedAt), mono: true)
                InfoRow(label: "Body size", value: Formatters.bytes(response.totalBodyBytes), mono: true)
                Explanation("Total time is measured from Send until the full response arrived, including connection setup.")
                if let timing = response.timing {
                    InfoRow(label: "DNS / connect / TLS", value: [timing.dns, timing.connect, timing.tls].map { $0.map { String(format: "%.0f ms", $0 * 1000) } ?? "—" }.joined(separator: " / "), mono: true)
                    InfoRow(label: "Time to first byte", value: timing.firstByte.map { String(format: "%.0f ms", $0 * 1000) } ?? "—", mono: true)
                    if timing.reusedConnection { Explanation("The connection was reused, so there was no DNS, connect or TLS phase.") }
                }
            }
            if let tls = response.tls {
                SentinelCard {
                    SectionLabel(text: "TLS", tone: .info)
                    InfoRow(label: "Protocol", value: tls.protocolVersion ?? "Not reported", mono: true)
                    InfoRow(label: "Cipher suite", value: tls.cipherSuite ?? "Not reported", mono: true)
                    InfoRow(label: "Trusted by iOS", value: tls.trusted.map { $0 ? "Yes" : "No" } ?? "Not reported")
                    ForEach(Array(tls.certificates.enumerated()), id: \.offset) { item in
                        InfoRow(label: item.offset == 0 ? "Certificate" : "Issuer \(item.offset)", value: item.element)
                    }
                    Explanation("As iOS reported it for this connection. Sentinel does not bypass certificate checks: an untrusted certificate fails the request.")
                }
            }
            SentinelCard {
                SectionLabel(text: "Response headers", tone: .info)
                if response.headers.isEmpty { Explanation("No headers.") }
                ForEach(Array(response.headers.enumerated()), id: \.offset) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.element.name).font(.caption).foregroundColor(Theme.textSecondary)
                        Text(item.element.value)
                            .font(Theme.mono(.footnote))
                            .foregroundColor(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            SentinelCard {
                SectionLabel(text: "Response body", tone: .info)
                if response.body.isEmpty {
                    Explanation("The response has no body.")
                } else {
                    Picker("Body format", selection: $format) {
                        ForEach(ResponseBodyFormat.allCases, id: \.self) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(ResponseFormatter.render(response.body, as: format))
                            .font(Theme.mono(.caption))
                            .foregroundColor(Theme.textPrimary)
                            .fixedSize(horizontal: format == .hex, vertical: true)
                    }
                    if response.bodyTruncated {
                        Explanation("Only the first \(Formatters.bytes(response.body.count)) of \(Formatters.bytes(response.totalBodyBytes)) were kept.")
                    }
                    Explanation("The body is displayed as data only. Nothing in it is executed, loaded or followed.")
                }
            }
        }
    }

    private var tone: Tone {
        switch response.statusCode {
        case 200..<300: return .verified
        case 300..<400: return .ready
        case 400..<500: return .warning
        default: return .danger
        }
    }
}


/// Requests sent in this session, newest first. URLs are redacted; header values are never kept.
private struct RequestHistoryCard: View {
    @EnvironmentObject private var requests: RequestModel

    var body: some View {
        SentinelCard {
            AdaptiveStack {
                SectionLabel(text: "History (this session only)")
                Spacer(minLength: 0)
                if !requests.history.isEmpty { Button("Clear") { requests.clearHistory() }.font(.footnote) }
            }
            if requests.history.isEmpty { Explanation("Sent requests appear here until Sentinel quits: method, redacted URL, header names, outcome and time.") }
            ForEach(requests.history) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Formatters.time.string(from: entry.at)) · \(entry.method) \(entry.url)")
                        .font(Theme.mono(.caption)).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    Text([entry.outcome, entry.duration.map { String(format: "%.0f ms", $0 * 1000) }, entry.tls?.protocolVersion,
                          entry.headerNames.isEmpty ? nil : "headers: \(entry.headerNames.joined(separator: ", "))", entry.bodyBytes > 0 ? "\(entry.bodyBytes)-byte body" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundColor(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
