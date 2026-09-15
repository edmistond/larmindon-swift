import SwiftUI
import XCTest
@testable import LarmindonKit

final class CaptionScrollStateTests: XCTestCase {
    func testShortTranscriptNeverRequestsBottomAlignment() {
        var state = CaptionScrollState()
        for height in [48.0, 90, 240, 599, 600, 600.5] {
            state.updateGeometry(geometry(height: height))
            XCTAssertNil(state.request(isEmpty: false))
            XCTAssertTrue(state.isPinnedToBottom)
        }

        // Correct an unwanted downward shift, including after a long tail shrinks.
        state.updateGeometry(geometry(height: 240, offset: -113))
        XCTAssertEqual(state.request(isEmpty: false)?.target, .top)
    }

    func testOverflowUsesActualViewportAfterInsets() {
        var state = CaptionScrollState()
        state.updateGeometry(geometry(height: 480, offset: -80, top: 80, bottom: 40))
        XCTAssertNil(state.request(isEmpty: false))
        state.updateGeometry(geometry(height: 482, offset: -80, top: 80, bottom: 40))
        XCTAssertEqual(state.request(isEmpty: false)?.target, .bottom)
        state.updateGeometry(geometry(height: 482, offset: -78, top: 80, bottom: 40))
        XCTAssertNil(state.request(isEmpty: false))
    }

    func testGrowthPastViewportFollowsWithoutLosingPin() {
        var state = CaptionScrollState()
        state.updateGeometry(geometry(height: 580))
        XCTAssertNil(state.request(isEmpty: false))
        state.updateGeometry(geometry(height: 720))
        XCTAssertEqual(state.request(isEmpty: false)?.target, .bottom)
        state.updateGeometry(geometry(height: 720, offset: 120))
        XCTAssertNil(state.request(isEmpty: false))
        state.updateGeometry(geometry(height: 900, offset: 120))
        XCTAssertTrue(state.isPinnedToBottom)
        XCTAssertEqual(state.request(isEmpty: false)?.target, .bottom)
    }

    func testLayoutCorrectionDoesNotLookLikeReaderScrollingUp() {
        var state = CaptionScrollState()
        state.updateGeometry(geometry(height: 1000, offset: 400))
        state.updateGeometry(geometry(height: 1200, offset: 380))
        XCTAssertTrue(state.isPinnedToBottom)
        XCTAssertEqual(state.request(isEmpty: false)?.target, .bottom)
    }

    func testScrollbackSurvivesMoreTextAndResize() {
        var state = CaptionScrollState()
        state.updateGeometry(geometry(height: 1000, offset: 400))
        state.updateInteraction(isUserScrolling: true, geometry: geometry(height: 1000, offset: 400))
        state.updateGeometry(geometry(height: 1000, offset: 200))
        state.updateInteraction(isUserScrolling: false, geometry: geometry(height: 1000, offset: 200))
        XCTAssertFalse(state.isPinnedToBottom)
        XCTAssertNil(state.request(isEmpty: false))

        state.updateGeometry(geometry(height: 1400, offset: 200, viewport: 400))
        XCTAssertFalse(state.isPinnedToBottom)
        XCTAssertNil(state.request(isEmpty: false))
    }

    func testReturningNearBottomResumesAfterGestureEnds() {
        var state = CaptionScrollState()
        state.updateGeometry(geometry(height: 1000, offset: 400))
        state.updateInteraction(isUserScrolling: true, geometry: geometry(height: 1000, offset: 400))
        state.updateGeometry(geometry(height: 1000, offset: 200))
        state.updateGeometry(geometry(height: 1000, offset: 375))
        XCTAssertTrue(state.isPinnedToBottom)
        XCTAssertNil(state.request(isEmpty: false))
        state.updateInteraction(isUserScrolling: false, geometry: geometry(height: 1000, offset: 375))
        XCTAssertEqual(state.request(isEmpty: false)?.target, .bottom)
    }

    func testTouchCancelsFollowAndStationaryReleaseCatchesUp() {
        var state = CaptionScrollState()
        state.updateGeometry(geometry(height: 1000))
        XCTAssertNotNil(state.request(isEmpty: false))
        state.updateInteraction(isUserScrolling: true, geometry: geometry(height: 1000))
        XCTAssertNil(state.request(isEmpty: false))
        state.updateGeometry(geometry(height: 1200))
        XCTAssertNil(state.request(isEmpty: false))
        state.updateInteraction(isUserScrolling: false, geometry: geometry(height: 1200))
        XCTAssertEqual(state.request(isEmpty: false)?.target, .bottom)
    }

    func testResizeAndTailShrinkChooseCorrectEdge() {
        var state = CaptionScrollState()
        state.updateGeometry(geometry(height: 500))
        // A banner or landscape layout reduces the viewport.
        state.updateGeometry(geometry(height: 500, viewport: 400))
        XCTAssertEqual(state.request(isEmpty: false)?.target, .bottom)
        state.updateGeometry(geometry(height: 500, offset: 100, viewport: 400))
        XCTAssertNil(state.request(isEmpty: false))
        // Removing the banner, or finalizing a shorter tail, makes everything fit.
        state.updateGeometry(geometry(height: 500, offset: 100))
        XCTAssertEqual(state.request(isEmpty: false)?.target, .top)
        state.updateGeometry(geometry(height: 300, offset: 100))
        XCTAssertEqual(state.request(isEmpty: false)?.target, .top)
    }

    func testClearReplacesPendingBottomRequestAndRepinsScrollback() {
        var state = CaptionScrollState()
        state.updateGeometry(geometry(height: 1000, offset: 100))
        let pending = state.request(isEmpty: false)
        XCTAssertEqual(pending?.target, .bottom)
        XCTAssertEqual(state.request(isEmpty: true)?.target, .top)
        XCTAssertNotEqual(pending, state.request(isEmpty: true))

        state.updateInteraction(isUserScrolling: true, geometry: geometry(height: 1000, offset: 50))
        state.updateInteraction(isUserScrolling: false, geometry: geometry(height: 1000, offset: 50))
        XCTAssertFalse(state.isPinnedToBottom)
        state.reset()
        XCTAssertTrue(state.isPinnedToBottom)
        state.updateGeometry(geometry(height: 48))
        XCTAssertNil(state.request(isEmpty: true))
        state.updateGeometry(geometry(height: 800))
        XCTAssertEqual(state.request(isEmpty: false)?.target, .bottom)
    }

    func testNewLayoutReplacesPendingRequestAndSettledLayoutStopsRequesting() {
        var state = CaptionScrollState()
        state.updateGeometry(geometry(height: 800))
        let first = state.request(isEmpty: false)
        state.updateGeometry(geometry(height: 900))
        XCTAssertNotEqual(first, state.request(isEmpty: false))
        let latest = state.request(isEmpty: false)
        state.updateGeometry(geometry(height: 900))
        XCTAssertEqual(latest, state.request(isEmpty: false))
        state.updateGeometry(geometry(height: 900, offset: 300))
        XCTAssertNil(state.request(isEmpty: false))
    }

    func testNoScrollBeforeViewportIsMeasured() {
        var state = CaptionScrollState()
        XCTAssertNil(state.request(isEmpty: false))
        state.updateGeometry(geometry(height: 800, viewport: 0))
        XCTAssertNil(state.request(isEmpty: false))
    }

    private func geometry(
        height: CGFloat,
        offset: CGFloat = 0,
        viewport: CGFloat = 600,
        top: CGFloat = 0,
        bottom: CGFloat = 0
    ) -> CaptionScrollGeometry {
        CaptionScrollGeometry(ScrollGeometry(
            contentOffset: CGPoint(x: 0, y: offset),
            contentSize: CGSize(width: 430, height: height),
            contentInsets: EdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 0),
            containerSize: CGSize(width: 430, height: viewport)
        ))
    }
}
