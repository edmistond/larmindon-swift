import XCTest
@testable import LarmindonKit

@MainActor
final class CaptionSessionClearUndoTests: XCTestCase {
    private let manualDelay = ManualDelay()

    private func makeSession() -> CaptionSession {
        let session = CaptionSession(selectedSourceKind: .fake)
        session.delay = manualDelay.dependency
        return session
    }

    private func expire(_ session: CaptionSession) async {
        await manualDelay.waitUntilScheduled(CaptionSession.clearUndoWindow)
        let task = session.clearUndoExpiryTask
        await manualDelay.advance(by: CaptionSession.clearUndoWindow)
        await task?.value
    }

    func testClearStashesFinalizedChunksAndOffersUndo() {
        let session = makeSession()
        session.store.appendFinalized("first")
        session.store.appendFinalized("second")
        session.store.replaceVolatile("tail")

        session.clear()

        XCTAssertTrue(session.store.finalizedChunks.isEmpty)
        XCTAssertNil(session.store.volatileTail)
        XCTAssertTrue(session.canUndoClear)
    }

    func testUndoRestoresChunksBeforeThoseThatArrivedAfterTheClear() {
        let session = makeSession()
        session.store.appendFinalized("first")
        session.store.appendFinalized("second")
        session.clear()
        session.store.appendFinalized("after")

        session.undoClear()

        XCTAssertEqual(session.store.finalizedChunks.map(\.text), ["first", "second", "after"])
        XCTAssertFalse(session.canUndoClear)
    }

    func testUndoDoesNotRestoreVolatileTail() {
        let session = makeSession()
        session.store.appendFinalized("first")
        session.store.replaceVolatile("tail")
        session.clear()

        session.undoClear()

        XCTAssertEqual(session.store.finalizedChunks.map(\.text), ["first"])
        XCTAssertNil(session.store.volatileTail)
    }

    func testUndoTwiceRestoresOnce() {
        let session = makeSession()
        session.store.appendFinalized("first")
        session.clear()

        session.undoClear()
        session.undoClear()

        XCTAssertEqual(session.store.finalizedChunks.map(\.text), ["first"])
    }

    func testUndoWithNothingToUndoIsANoOp() {
        let session = makeSession()
        session.store.appendFinalized("kept")

        session.undoClear()

        XCTAssertEqual(session.store.finalizedChunks.map(\.text), ["kept"])
        XCTAssertFalse(session.canUndoClear)
    }

    func testUndoExpiresAfterTheWindow() async {
        let session = makeSession()
        session.store.appendFinalized("first")
        session.clear()

        await expire(session)

        XCTAssertFalse(session.canUndoClear)
        session.undoClear()
        XCTAssertTrue(session.store.finalizedChunks.isEmpty)
    }

    func testUndoStillAvailableBeforeTheWindowEnds() async {
        let session = makeSession()
        session.store.appendFinalized("first")
        session.clear()

        await manualDelay.waitUntilScheduled(CaptionSession.clearUndoWindow)
        await manualDelay.advance(by: .seconds(4))
        await Task.yield()

        XCTAssertTrue(session.canUndoClear)
        session.undoClear()
        XCTAssertEqual(session.store.finalizedChunks.map(\.text), ["first"])
    }

    func testSecondClearReplacesStashAndRestartsWindow() async {
        let session = makeSession()
        session.store.appendFinalized("first")
        session.clear()
        await manualDelay.waitUntilScheduled(CaptionSession.clearUndoWindow)
        await manualDelay.advance(by: .seconds(4))

        session.store.appendFinalized("second")
        session.clear()
        // The first window would have ended here; the second clear's has not.
        await manualDelay.advance(by: .seconds(2))
        await Task.yield()
        XCTAssertTrue(session.canUndoClear)

        session.undoClear()
        XCTAssertEqual(session.store.finalizedChunks.map(\.text), ["second"])
    }

    func testSecondClearWindowStillExpires() async {
        let session = makeSession()
        session.store.appendFinalized("first")
        session.clear()
        session.store.appendFinalized("second")
        session.clear()

        await expire(session)

        XCTAssertFalse(session.canUndoClear)
    }

    func testClearingAnEmptyStoreOffersNoUndo() {
        let session = makeSession()

        session.clear()

        XCTAssertFalse(session.canUndoClear)
    }

    func testClearingAnEmptyStoreDropsTheEarlierStash() {
        let session = makeSession()
        session.store.appendFinalized("first")
        session.clear()

        session.clear()

        XCTAssertFalse(session.canUndoClear)
        session.undoClear()
        XCTAssertTrue(session.store.finalizedChunks.isEmpty)
    }
}
