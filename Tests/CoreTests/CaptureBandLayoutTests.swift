import CoreGraphics
import XCTest
@testable import LarmindonKit

final class CaptureBandLayoutTests: XCTestCase {
    func testPortraitPhoneStacksLabelAboveChip() {
        let layout = CaptureBandLayout.resolved(for: CGSize(width: 402, height: 780), bottomSafeAreaInset: 34)
        XCTAssertEqual(layout.arrangement, .stacked)
        XCTAssertEqual(layout.corner.radius, 60)
    }

    func testLandscapePhoneUsesRowAndSmallerDiscs() {
        let layout = CaptureBandLayout.resolved(for: CGSize(width: 852, height: 372), bottomSafeAreaInset: 21)
        XCTAssertEqual(layout.arrangement, .row)
        XCTAssertEqual(layout.corner.radius, 48)
    }

    func testLargeLandscapeKeepsFullSizeDiscs() {
        let layout = CaptureBandLayout.resolved(for: CGSize(width: 1024, height: 748), bottomSafeAreaInset: 20)
        XCTAssertEqual(layout.arrangement, .row)
        XCTAssertEqual(layout.corner.radius, 60)
    }

    func testBandIsTallEnoughThatCornerControlsStayInsideIt() {
        let layout = CaptureBandLayout.resolved(for: CGSize(width: 402, height: 780), bottomSafeAreaInset: 34)
        XCTAssertEqual(layout.minimumBandHeight + 34, layout.corner.frameSize.height)
    }

    func testBandHeightNeverGoesNegative() {
        let layout = CaptureBandLayout.resolved(for: CGSize(width: 402, height: 780), bottomSafeAreaInset: 500)
        XCTAssertEqual(layout.minimumBandHeight, 0)
    }

    func testCornerCircleReachesPastBothScreenEdges() {
        let corner = CaptureBandLayout.resolved(for: CGSize(width: 402, height: 780), bottomSafeAreaInset: 34).corner
        XCTAssertGreaterThan(corner.radius, corner.center.x)
        XCTAssertGreaterThan(corner.radius, corner.center.y)
    }

    func testChipAndLabelClearTheCornerRings() {
        let layout = CaptureBandLayout.resolved(for: CGSize(width: 402, height: 780), bottomSafeAreaInset: 34)
        let ringOuter = layout.corner.radius + CornerControlMetrics.ringAllowance
        XCTAssertGreaterThan(layout.chipInset, layout.corner.center.x)
        XCTAssertLessThanOrEqual(layout.chipInset, layout.corner.center.x + ringOuter + CaptureBandLayout.contentGap)
        XCTAssertLessThan(layout.labelInset, layout.chipInset)
        // Leaves the chip a usable width on a 402 pt phone.
        XCTAssertGreaterThan(402 - 2 * layout.chipInset, 150)
    }

    func testReachIsZeroAboveTheRing() {
        let corner = CornerControlMetrics(radius: 60, center: CGPoint(x: 42, y: 44))
        XCTAssertEqual(corner.reach(atHeight: 44 + 60 + CornerControlMetrics.ringAllowance + 1), 0)
        XCTAssertEqual(corner.reach(atHeight: 44), 42 + 60 + CornerControlMetrics.ringAllowance)
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
