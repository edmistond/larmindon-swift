import CoreGraphics
import XCTest
@testable import LarmindonKit

final class CaptureBandLayoutTests: XCTestCase {
    func testPortraitPhoneStacksLabelAboveChip() {
        let layout = CaptureBandLayout.resolved(for: CGSize(width: 402, height: 780), bottomSafeAreaInset: 34)
        XCTAssertEqual(layout.arrangement, .stacked)
        XCTAssertEqual(layout.discRadius, 108)
    }

    func testLandscapePhoneUsesRowAndSmallerDiscs() {
        let layout = CaptureBandLayout.resolved(for: CGSize(width: 852, height: 372), bottomSafeAreaInset: 21)
        XCTAssertEqual(layout.arrangement, .row)
        XCTAssertEqual(layout.discRadius, 84)
    }

    func testLargeLandscapeKeepsFullSizeDiscs() {
        let layout = CaptureBandLayout.resolved(for: CGSize(width: 1024, height: 748), bottomSafeAreaInset: 20)
        XCTAssertEqual(layout.arrangement, .row)
        XCTAssertEqual(layout.discRadius, 108)
    }

    func testBandIsTallEnoughThatCornerControlsStayInsideIt() {
        let layout = CaptureBandLayout.resolved(for: CGSize(width: 402, height: 780), bottomSafeAreaInset: 34)
        let side = CornerControlMetrics(radius: layout.discRadius).frameSide
        XCTAssertEqual(layout.minimumBandHeight + 34, side)
    }

    func testBandHeightNeverGoesNegative() {
        let layout = CaptureBandLayout.resolved(for: CGSize(width: 402, height: 780), bottomSafeAreaInset: 500)
        XCTAssertEqual(layout.minimumBandHeight, 0)
    }

    func testOnlyStoppedStatusDrawsNoRing() {
        XCTAssertEqual(CaptureStatusAppearance(.stopped).ring, .none)
        XCTAssertEqual(CaptureStatusAppearance(.noAudio).ring, .dashed)
        XCTAssertEqual(CaptureStatusAppearance(.listening).ring, .thin)
        XCTAssertEqual(CaptureStatusAppearance(.captioning).ring, .thick)
        XCTAssertTrue(CaptureStatusAppearance(.stalled).showsBadge)
        XCTAssertFalse(CaptureStatusAppearance(.captioning).showsBadge)
    }
}
