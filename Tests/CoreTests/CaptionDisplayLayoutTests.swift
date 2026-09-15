#if os(iOS)
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import LarmindonKit

/// Exercise the real SwiftUI/UIScrollView layout as partial captions arrive. Policy
/// tests cover gesture intent; these catch mismatches between that policy and layout.
@MainActor
final class CaptionDisplayLayoutTests: XCTestCase {
    @Observable
    final class Fixture {
        var finalized: [TranscriptChunk] = []
        var volatile: [VolatileCaption] = []
        var height: CGFloat = 560
        var fontSize: Double = 34
    }

    private struct FixtureView: View {
        let fixture: Fixture

        var body: some View {
            CaptionDisplayView(
                finalizedChunks: fixture.finalized,
                volatileCaptions: fixture.volatile,
                fontSize: fixture.fontSize
            )
            .frame(height: fixture.height)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private final class QuietSource: TranscriptionSource {
        let name = "Layout fixture"
        let results: AsyncStream<CaptionResult>
        let continuation: AsyncStream<CaptionResult>.Continuation
        let levelUpdates = AsyncStream<AudioLevelSnapshot> { $0.finish() }

        init() { (results, continuation) = AsyncStream.makeStream() }
        func start() async throws {}
        func stop() async {}
    }

    func testErrorBannerChangesRealViewportWithoutReplacingScrollView() async throws {
        let session = CaptionSession(selectedSourceKind: .fake)
        let source = QuietSource()
        session.sourceFactory = { _, _ in source }
        session.store.appendFinalized("A short caption stays at the top.")
        let window = hostContent(LarmindonRootView(session: session))
        defer { window.isHidden = true }
        await settle()
        session.start()
        await settle()
        XCTAssertNil(session.lastError)
        let scroll = try XCTUnwrap(findScrollView(in: window))
        let originalHeight = scroll.bounds.height
        let originalViewportHeight = viewportHeight(scroll)
        let originalTop = scroll.convert(scroll.bounds, to: window).minY + scroll.adjustedContentInset.top
        let originalInsets = scroll.adjustedContentInset
        assertAtTop(scroll)

        source.continuation.yield(.failure("An example provider error for the layout test."))
        await settle()
        XCTAssertNotNil(session.lastError)
        XCTAssertTrue(findScrollView(in: window) === scroll)
        XCTAssertLessThan(scroll.bounds.height, originalHeight)
        // UIKit can remove its navigation-bar inset when the banner moves the scroll
        // view away from that edge. Compare the usable viewport, not raw insets.
        XCTAssertLessThan(viewportHeight(scroll), originalViewportHeight)
        XCTAssertGreaterThan(scroll.convert(scroll.bounds, to: window).minY + scroll.adjustedContentInset.top, originalTop)
        assertAtTop(scroll)

        session.sourceFactory = { _, _ in QuietSource() }
        session.start()
        await settle()
        XCTAssertNil(session.lastError)
        XCTAssertTrue(findScrollView(in: window) === scroll)
        XCTAssertEqual(scroll.bounds.height, originalHeight, accuracy: 1)
        XCTAssertEqual(scroll.adjustedContentInset, originalInsets)
        assertAtTop(scroll)
        await session.stop()
    }

    func testStreamingShortTextAndFinalizationStayAtTop() async throws {
        let fixture = Fixture()
        let window = host(fixture)
        defer { window.isHidden = true }
        await settle()
        let scroll = try XCTUnwrap(findScrollView(in: window))

        for text in [
            "I th", "I think you", "I think you can read",
            "I think you can read for another 5 minutes",
            "I think you can read for another 5 minutes along, then it's time to go upstairs."
        ] {
            fixture.volatile = [VolatileCaption(text: text, speakerID: "1")]
            await settle()
            XCTAssertLessThan(scroll.contentSize.height, viewportHeight(scroll))
            assertAtTop(scroll)
        }

        fixture.finalized = [TranscriptChunk(text: fixture.volatile[0].text, speakerID: "1")]
        fixture.volatile = [VolatileCaption(text: "So you're reading a book again, huh?", speakerID: "1")]
        await settle()
        XCTAssertLessThan(scroll.contentSize.height, viewportHeight(scroll))
        assertAtTop(scroll)
    }

    func testOverflowFollowsBottomThenShrinkAndClearReturnToTop() async throws {
        let fixture = Fixture()
        let window = host(fixture)
        defer { window.isHidden = true }
        await settle()
        let scroll = try XCTUnwrap(findScrollView(in: window))

        for index in 0..<12 {
            fixture.finalized.append(TranscriptChunk(
                text: "Caption \(index). Another sentence in the conversation.", speakerID: "1"
            ))
            await settle()
            if scroll.contentSize.height > viewportHeight(scroll) + 1 {
                assertAtBottom(scroll)
            } else {
                assertAtTop(scroll)
            }
        }
        XCTAssertGreaterThan(scroll.contentSize.height, viewportHeight(scroll))

        // Rapid replacements must leave the latest layout at the end.
        for index in 0..<20 {
            fixture.volatile = [VolatileCaption(text: String(repeating: "Growing tail \(index). ", count: index + 1))]
        }
        await settle()
        assertAtBottom(scroll)

        fixture.finalized = []
        fixture.volatile = [VolatileCaption(text: "Short corrected result.")]
        await settle()
        XCTAssertLessThan(scroll.contentSize.height, viewportHeight(scroll))
        assertAtTop(scroll)

        fixture.volatile = []
        await settle()
        assertAtTop(scroll)
        fixture.volatile = [VolatileCaption(text: "Starting again.")]
        await settle()
        assertAtTop(scroll)
    }

    func testViewportAndFontChangesReevaluateOverflow() async throws {
        let fixture = Fixture()
        let window = host(fixture)
        defer { window.isHidden = true }
        fixture.volatile = [VolatileCaption(text: String(repeating: "Another caption sentence. ", count: 4))]
        await settle()
        let scroll = try XCTUnwrap(findScrollView(in: window))
        XCTAssertLessThan(scroll.contentSize.height, viewportHeight(scroll))
        assertAtTop(scroll)

        // The same caption view can shrink for an error banner or landscape controls.
        fixture.height = 180
        await settle()
        XCTAssertGreaterThan(scroll.contentSize.height, viewportHeight(scroll))
        assertAtBottom(scroll)
        fixture.height = 560
        await settle()
        assertAtTop(scroll)

        fixture.fontSize = 72
        await settle()
        XCTAssertGreaterThan(scroll.contentSize.height, viewportHeight(scroll))
        assertAtBottom(scroll)
        fixture.fontSize = 20
        await settle()
        assertAtTop(scroll)
    }

    private func host(_ fixture: Fixture) -> UIWindow {
        hostContent(FixtureView(fixture: fixture))
    }

    private func hostContent<Content: View>(_ content: Content) -> UIWindow {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        }
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        return window
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }

    private func viewportHeight(_ scroll: UIScrollView) -> CGFloat {
        scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom
    }

    private func assertAtTop(_ scroll: UIScrollView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 1, file: file, line: line)
    }

    private func assertAtBottom(_ scroll: UIScrollView, file: StaticString = #filePath, line: UInt = #line) {
        let expected = max(-scroll.adjustedContentInset.top,
                           scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        XCTAssertEqual(scroll.contentOffset.y, expected, accuracy: 1, file: file, line: line)
    }
}
#endif
