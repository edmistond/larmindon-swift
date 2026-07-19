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
}
