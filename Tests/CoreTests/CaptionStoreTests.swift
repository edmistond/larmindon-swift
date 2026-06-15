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
}
