import SwiftUI
import UIKit
import XCTest
#if SENTINEL_MODERN_TESTS
@testable import HCGSentinelModern
#else
@testable import HCGSentinel
#endif

/// The header's brand resources are bundled with the app and load without a network connection.
final class BrandLockupTests: XCTestCase {
    func testOriginalMarkIsBundledWithTransparencyAndAspectRatio() throws {
        for (name, size) in [("hcg-mark-240", CGSize(width: 240, height: 109)), ("hcg-mark-480", CGSize(width: 480, height: 218))] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "webp"), "\(name).webp is not in the app bundle")
            let image = try XCTUnwrap(UIImage(contentsOfFile: url.path), "\(name).webp could not be decoded")
            let cg = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(CGSize(width: cg.width, height: cg.height), size)
            XCTAssertFalse([CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo), "\(name) lost its alpha channel")
            XCTAssertEqual(Double(cg.width) / Double(cg.height), Double(HCGLockup.markAspect), accuracy: 0.01)
        }
    }

    func testDisplayFontIsRegistered() {
        let font = UIFont(name: HCGLockup.fontName, size: HCGLockup.fontSize)
        XCTAssertNotNil(font, "Space Grotesk SemiBold is not registered (UIAppFonts)")
        XCTAssertEqual(font?.familyName, "Space Grotesk")
        XCTAssertNotNil(Bundle.main.url(forResource: "SpaceGrotesk-OFL", withExtension: "txt"), "the font licence travels with the font")
    }

    func testLockupFitsTheNarrowestIPhone() {
        // 320-point screen minus 16-point margins: the word must fit at the scale ScaledHCGLockup chooses.
        let available: CGFloat = 320 - 32
        let scale = min(1.5, available / (HCGLockup.baseWidth * 1.04))
        let font = UIFont(name: HCGLockup.fontName, size: HCGLockup.fontSize * scale) ?? .systemFont(ofSize: HCGLockup.fontSize * scale, weight: .semibold)
        let word = NSAttributedString(string: "SENTINEL", attributes: [.font: font, .kern: HCGLockup.letterSpacing * HCGLockup.fontSize * scale])
        let total = HCGLockup.markWidth * scale + HCGLockup.gap * scale + 1 + HCGLockup.wordPadding * scale + word.size().width
        XCTAssertLessThanOrEqual(total, available, "lockup is \(total) points wide for \(available) available")
    }
}
