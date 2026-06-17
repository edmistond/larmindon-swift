import CoreGraphics
import XCTest
@testable import LarmindonKit

final class CaptionRootLayoutTests: XCTestCase {
    func testLandscapePhoneSizeUsesCompactLandscapeLayout() {
        XCTAssertEqual(
            CaptionRootLayout.resolved(
                for: CGSize(width: 852, height: 393),
                supportsCompactLandscape: true
            ),
            .compactLandscape
        )
    }

    func testPortraitPhoneSizeUsesStandardLayout() {
        XCTAssertEqual(
            CaptionRootLayout.resolved(
                for: CGSize(width: 393, height: 852),
                supportsCompactLandscape: true
            ),
            .standard
        )
    }

    func testLargeLandscapeSizeUsesStandardLayout() {
        XCTAssertEqual(
            CaptionRootLayout.resolved(
                for: CGSize(width: 1024, height: 768),
                supportsCompactLandscape: true
            ),
            .standard
        )
    }

    func testMacWindowDoesNotUsePhoneLandscapeLayout() {
        XCTAssertEqual(
            CaptionRootLayout.resolved(
                for: CGSize(width: 852, height: 393),
                supportsCompactLandscape: false
            ),
            .standard
        )
    }

    func testTrailingControlsWidthKeepsCaptionAreaPrimary() {
        XCTAssertEqual(CaptionRootLayout.trailingControlsWidth(for: CGSize(width: 667, height: 375)), 240)
        XCTAssertEqual(
            CaptionRootLayout.trailingControlsWidth(for: CGSize(width: 852, height: 393)),
            289.68,
            accuracy: 0.001
        )
        XCTAssertEqual(CaptionRootLayout.trailingControlsWidth(for: CGSize(width: 932, height: 430)), 300)
    }
}
