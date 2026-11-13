import SwiftUI

/// HCG Sentinel visual identity: obsidian surfaces, brushed-metal edges,
/// precise cyan illumination and restrained violet highlights.
enum Theme {
    /// Pure black, matching the SentinelHeader banner.
    static let obsidian = Color.black
    static let obsidianRaised = Color(red: 0.035, green: 0.040, blue: 0.050)
    static let panel = Color(red: 0.065, green: 0.072, blue: 0.088)
    static let panelInset = Color(red: 0.030, green: 0.034, blue: 0.042)
    static let hairline = Color.white.opacity(0.10)

    static let cyan = Color(red: 0.25, green: 0.87, blue: 0.96)
    static let violet = Color(red: 0.66, green: 0.57, blue: 0.99)
    static let metalLight = Color(red: 0.80, green: 0.82, blue: 0.86)
    static let metalDark = Color(red: 0.30, green: 0.32, blue: 0.37)

    static let textPrimary = Color(red: 0.94, green: 0.96, blue: 0.98)
    static let textSecondary = Color(red: 0.70, green: 0.74, blue: 0.80)
    static let ok = Color(red: 0.45, green: 0.90, blue: 0.64)
    static let warning = Color(red: 0.99, green: 0.78, blue: 0.36)
    static let danger = Color(red: 1.00, green: 0.50, blue: 0.50)

    /// Brushed-metal edge used on card borders and dividers.
    static let metalEdge = LinearGradient(
        gradient: Gradient(colors: [metalLight.opacity(0.55), metalDark.opacity(0.35), metalLight.opacity(0.18), metalDark.opacity(0.45)]),
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let backdrop = Color.black

    static func mono(_ style: Font.TextStyle = .footnote) -> Font {
        Font.system(style, design: .monospaced)
    }

    static let cornerRadius: CGFloat = 14
}

// MARK: - Motion

private struct SentinelMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True only when the user's animation setting is on and Reduce Motion is off.
    var sentinelMotion: Bool {
        get { self[SentinelMotionKey.self] }
        set { self[SentinelMotionKey.self] = newValue }
    }
}

// MARK: - Tone

enum Tone {
    case verified, ready, off, warning, danger, info, accent

    var color: Color {
        switch self {
        case .verified: return Theme.ok
        case .ready: return Theme.cyan
        case .off: return Theme.textSecondary
        case .warning: return Theme.warning
        case .danger: return Theme.danger
        case .info: return Theme.metalLight
        case .accent: return Theme.violet
        }
    }
}

// MARK: - Building blocks

struct SentinelCard<Content: View>: View {
    var highlight: Color?
    let content: Content

    init(highlight: Color? = nil, @ViewBuilder content: () -> Content) {
        self.highlight = highlight
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Theme.panel))
            .overlay(shape.strokeBorder(Theme.metalEdge, lineWidth: 1))
            .overlay(shape.strokeBorder((highlight ?? Color.clear).opacity(0.55), lineWidth: 1))
    }
}

struct SectionLabel: View {
    let text: String
    var tone: Tone = .ready

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(tone.color).frame(width: 14, height: 2)
            Text(text.uppercased())
                .font(.system(.caption, design: .default).weight(.semibold))
                .kerning(1.2)
                .foregroundColor(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct StatusPill: View {
    let text: String
    let tone: Tone

    var body: some View {
        Text(text.uppercased())
            .font(.system(.caption2, design: .default).weight(.bold))
            .kerning(0.6)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundColor(tone.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tone.color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tone.color.opacity(0.55), lineWidth: 1))
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var mono = false
    @Environment(\.sizeCategory) private var sizeCategory

    var body: some View {
        Group {
            if sizeCategory.isAccessibilityCategory {
                VStack(alignment: .leading, spacing: 2) {
                    labelText
                    valueText.multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    labelText.layoutPriority(1)
                    Spacer(minLength: 8)
                    valueText.multilineTextAlignment(.trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var labelText: some View {
        Text(label)
            .font(.subheadline)
            .foregroundColor(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var valueText: some View {
        Text(value)
            .font(mono ? Theme.mono(.subheadline) : .subheadline)
            .foregroundColor(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A horizontal row at normal text sizes that becomes a vertical stack at accessibility sizes, so a title and a
/// trailing badge never overlap or squeeze each other.
struct AdaptiveStack<Content: View>: View {
    var spacing: CGFloat = 8
    let content: Content
    @Environment(\.sizeCategory) private var sizeCategory

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if sizeCategory.isAccessibilityCategory {
            VStack(alignment: .leading, spacing: spacing) { content }
        } else {
            HStack(alignment: .center, spacing: spacing) { content }
        }
    }
}

struct Explanation: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundColor(Theme.metalLight)
            Text(title)
                .font(.headline)
                .foregroundColor(Theme.textPrimary)
            Text(message)
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

/// Shown wherever demonstration data is on screen.
struct PreviewBanner: View {
    var detail = "Everything below is fabricated sample data. Nothing was scanned, captured or received."

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "theatermasks.fill")
                .foregroundColor(Theme.violet)
            VStack(alignment: .leading, spacing: 2) {
                Text("PREVIEW MODE — DEMONSTRATION DATA")
                    .font(.system(.caption, design: .default).weight(.bold))
                    .kerning(0.8)
                    .foregroundColor(Theme.violet)
                Text(detail)
                    .font(.footnote)
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.violet.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.violet.opacity(0.7), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct NoticeBanner: View {
    let icon: String
    let text: String
    var tone: Tone = .info

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(tone.color)
            Text(text)
                .font(.footnote)
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tone.color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tone.color.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct SentinelButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .primary
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        let color: Color = kind == .primary ? Theme.cyan : kind == .destructive ? Theme.danger : Theme.metalLight
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return configuration.label
            .font(.system(.subheadline, design: .default).weight(.semibold))
            .foregroundColor(kind == .primary ? Theme.obsidian : color)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
            .background(shape.fill(kind == .primary ? color : color.opacity(0.10)))
            .overlay(shape.strokeBorder(color.opacity(kind == .primary ? 0 : 0.6), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(shape)
    }
}

/// Small status light. Pulses only when motion is allowed and `active` is true.
struct PulseDot: View {
    let color: Color
    let active: Bool
    @Environment(\.sentinelMotion) private var motion
    @State private var expanded = false

    var body: some View {
        ZStack {
            if active && motion {
                Circle()
                    .stroke(color.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 10, height: 10)
                    .scaleEffect(expanded ? 2.2 : 1)
                    .opacity(expanded ? 0 : 0.9)
                    .onAppear {
                        withAnimation(Animation.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { expanded = true }
                    }
                    .onDisappear { expanded = false }
            }
            Circle().fill(color).frame(width: 10, height: 10)
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// A thin line of cyan light that travels across a surface. Static when motion is off.
struct SweepLine: View {
    @Environment(\.sentinelMotion) private var motion
    @State private var travelled = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.hairline)
                Rectangle()
                    .fill(LinearGradient(gradient: Gradient(colors: [Theme.cyan.opacity(0), Theme.cyan, Theme.cyan.opacity(0)]),
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * 0.35)
                    .offset(x: motion ? (travelled ? proxy.size.width * 0.65 : 0) : proxy.size.width * 0.325)
            }
        }
        .frame(height: 2)
        .clipped()
        .onAppear { start() }
        .onChange(of: motion) { _ in start() }
        .accessibilityHidden(true)
    }

    private func start() {
        travelled = false
        guard motion else { return }
        withAnimation(Animation.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { travelled = true }
    }
}

/// Standard scrolling screen with a black background and a readable maximum width.
struct Screen<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            Theme.backdrop.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        content
                        Color.clear.frame(height: 1).id(Screen.endAnchor)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .onAppear {
                    #if DEBUG
                    // Screenshot checks in CI launch with -SentinelScrollToEnd to capture the scrolled state.
                    if ProcessInfo.processInfo.arguments.contains("-SentinelScrollToEnd") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { proxy.scrollTo(Screen.endAnchor, anchor: .bottom) }
                    }
                    #endif
                }
            }
        }
        .modifier(OpaqueBars())
    }

    // Generic types cannot have static stored properties.
    static var endAnchor: String { "sentinel.screen.end" }
}

/// Opaque black navigation and tab bars, so scrolled content never shows through behind titles. iOS 14 and 15
/// get the same result from the UIKit appearance set at launch.
struct OpaqueBars: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .toolbarBackground(Theme.obsidian, for: .navigationBar, .tabBar)
                .toolbarBackground(.visible, for: .navigationBar, .tabBar)
                .toolbarColorScheme(.dark, for: .navigationBar, .tabBar)
        } else {
            content
        }
    }
}

/// Navigation container that uses NavigationStack where available and a
/// stack-style NavigationView on iOS 14 and 15.
struct NavContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content }
        } else {
            NavigationView { content }
                .navigationViewStyle(StackNavigationViewStyle())
        }
    }
}

/// Labelled toggle with a plain-language description of what it changes.
struct SettingToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isOn) {
                Text(title)
                    .font(.body)
                    .foregroundColor(Theme.textPrimary)
            }
            .toggleStyle(SwitchToggleStyle(tint: Theme.cyan))
            Explanation(detail)
        }
    }
}

private struct SentinelFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.mono(.subheadline))
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.panelInset))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

extension View {
    /// Inset, monospaced styling for text inputs.
    func sentinelField() -> some View {
        modifier(SentinelFieldModifier())
    }

    /// Text input tuned for addresses and protocol text: no autocorrection or capitalisation.
    func technicalInput() -> some View {
        self.autocapitalization(.none).disableAutocorrection(true)
    }
}
