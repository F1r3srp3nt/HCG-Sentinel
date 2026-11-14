import SentinelCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var router: Router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isCompact: Bool { sizeClass != .regular }

    var body: some View {
        Group {
            if isCompact {
                CompactLayout()
            } else {
                RegularLayout()
            }
        }
        .environment(\.sentinelMotion, app.settings.animationsEnabled && !reduceMotion)
        .accentColor(Theme.cyan)
        .preferredColorScheme(.dark)
        .onAppear { router.layoutChanged(compact: isCompact) }
        .onChange(of: isCompact) { router.layoutChanged(compact: $0) }
        .sheet(item: $router.sheet) { section in
            NavContainer {
                SectionContent(section: section)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") { router.sheet = nil }
                        }
                    }
            }
            .modifier(ModelInjection(app: app, router: router))
            .environment(\.sentinelMotion, app.settings.animationsEnabled && !reduceMotion)
            .accentColor(Theme.cyan)
            .preferredColorScheme(.dark)
        }
        .alert(item: $app.stopReportItem) { item in
            Alert(title: Text("Stop All Operations"), message: Text(item.text), dismissButton: .default(Text("OK")))
        }
    }
}

struct StopReportItem: Identifiable {
    let text: String
    var id: String { text }
}

extension AppModel {
    var stopReportItem: StopReportItem? {
        get { stopReport.map(StopReportItem.init(text:)) }
        set { stopReport = newValue?.text }
    }
}

/// The screen for one section, without any navigation container.
struct SectionContent: View {
    let section: SentinelSection

    var body: some View {
        switch section {
        case .dashboard: DashboardView()
        case .network: NetworkInspectorView()
        case .networkCheck: NetworkCheckView()
        case .securityLab: SecurityLabView()
        case .bluetooth: BluetoothExplorerView()
        case .radio: RadioLabView()
        case .requests: RequestComposerView()
        case .capabilities: CapabilitiesView()
        case .settings: SettingsView()
        }
    }
}

/// iPhone and narrow iPad windows: one tab per tool.
private struct CompactLayout: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        TabView(selection: $router.section) {
            ForEach(Router.tabSections) { section in
                NavContainer { SectionContent(section: section) }
                    .tabItem {
                        Image(systemName: section.icon)
                        Text(section.shortTitle)
                    }
                    .tag(section)
            }
        }
    }
}

/// Full-width iPad: persistent sidebar beside the selected tool.
private struct RegularLayout: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var router: Router

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 270)
                .background(Theme.obsidianRaised.ignoresSafeArea())
            Rectangle().fill(Theme.metalEdge).frame(width: 1).ignoresSafeArea()
            NavContainer { SectionContent(section: router.section) }
                .id(router.section)
        }
        .background(Theme.obsidian.ignoresSafeArea())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 6) {
                Image("SentinelHeader")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 64)
                    .accessibilityLabel("HCG Sentinel")
                    .accessibilityAddTraits(.isHeader)
                SweepLine()
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)

            ForEach(SentinelSection.allCases) { section in
                Button(action: { router.open(section) }) {
                    HStack(spacing: 12) {
                        Image(systemName: section.icon).frame(width: 24)
                        Text(section.title).font(.body)
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(router.section == section ? Theme.cyan : Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 46)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(router.section == section ? Theme.cyan.opacity(0.12) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal, 8)
                .accessibilityAddTraits(router.section == section ? .isSelected : [])
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 8) {
                if app.settings.previewMode { StatusPill(text: "Preview mode", tone: .accent) }
                Text(app.activeOperations.isEmpty ? "Nothing running" : "\(app.activeOperations.count) operation(s) running")
                    .font(.footnote)
                    .foregroundColor(Theme.textSecondary)
                Button(action: { app.stopAllOperations() }) {
                    Label("Stop All Operations", systemImage: "stop.circle.fill")
                }
                .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
            }
            .padding(12)
        }
    }
}
