import SentinelCore
import SwiftUI

struct NetworkInspectorView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var network: NetworkModel
    @EnvironmentObject private var connection: ConnectionMonitor
    @State private var showPicker = false
    @State private var pendingDelete: StoredCapture?

    var body: some View {
        Screen {
            if network.previewMode { PreviewBanner() }
            SectionLabel(text: "This app’s connection")
            NavigationLink(destination: NetworkCheckView()) {
                SentinelCard(highlight: Theme.cyan) {
                    AdaptiveStack {
                        Image(systemName: "checkmark.shield").foregroundColor(Theme.cyan)
                        Text("Check My Network")
                            .font(.headline)
                            .foregroundColor(Theme.textPrimary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundColor(Theme.textSecondary)
                    }
                    Explanation("Run bounded DNS, HTTPS, captive-portal and proxy checks on the current connection, with evidence for each finding.")
                }
            }
            .buttonStyle(PlainButtonStyle())
            connectionCard
            SectionLabel(text: "Capture files")
            NoticeBanner(icon: "doc.text.magnifyingglass",
                         text: "Sentinel inspects capture files recorded elsewhere. It has no verified live-capture backend, so it does not capture this device’s traffic and cannot decrypt HTTPS.")
            importCard
            savedCard
            NavigationLink(destination: captureDestination, isActive: captureIsOpen) { EmptyView() }
                .hidden()
        }
        .navigationBarTitle("Network Inspector", displayMode: .inline)
        .sheet(isPresented: $showPicker) {
            DocumentPicker { url in network.importFile(at: url) }
                .ignoresSafeArea()
        }
        .alert(item: $pendingDelete) { item in
            Alert(title: Text("Delete this capture?"),
                  message: Text("“\(item.originalName)” will be removed from Sentinel’s storage. This cannot be undone."),
                  primaryButton: .destructive(Text("Delete")) { network.delete(item) },
                  secondaryButton: .cancel())
        }
    }

    private var captureIsOpen: Binding<Bool> {
        Binding(get: { network.open != nil }, set: { if !$0 { network.open = nil } })
    }

    @ViewBuilder private var captureDestination: some View {
        if let open = network.open {
            CaptureView(open: open)
        } else {
            EmptyView()
        }
    }

    // MARK: Connection

    private var connectionCard: some View {
        SentinelCard {
            if let snapshot = connection.snapshot {
                AdaptiveStack {
                    Text(snapshot.headline).font(.headline).foregroundColor(Theme.textPrimary)
                    Spacer()
                    StatusPill(text: snapshot.isOnline ? "Online" : "Offline", tone: snapshot.isOnline ? .verified : .warning)
                }
                InfoRow(label: "Path status", value: snapshot.statusText)
                InfoRow(label: "Interface types", value: snapshot.interfaceTypes.isEmpty ? "None" : snapshot.interfaceTypes.joined(separator: ", "))
                InfoRow(label: "IPv4 routable", value: snapshot.supportsIPv4 ? "Yes" : "No")
                InfoRow(label: "IPv6 routable", value: snapshot.supportsIPv6 ? "Yes" : "No")
                InfoRow(label: "DNS available", value: snapshot.supportsDNS ? "Yes" : "No")
                InfoRow(label: "Metered (expensive)", value: snapshot.isExpensive ? "Yes" : "No")
                InfoRow(label: "Low Data Mode", value: snapshot.isConstrained ? "Yes" : "No")
                if !snapshot.addresses.isEmpty {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    ForEach(snapshot.addresses) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.interface) · \(item.family) · \(item.interfaceHint)")
                                .font(.caption)
                                .foregroundColor(Theme.textSecondary)
                            Text(item.address)
                                .font(Theme.mono(.footnote))
                                .foregroundColor(Theme.textPrimary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                HStack {
                    Text("Updated \(Formatters.time.string(from: snapshot.updatedAt))")
                        .font(Theme.mono(.caption))
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    Button("Refresh addresses") { connection.refreshAddresses() }
                        .font(.footnote)
                }
            } else {
                Text("Waiting for iOS to report the network path…")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
            }
            Explanation("Read from iOS path monitoring and this device’s own interface list. No probes are sent and no traffic is observed.")
        }
    }

    // MARK: Import

    private var importCard: some View {
        SentinelCard {
            if network.previewMode {
                Button(action: { network.openPreview() }) {
                    Label("Open demonstration capture", systemImage: "theatermasks")
                }
                .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
                Explanation("A fabricated seven-packet capture built inside the app. Turn Preview mode off to import real files.")
            } else if network.isParsing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading capture file…").font(.subheadline).foregroundColor(Theme.textPrimary)
                    Spacer()
                    Button("Cancel") { network.cancelImport() }
                }
            } else {
                Button(action: { showPicker = true }) {
                    Label("Import pcap or pcapng file", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                Explanation("Supported: classic pcap (microsecond and nanosecond) and pcapng. Limits: \(Formatters.bytes(CaptureLimits.default.maxFileBytes)) per file and \(CaptureLimits.default.maxPackets) packets. The file is copied into Sentinel; the original is not modified.")
                Explanation(network.retention.savesImports
                            ? "Imports are saved in the app sandbox (retention: \(network.retention.title)). Change this in Settings."
                            : "Imports are inspected in memory only and not saved, as chosen in Settings.")
            }
            if let message = network.errorMessage {
                NoticeBanner(icon: "exclamationmark.triangle.fill", text: message, tone: .warning)
            }
        }
    }

    private var savedCard: some View {
        SentinelCard {
            AdaptiveStack {
                Text("Saved captures").font(.headline).foregroundColor(Theme.textPrimary)
                Spacer()
                Text(network.saved.isEmpty ? "None" : "\(network.saved.count) · \(Formatters.bytes(network.savedByteCount))")
                    .font(Theme.mono(.caption))
                    .foregroundColor(Theme.textSecondary)
            }
            if network.saved.isEmpty {
                Explanation("Nothing is stored. Imported captures appear here when retention is enabled.")
            } else {
                ForEach(network.saved) { item in
                    HStack(spacing: 10) {
                        Button(action: { network.openSaved(item) }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.originalName)
                                    .font(.subheadline)
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(2)
                                Text("\(item.format.displayName) · \(item.packetCount) packets · \(Formatters.bytes(item.byteCount)) · imported \(Formatters.dateTime.string(from: item.importedAt))")
                                    .font(.caption)
                                    .foregroundColor(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(network.previewMode || network.isParsing)
                        Button(action: { pendingDelete = item }) {
                            Image(systemName: "trash").foregroundColor(Theme.danger).frame(width: 44, height: 44)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel("Delete \(item.originalName)")
                    }
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                Explanation("Delete everything at once from Settings › Capture retention.")
            }
        }
    }
}

// MARK: - Capture

struct CaptureView: View {
    let open: OpenCapture
    @State private var filter = ""
    @State private var visibleCount = 300

    private var packets: [CapturedPacket] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return open.capture.packets }
        return open.capture.packets.filter { packet in
            let summary = packet.summary
            return summary.protocolName.lowercased().contains(needle)
                || summary.sourceEndpoint.lowercased().contains(needle)
                || summary.destinationEndpoint.lowercased().contains(needle)
                || (summary.serviceHint?.lowercased().contains(needle) ?? false)
                || summary.info.lowercased().contains(needle)
        }
    }

    var body: some View {
        let matching = packets
        return Screen {
            sourceBanner
            summaryCard
            if !open.capture.warnings.isEmpty { warningsCard }
            TextField("Filter by address, port, protocol or text", text: $filter)
                .technicalInput()
                .sentinelField()
            Text("\(matching.count) of \(open.capture.packets.count) packets")
                .font(Theme.mono(.caption))
                .foregroundColor(Theme.textSecondary)
            LazyVStack(spacing: 8) {
                ForEach(matching.prefix(visibleCount)) { packet in
                    NavigationLink(destination: PacketDetailView(open: open, packet: packet)) {
                        PacketRow(packet: packet)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            if matching.count > visibleCount {
                Button("Show 300 more (\(matching.count - visibleCount) remaining)") { visibleCount += 300 }
                    .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
            }
            if matching.isEmpty {
                EmptyState(icon: "line.horizontal.3.decrease.circle", title: "No packets match",
                           message: open.capture.packets.isEmpty ? "The file contains no readable packets." : "Clear the filter to see every packet.")
            }
        }
        .navigationBarTitle(Text(open.name), displayMode: .inline)
    }

    @ViewBuilder private var sourceBanner: some View {
        switch open.source {
        case .preview:
            PreviewBanner(detail: "Fabricated capture using documentation-only addresses. These packets never existed on any network.")
        case .importedFile:
            NoticeBanner(icon: "doc.fill", text: "IMPORTED FILE — recorded elsewhere and opened for inspection. This is not a live capture.", tone: .ready)
        }
    }

    private var summaryCard: some View {
        SentinelCard {
            InfoRow(label: "Format", value: open.capture.format.displayName)
            InfoRow(label: "Link type", value: open.capture.linkTypes.map { LinkType.name($0) }.joined(separator: ", "))
            InfoRow(label: "Packets", value: "\(open.capture.packets.count)")
            InfoRow(label: "File size", value: Formatters.bytes(open.capture.data.count))
            if let span = open.capture.timeSpan {
                InfoRow(label: "First packet", value: Formatters.preciseTime.string(from: span.first), mono: true)
                InfoRow(label: "Last packet", value: Formatters.preciseTime.string(from: span.last), mono: true)
            }
            InfoRow(label: "Stored in Sentinel", value: open.stored == nil ? "No (in memory only)" : "Yes")
            Explanation("Timestamps are the values recorded in the file, shown in this device’s time zone.")
        }
    }

    private var warningsCard: some View {
        SentinelCard(highlight: Theme.warning) {
            SectionLabel(text: open.capture.stoppedEarly ? "Parsing stopped early" : "Parser notes", tone: .warning)
            ForEach(Array(open.capture.warnings.prefix(12).enumerated()), id: \.offset) { item in
                Text(item.element)
                    .font(.footnote)
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if open.capture.warnings.count > 12 {
                Explanation("\(open.capture.warnings.count - 12) further notes not shown.")
            }
        }
    }
}

private struct PacketRow: View {
    let packet: CapturedPacket

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AdaptiveStack(spacing: 8) {
                Text("#\(packet.id)")
                    .font(Theme.mono(.caption))
                    .foregroundColor(Theme.textSecondary)
                Text(packet.summary.protocolName)
                    .font(.system(.caption, design: .default).weight(.bold))
                    .foregroundColor(Theme.cyan)
                if let hint = packet.summary.serviceHint {
                    Text("port hint: \(hint)")
                        .font(.caption2)
                        .foregroundColor(Theme.violet)
                }
                Spacer(minLength: 4)
                Text(packet.timestamp.map { Formatters.preciseTime.string(from: $0).suffix(12).description } ?? "no timestamp")
                    .font(Theme.mono(.caption))
                    .foregroundColor(Theme.textSecondary)
            }
            Text("\(packet.summary.sourceEndpoint)  →  \(packet.summary.destinationEndpoint)")
                .font(Theme.mono(.footnote))
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(packet.summary.info.isEmpty ? "—" : packet.summary.info) · \(packet.capturedLength) bytes")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct PacketDetailView: View {
    let open: OpenCapture
    let packet: CapturedPacket

    var body: some View {
        let detail = open.capture.detail(of: packet)
        let bytes = open.capture.bytes(of: packet)
        return Screen {
            if case .preview = open.source { PreviewBanner(detail: "This packet is fabricated sample data.") }
            SentinelCard {
                SectionLabel(text: "Packet \(packet.id)")
                InfoRow(label: "Timestamp", value: packet.timestamp.map { Formatters.preciseTime.string(from: $0) } ?? "Not recorded", mono: true)
                InfoRow(label: "Source", value: detail.summary.sourceEndpoint, mono: true)
                InfoRow(label: "Destination", value: detail.summary.destinationEndpoint, mono: true)
                InfoRow(label: "Protocol", value: detail.summary.protocolName)
                if let hint = detail.summary.serviceHint {
                    InfoRow(label: "Port hint", value: hint)
                    Explanation("Guessed from the port number only. The payload was not inspected.")
                }
                InfoRow(label: "Captured / on wire", value: "\(packet.capturedLength) / \(packet.originalLength) bytes")
                InfoRow(label: "Link type", value: LinkType.name(packet.linkType))
            }
            ForEach(Array(detail.notes.enumerated()), id: \.offset) { note in
                NoticeBanner(icon: "exclamationmark.triangle.fill", text: note.element, tone: .warning)
            }
            ForEach(Array(detail.layers.enumerated()), id: \.offset) { layer in
                SentinelCard {
                    SectionLabel(text: layer.element.name, tone: .info)
                    ForEach(Array(layer.element.fields.enumerated()), id: \.offset) { field in
                        InfoRow(label: field.element.label, value: field.element.value, mono: true)
                    }
                }
            }
            SentinelCard {
                SectionLabel(text: "Raw bytes", tone: .info)
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(Hex.dump(bytes, maxBytes: 2048))
                        .font(Theme.mono(.caption))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize()
                }
                Explanation("Bytes exactly as stored in the file. Encrypted payloads stay encrypted.")
            }
        }
        .navigationBarTitle("Packet \(packet.id)", displayMode: .inline)
    }
}
