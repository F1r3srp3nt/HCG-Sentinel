import SwiftUI
import UIKit

/// The HCG brand lockup used across HCG products: the chrome HCG mark, a thin divider, and the product name in widely
/// spaced capitals. Metrics are HCG Store's navigation header (`.brand` in web-hcg-store/src/styles/layout.css),
/// multiplied by one `scale`, so the proportions always match Store's.
struct HCGLockup: View {
    // Store's values in CSS pixels; one point here per pixel there at scale 1.
    static let markWidth: CGFloat = 88
    static let markAspect: CGFloat = 240.0 / 109.0          // the mark's own pixel size, 240×109 (and 480×218)
    static let gap: CGFloat = 10
    static let dividerHeight: CGFloat = 15 * 1.6            // one 15 px line at Store's body line-height of 1.6
    static let wordPadding: CGFloat = 12
    static let fontSize: CGFloat = 15
    static let letterSpacing: CGFloat = 0.32                // em
    /// Width of the whole lockup with "SENTINEL" at scale 1, measured from the bundled font's advance widths.
    static let baseWidth: CGFloat = 216

    static let fontName = "SpaceGrotesk-SemiBold"
    static let wordColor = Color(red: 0xF4 / 255, green: 0xF6 / 255, blue: 0xF9 / 255)        // Store --text
    static let dividerColor = Color(red: 206 / 255, green: 220 / 255, blue: 236 / 255).opacity(0.15) // --line-strong

    var word = "SENTINEL"
    var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: HCGLockup.gap * scale) {
            HCGMark(width: HCGLockup.markWidth * scale)
            HStack(spacing: 0) {
                Rectangle()
                    .fill(HCGLockup.dividerColor)
                    .frame(width: 1, height: HCGLockup.dividerHeight * scale)
                Text(word)
                    // A brand mark: fixed size, so it keeps Store's proportions at every text size. The status line
                    // under it follows Dynamic Type.
                    .font(.custom(HCGLockup.fontName, fixedSize: HCGLockup.fontSize * scale))
                    .kerning(HCGLockup.letterSpacing * HCGLockup.fontSize * scale)
                    .foregroundColor(HCGLockup.wordColor)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, HCGLockup.wordPadding * scale)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("HCG \(word.capitalized)")
        .accessibilityAddTraits(.isHeader)
    }
}

/// The chrome HCG mark, loaded from the original WebP files copied from HCG Store (bundled, so it works offline).
/// Transparency and the 240:109 aspect ratio are preserved; the smaller file is used when it is sharp enough.
struct HCGMark: View {
    let width: CGFloat
    @Environment(\.displayScale) private var displayScale

    private static let small = load("hcg-mark-240")
    private static let large = load("hcg-mark-480")

    private static func load(_ name: String) -> UIImage? {
        Bundle.main.url(forResource: name, withExtension: "webp").flatMap { UIImage(contentsOfFile: $0.path) }
    }

    var body: some View {
        let height = width / HCGLockup.markAspect
        let image = width * displayScale <= 240 ? (HCGMark.small ?? HCGMark.large) : (HCGMark.large ?? HCGMark.small)
        return Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // Only if the bundled file is missing: never substitute a different logo.
                Text("HCG")
                    .font(.custom(HCGLockup.fontName, fixedSize: height * 0.6))
                    .foregroundColor(HCGLockup.wordColor)
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

/// Fits the lockup to the available width: Store's size times up to `maxScale`, never wider than the space it has,
/// so it fits the smallest iPhones (320 points) and does not overflow at large text sizes.
struct ScaledHCGLockup: View {
    var word = "SENTINEL"
    var maxScale: CGFloat = 1.5
    var alignment: Alignment = .leading
    @State private var available: CGFloat = 0

    private var scale: CGFloat {
        guard available > 0 else { return 1 }
        return max(0.6, min(maxScale, available / (HCGLockup.baseWidth * 1.04)))
    }

    var body: some View {
        HCGLockup(word: word, scale: scale)
            .frame(maxWidth: .infinity, alignment: alignment)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: AvailableWidthKey.self, value: proxy.size.width)
            })
            .onPreferenceChange(AvailableWidthKey.self) { width in
                if abs(width - available) > 0.5 { available = width }
            }
    }
}

private struct AvailableWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
