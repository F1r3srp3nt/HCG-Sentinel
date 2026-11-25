import SentinelCore
import SwiftUI

/// Entry to the HCG Server health screen from Connected Devices.
struct ServerHealthCard: View {
    @EnvironmentObject private var devices: ConnectedDevicesModel

    var body: some View {
        SentinelCard {
            SectionLabel(text: "HCG Server health")
            Explanation("Read-only diagnostics from the paired server: availability, TLS, hosted services and security events, exactly as the server reports them. Viewing them sends nothing.")
            if devices.isLocalDevelopment { StatusPill(text: SentinelLinkAuthority.localDevelopmentLabel, tone: .warning) }
            NavigationLink(destination: ServerHealthView()) {
                Label("View server health", systemImage: "stethoscope")
            }
            .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
        }
    }
}

/// HCG Server health (Device Link `link/diagnostics`). Read only: it shows
/// what the server returned, or "not connected" / the real error. It runs no
/// action on the server and shows no credentials; security events arrive
/// redacted by the server and are shown as plain text.
struct ServerHealthView: View {
    @EnvironmentObject private var devices: ConnectedDevicesModel
    @State private var share = false

    var body: some View {
        Screen {
            Explanation("What HCG Server reports about itself. Sentinel only reads this; nothing here changes the server or sends anything to another device. Values the server did not send say \"Not reported\".")
            if devices.isLocalDevelopment { LocalDevelopmentBanner() }
            switch devices.health {
            case .notConnected(let why):
                SentinelCard {
                    StatusPill(text: "Not connected", tone: .off)
                    Explanation(why)
                }
            case .loading:
                SentinelCard {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading diagnostics from HCG Server…").font(.footnote).foregroundColor(Theme.textSecondary)
                    }
                }
            case .failed(let error):
                SentinelCard {
                    StatusPill(text: "Could not read diagnostics", tone: .danger)
                    Text(verbatim: error).font(.footnote).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                }
            case .loaded(let d, let fetchedAt):
                InfoRow(label: "Read at", value: Formatters.preciseTime.string(from: fetchedAt), mono: true)
                ForEach(Array(ServerHealthPresenter.sections(d, pinnedFingerprint: devices.record?.serverFingerprint).enumerated()), id: \.offset) { _, section in
                    HealthSectionCard(section: section)
                }
                SentinelCard {
                    SectionLabel(text: "Share (optional, separate step)")
                    Explanation("Reading these diagnostics sends nothing anywhere, and being able to read them does not allow Sentinel to transmit them. To share a redacted copy you review the exact report, check the destination's key and confirm; nothing is sent before that.")
                    Button(action: { share = true }) { Label("Share with paired device…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
                }
                .sheet(isPresented: $share) {
                    ShareReviewSheet(title: "HCG Server health — \(devices.record?.serverName ?? "HCG Server")") { origin, redaction in
                        SentinelReportSharing.report(from: d, serverName: devices.record?.serverName ?? "HCG Server", installationId: origin.installationId,
                                                     appVersion: origin.appVersion, deviceName: origin.deviceName, redaction: redaction)
                    }
                    .environmentObject(devices)
                }
            }
            Button(action: { devices.loadHealth() }) { Label("Read again", systemImage: "arrow.clockwise") }
                .buttonStyle(SentinelButtonStyle(kind: .secondary))
                .disabled(devices.health == .loading)
        }
        .navigationBarTitle("HCG Server health", displayMode: .inline)
        .onAppear { devices.loadHealth() }
    }
}

private struct HealthSectionCard: View {
    let section: ServerHealthPresenter.Section

    var body: some View {
        SentinelCard {
            SectionLabel(text: section.title)
            if section.rows.isEmpty, let empty = section.empty { Explanation(empty) }
            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                if row.label.isEmpty {
                    Text(verbatim: row.value).font(.footnote).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.label).font(.caption).foregroundColor(Theme.textSecondary)
                        Text(verbatim: row.value)
                            .font(row.mono ? Theme.mono(.footnote) : .footnote)
                            .foregroundColor(color(row.tone))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func color(_ tone: ServerHealthPresenter.Tone) -> Color {
        switch tone {
        case .ok: return Theme.ok
        case .warning: return Theme.warning
        case .danger: return Theme.danger
        case .neutral: return Theme.textPrimary
        }
    }
}
