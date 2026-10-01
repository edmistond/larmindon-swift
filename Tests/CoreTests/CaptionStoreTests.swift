import XCTest
@testable import LarmindonKit

@MainActor
final class CaptionStoreTests: XCTestCase {
    func testVolatileUpdateReplacesTail() {
        let store = CaptionStore()

        store.replaceVolatile("one")
        store.replaceVolatile("two")

        XCTAssertEqual(store.volatileTail?.text, "two")
        XCTAssertTrue(store.finalizedChunks.isEmpty)
    }

    func testFinalizedResultAppendsChunkAndClearsVolatileTail() {
        let store = CaptionStore()

        store.replaceVolatile("temporary")
        store.appendFinalized("final")

        XCTAssertEqual(store.finalizedChunks.map(\.text), ["final"])
        XCTAssertNil(store.volatileTail)
    }

    func testClearRemovesFinalizedAndVolatileText() {
        let store = CaptionStore()

        store.appendFinalized("first")
        store.replaceVolatile("tail")
        store.clear()

        XCTAssertTrue(store.finalizedChunks.isEmpty)
        XCTAssertNil(store.volatileTail)
    }

    func testRestoreClearedPrependsBeforeChunksFinalizedSinceTheClear() {
        let store = CaptionStore()
        store.appendFinalized("first")
        store.appendFinalized("second")
        let cleared = store.finalizedChunks
        store.clear()
        store.appendFinalized("after")

        store.restoreCleared(cleared)

        XCTAssertEqual(store.finalizedChunks.map(\.text), ["first", "second", "after"])
        XCTAssertEqual(store.finalizedChunks.prefix(2).map(\.id), cleared.map(\.id))
    }

    func testRestoreClearedWithNoChunksChangesNothing() {
        let store = CaptionStore()
        store.appendFinalized("only")

        store.restoreCleared([])

        XCTAssertEqual(store.finalizedChunks.map(\.text), ["only"])
    }

    func testFullFinalizedTranscriptGeneration() {
        let store = CaptionStore()

        store.appendFinalized("first")
        store.appendFinalized("second")

        XCTAssertEqual(store.fullFinalizedTranscript, "first\nsecond")
    }

    func testFullTranscriptIncludesVolatileTail() {
        let store = CaptionStore()

        store.appendFinalized("first")
        store.appendFinalized("second")
        store.replaceVolatile("still in progress")

        XCTAssertEqual(store.fullTranscript, "first\nsecond\nstill in progress")
    }

    func testTranscriptMarksSpeakerChangesAndSeparatesBlocks() {
        let store = CaptionStore()

        store.appendFinalized([
            CaptionSegment(text: "First thing I said.", speakerID: "1"),
            CaptionSegment(text: "Second thing I said.", speakerID: "1"),
            CaptionSegment(text: "My reply.", speakerID: "2"),
        ])

        // One marker per speaker turn, not per line, and a blank line between turns.
        XCTAssertEqual(
            store.fullTranscript,
            """
            [Speaker 1] First thing I said.
            Second thing I said.

            [Speaker 2] My reply.
            """
        )
    }

    func testTranscriptMarksASpeakerReturningLaterAsANewBlock() {
        let store = CaptionStore()

        store.appendFinalized([
            CaptionSegment(text: "Question?", speakerID: "1"),
            CaptionSegment(text: "Answer.", speakerID: "2"),
        ])
        store.replaceVolatile([
            CaptionSegment(text: "Follow-up.", speakerID: "1")
        ])

        XCTAssertEqual(
            store.fullTranscript,
            """
            [Speaker 1] Question?

            [Speaker 2] Answer.

            [Speaker 1] Follow-up.
            """
        )
    }

    func testTranscriptWithoutSpeakersStaysUnlabelled() {
        let store = CaptionStore()

        // On-device transcription reports no speaker, so the output must not gain markers.
        store.appendFinalized("first")
        store.appendFinalized("second")
        store.replaceVolatile("still in progress")

        XCTAssertEqual(store.fullTranscript, "first\nsecond\nstill in progress")
    }

    func testVisibleCaptionTextUsesRecentChunksPlusVolatileTail() {
        let store = CaptionStore()

        store.appendFinalized("first")
        store.appendFinalized("second")
        store.appendFinalized("third")
        store.replaceVolatile("tail")

        let lines = store.visibleCaptionLines(recentLimit: 2)

        XCTAssertEqual(lines.map(\.text), ["second", "third", "tail"])
        XCTAssertEqual(lines.map(\.isVolatile), [false, false, true])
    }

    func testVisibleCaptionTextIncludesEntireTranscriptByDefault() {
        let store = CaptionStore()

        for index in 0..<40 {
            store.appendFinalized("caption \(index)")
        }

        let lines = store.visibleCaptionLines()

        XCTAssertEqual(lines.count, 40)
        XCTAssertEqual(lines.first?.text, "caption 0")
        XCTAssertEqual(lines.last?.text, "caption 39")
    }

    func testSpeakerSegmentsRetainMetadataForFinalAndVolatileLines() {
        let store = CaptionStore()

        store.appendFinalized([
            CaptionSegment(text: "First speaker", speakerID: "1"),
            CaptionSegment(text: "Second speaker", speakerID: "2"),
        ])
        store.replaceVolatile([
            CaptionSegment(text: "Live first speaker", speakerID: "1"),
            CaptionSegment(text: "Live second speaker", speakerID: "2"),
        ])

        let lines = store.visibleCaptionLines()

        XCTAssertEqual(
            lines.map(\.text),
            [
                "First speaker",
                "Second speaker",
                "Live first speaker",
                "Live second speaker",
            ]
        )
        XCTAssertEqual(lines.map(\.speakerID), ["1", "2", "1", "2"])
        XCTAssertEqual(lines.map(\.isVolatile), [false, false, true, true])
    }
}
