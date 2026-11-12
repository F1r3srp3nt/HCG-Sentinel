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
                         text: "This composer edits and sends requests that Sentinel itself creates, to the one test endpoint you selected. It does not intercept other apps’ traffic and cannot decrypt captured HTTPS.")
            endpointCard
            requestCard
            headersCard
            bodyCard
            actionCard
            responseSection
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
            SectionLabel(text: "HCG test endpoint")
            if let endpoint = requests.endpoint {
                Text(endpoint.displayString)
                    .font(Theme.mono(.subheadline))
                    .foregroundColor(Theme.textPrimary)
                Explanation("Requests can only go to this scheme, host and port. Redirects are shown, never followed.")
                if endpoint.scheme == "http" {
                    Explanation("Plain HTTP is unencrypted. iOS only permits it for local-network and loopback addresses.")
                }
            } else {
                Text("No endpoint selected")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                if let problem = requests.endpointProblem {
                    NoticeBanner(icon: "exclamationmark.triangle.fill", text: problem, tone: .warning)
                }
                Explanation("Choose the service you are authorised to test. Nothing can be sent until you do.")
            }
            Button(requests.endpoint == nil ? "Select endpoint in Settings" : "Change in Settings") { router.open(.settings) }
                .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
        }
    }

    // MARK: Editing

    private var requestCard: some View {
        SentinelCard {
            SectionLabel(text: "Request line")
            HStack(spacing: 10) {
                Picker("Method", selection: $requests.draft.method) {
                    ForEach(HTTPMethod.allCases, id: \.self) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(minWidth: 92, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.panelInset))
                .accessibilityLabel("HTTP method")
                TextField("/path?query=value", text: $requests.draft.path)
                    .technicalInput()
                    .keyboardType(.URL)
                    .sentinelField()
                    .accessibilityLabel("Path and query")
            }
            Text("Method: \(requests.draft.method.rawValue)")
                .font(Theme.mono(.caption))
                .foregroundColor(Theme.textSecondary)
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
            ResponseCard(response: response)
        }
    }
}

private struct HeaderEditorRow: View {
    @Binding var header: HeaderField
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
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
    private static let displayLimit = 20_000

    var body: some View {
        let text = response.bodyText
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
                if text.isEmpty {
                    Explanation("The response has no body.")
                } else {
                    Text(String(text.prefix(ResponseCard.displayLimit)))
                        .font(Theme.mono(.caption))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if text.count > ResponseCard.displayLimit || response.bodyTruncated {
                        Explanation("The body is longer than what is shown here.")
                    }
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
