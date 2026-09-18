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
        state.updatePhase(.interacting, geometry: geometry(height: 1000, offset: 400))
        state.updateGeometry(geometry(height: 1000, offset: 200))
        state.updatePhase(.idle, geometry: geometry(height: 1000, offset: 200))
        XCTAssertFalse(state.isPinnedToBottom)
        XCTAssertNil(state.request(isEmpty: false))

        state.updateGeometry(geometry(height: 1400, offset: 200, viewport: 400))
        XCTAssertFalse(state.isPinnedToBottom)
        XCTAssertNil(state.request(isEmpty: false))
    }

    func testReturningNearBottomResumesAfterGestureEnds() {
        var state = CaptionScrollState()
        state.updateGeometry(geometry(height: 1000, offset: 400))
        state.updatePhase(.interacting, geometry: geometry(height: 1000, offset: 400))
        state.updateGeometry(geometry(height: 1000, offset: 200))
        state.updateGeometry(geometry(height: 1000, offset: 375))
        XCTAssertTrue(state.isPinnedToBottom)
        XCTAssertNil(state.request(isEmpty: false))
        state.updatePhase(.idle, geometry: geometry(height: 1000, offset: 375))
        XCTAssertEqual(state.request(isEmpty: false)?.target, .bottom)
    }

    func testTouchCancelsFollowAndStationaryReleaseCatchesUp() {
        var state = CaptionScrollState()
        state.updateGeometry(geometry(height: 1000))
        XCTAssertNotNil(state.request(isEmpty: false))
        state.updatePhase(.tracking, geometry: geometry(height: 1000))
        XCTAssertNil(state.request(isEmpty: false))
        state.updateGeometry(geometry(height: 1200))
        XCTAssertNil(state.request(isEmpty: false))
        state.updatePhase(.idle, geometry: geometry(height: 1200))
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

        state.updatePhase(.interacting, geometry: geometry(height: 1000, offset: 50))
        state.updatePhase(.idle, geometry: geometry(height: 1000, offset: 50))
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

    func testReturnToBottomSurvivesNewTextAndReboundDuringDeceleration() {
        var state = CaptionScrollState(fontSize: 38)
        state.updateGeometry(geometry(height: 1000, offset: 400))
        state.updatePhase(.interacting, geometry: geometry(height: 1000, offset: 400))
        state.updateGeometry(geometry(height: 1000, offset: 200))
        XCTAssertFalse(state.isPinnedToBottom)
        state.updateGeometry(geometry(height: 1000, offset: 400))
        XCTAssertTrue(state.isPinnedToBottom)
        state.updatePhase(.decelerating, geometry: geometry(height: 1000, offset: 450))

        // The reader released at the end. New text/reflow moves the end away while
        // the elastic overscroll settles upward, beyond even the font-aware tolerance.
        state.updateGeometry(geometry(height: 1400, offset: 420))
        state.updateGeometry(geometry(height: 1400, offset: 400))
        XCTAssertTrue(state.isPinnedToBottom)
        XCTAssertNil(state.request(isEmpty: false))
        state.updatePhase(.idle, geometry: geometry(height: 1400, offset: 400))
        XCTAssertEqual(state.request(isEmpty: false)?.target, .bottom)
        state.updateGeometry(geometry(height: 1600, offset: 400))
        XCTAssertEqual(state.request(isEmpty: false)?.target, .bottom)
    }

    func testCoastingIntoLatestTextReattachesWithoutReachingBlankPadding() {
        for fontSize in [20.0, 38, 54, 72] {
            let metrics = CaptionLayoutMetrics(fontSize: fontSize)
            var state = CaptionScrollState(fontSize: fontSize)
            state.updateGeometry(geometry(height: 2000, offset: 1400))
            state.updatePhase(.interacting, geometry: geometry(height: 2000, offset: 1400))
            state.updateGeometry(geometry(height: 2000, offset: 600))
            XCTAssertFalse(state.isPinnedToBottom)
            state.updatePhase(.decelerating, geometry: geometry(height: 2000, offset: 1000))
            // The end of the text is visible, but its trailing decoration is offscreen.
            let offset = 1400 - metrics.trailingPadding
            state.updateGeometry(geometry(height: 2000, offset: offset))
            XCTAssertTrue(state.isPinnedToBottom, "Font size \(fontSize)")
            XCTAssertNil(state.request(isEmpty: false))
            state.updatePhase(.idle, geometry: geometry(height: 2000, offset: offset))
            XCTAssertEqual(state.request(isEmpty: false)?.target, .bottom)
        }
    }

    func testOneLineSlackScalesWithFontAndHonorsInsetsAndViewport() {
        for fontSize in [20.0, 38, 72] {
            for viewport in [260.0, 600, 900] {
                let metrics = CaptionLayoutMetrics(fontSize: fontSize)
                // At bottom: contentHeight - containerHeight + bottomInset.
                let bottom = 3000 - viewport + 30
                var state = CaptionScrollState(fontSize: fontSize)
                state.updateGeometry(geometry(height: 3000, offset: bottom, viewport: viewport, top: 80, bottom: 30))
                state.updatePhase(
                    .interacting,
                    geometry: geometry(height: 3000, offset: bottom, viewport: viewport, top: 80, bottom: 30))
                state.updateGeometry(
                    geometry(height: 3000, offset: bottom - 800, viewport: viewport, top: 80, bottom: 30))
                state.updatePhase(
                    .decelerating,
                    geometry: geometry(height: 3000, offset: bottom - 800, viewport: viewport, top: 80, bottom: 30))

                let tooFar = bottom - metrics.trailingPadding - metrics.lineAdvance * 1.5
                state.updateGeometry(geometry(height: 3000, offset: tooFar, viewport: viewport, top: 80, bottom: 30))
                XCTAssertFalse(state.isPinnedToBottom)
                let nearText = bottom - metrics.trailingPadding - metrics.lineAdvance * 0.75
                state.updateGeometry(geometry(height: 3000, offset: nearText, viewport: viewport, top: 80, bottom: 30))
                XCTAssertTrue(state.isPinnedToBottom)
                state.updatePhase(
                    .idle, geometry: geometry(height: 3000, offset: nearText, viewport: viewport, top: 80, bottom: 30))
                XCTAssertEqual(state.request(isEmpty: false)?.target, .bottom)
            }
        }
    }

    func testReaderCanReverseDirectionAndDetachAgainInSameDrag() {
        var state = CaptionScrollState(fontSize: 38)
        state.updateGeometry(geometry(height: 1400, offset: 800))
        state.updatePhase(.interacting, geometry: geometry(height: 1400, offset: 800))
        state.updateGeometry(geometry(height: 1400, offset: 400))
        XCTAssertFalse(state.isPinnedToBottom)
        state.updateGeometry(geometry(height: 1400, offset: 790))
        XCTAssertTrue(state.isPinnedToBottom)
        state.updateGeometry(geometry(height: 1400, offset: 450))
        XCTAssertFalse(state.isPinnedToBottom)
        state.updatePhase(.idle, geometry: geometry(height: 1400, offset: 450))
        XCTAssertNil(state.request(isEmpty: false))
    }

    func testSlowUpwardDragStillDetaches() {
        var state = CaptionScrollState(fontSize: 38)
        state.updateGeometry(geometry(height: 1000, offset: 400))
        state.updatePhase(.tracking, geometry: geometry(height: 1000, offset: 400))
        state.updatePhase(.interacting, geometry: geometry(height: 1000, offset: 400))
        for step in 1...400 {
            state.updateGeometry(geometry(height: 1000, offset: 400 - CGFloat(step) * 0.5))
        }
        XCTAssertFalse(state.isPinnedToBottom)
        state.updatePhase(.idle, geometry: geometry(height: 1000, offset: 200))
        XCTAssertNil(state.request(isEmpty: false))
    }

    func testShortUpwardFlickCanDetachDuringItsCoast() {
        var state = CaptionScrollState(fontSize: 38)
        state.updateGeometry(geometry(height: 1400, offset: 800))
        state.updatePhase(.interacting, geometry: geometry(height: 1400, offset: 800))
        state.updateGeometry(geometry(height: 1400, offset: 780))
        XCTAssertTrue(state.isPinnedToBottom)  // Still inside the near-text region.
        state.updatePhase(.decelerating, geometry: geometry(height: 1400, offset: 775))
        state.updateGeometry(geometry(height: 1400, offset: 400))
        XCTAssertFalse(state.isPinnedToBottom)
        state.updatePhase(.idle, geometry: geometry(height: 1400, offset: 400))
        XCTAssertNil(state.request(isEmpty: false))
    }

    func testDownwardReturnAfterUpwardFlickCanReattachAndStayAttached() {
        var state = CaptionScrollState(fontSize: 38)
        state.updateGeometry(geometry(height: 1400, offset: 800))
        state.updatePhase(.interacting, geometry: geometry(height: 1400, offset: 800))
        state.updateGeometry(geometry(height: 1400, offset: 770))
        state.updatePhase(.decelerating, geometry: geometry(height: 1400, offset: 765))
        state.updateGeometry(geometry(height: 1400, offset: 400))
        state.updatePhase(.tracking, geometry: geometry(height: 1400, offset: 400))
        state.updatePhase(.interacting, geometry: geometry(height: 1400, offset: 400))
        state.updateGeometry(geometry(height: 1400, offset: 600))
        state.updatePhase(.decelerating, geometry: geometry(height: 1400, offset: 650))
        state.updateGeometry(geometry(height: 1400, offset: 755))
        XCTAssertTrue(state.isPinnedToBottom)
        state.updateGeometry(geometry(height: 1400, offset: 850))
        state.updateGeometry(geometry(height: 1800, offset: 800))
        state.updatePhase(.idle, geometry: geometry(height: 1800, offset: 800))
        XCTAssertTrue(state.isPinnedToBottom)
        XCTAssertEqual(state.request(isEmpty: false)?.target, .bottom)
    }

    func testReflowWhileFingerIsDownDoesNotDetachButSubsequentDragCan() {
        var state = CaptionScrollState(fontSize: 38)
        state.updateGeometry(geometry(height: 1000, offset: 400))
        state.updatePhase(.interacting, geometry: geometry(height: 1000, offset: 400))
        state.updateGeometry(geometry(height: 1400, offset: 300))
        XCTAssertTrue(state.isPinnedToBottom)
        state.updateGeometry(geometry(height: 1400, offset: 290))
        XCTAssertFalse(state.isPinnedToBottom)
    }

    func testFontChangeUpdatesReattachmentThreshold() {
        var state = CaptionScrollState(fontSize: 20)
        state.updateGeometry(geometry(height: 1400, offset: 800))
        state.updatePhase(.interacting, geometry: geometry(height: 1400, offset: 800))
        state.updateGeometry(geometry(height: 1400, offset: 400))
        state.updatePhase(.idle, geometry: geometry(height: 1400, offset: 400))
        let gap =
            CaptionLayoutMetrics(fontSize: 38).trailingPadding
            + CaptionLayoutMetrics(fontSize: 38).lineAdvance * 0.9
        state.updateGeometry(geometry(height: 1400, offset: 800 - gap))
        XCTAssertFalse(state.isPinnedToBottom)
        state.updateGeometry(geometry(height: 1400, offset: 800 - gap), fontSize: 38)
        XCTAssertTrue(state.isPinnedToBottom)
        XCTAssertEqual(state.request(isEmpty: false)?.target, .bottom)
    }

    func testLargerFontDoesNotReattachUsingTheOldShorterLayout() {
        var state = CaptionScrollState(fontSize: 20)
        state.updateGeometry(geometry(height: 1400, offset: 800))
        state.updatePhase(.interacting, geometry: geometry(height: 1400, offset: 800))
        state.updateGeometry(geometry(height: 1400, offset: 700))
        state.updatePhase(.idle, geometry: geometry(height: 1400, offset: 700))
        XCTAssertFalse(state.isPinnedToBottom)
        // A 72-point font would put the old 100-point gap inside its tolerance, but
        // the actual larger text is much taller and the reader is still in history.
        state.updateGeometry(geometry(height: 2400, offset: 700), fontSize: 72)
        XCTAssertFalse(state.isPinnedToBottom)
        XCTAssertNil(state.request(isEmpty: false))
    }

    private func geometry(
        height: CGFloat,
        offset: CGFloat = 0,
        viewport: CGFloat = 600,
        top: CGFloat = 0,
        bottom: CGFloat = 0
    ) -> CaptionScrollGeometry {
        CaptionScrollGeometry(
            ScrollGeometry(
                contentOffset: CGPoint(x: 0, y: offset),
                contentSize: CGSize(width: 430, height: height),
                contentInsets: EdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 0),
                containerSize: CGSize(width: 430, height: viewport)
            ))
    }
}
