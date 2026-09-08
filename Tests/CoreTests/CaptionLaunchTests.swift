import XCTest
@testable import LarmindonKit

@MainActor
final class CaptionLaunchTests: XCTestCase {
    private final class Source: TranscriptionSource {
        let name = "Launcher test"
        let results = AsyncStream<CaptionResult> { _ in }
        let levelUpdates = AsyncStream<AudioLevelSnapshot> { _ in }
        var starts = 0
        var stops = 0
        func start() async throws { starts += 1 }
        func stop() async { stops += 1 }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }

    func testOnlyExactLaunchActionIsAccepted() {
        XCTAssertTrue(CaptionLaunchLink.matches(CaptionLaunchLink.url))
        for value in [
            "https://captions/start", "larmindon://captions/stop",
            "larmindon://other/start", "larmindon://captions/start?provider=soniox",
            "larmindon://captions/start#extra", "larmindon://user@captions/start",
            "larmindon://captions:123/start", "larmindon://captions/start/",
        ] {
            XCTAssertFalse(CaptionLaunchLink.matches(URL(string: value)!), value)
        }
    }

    func testRepeatedLaunchPreservesStartingAndRunningSessionAndProvider() async {
        let source = Source()
        let session = CaptionSession(selectedSourceKind: .fake)
        var modes: [TranscriptionMode] = []
        session.sourceFactory = { _, mode in
            modes.append(mode)
            return source
        }
        XCTAssertTrue(session.startIfIdle(mode: .server))
        // No suspension: verifies the window before performStart sets isRunning.
        XCTAssertFalse(session.startIfIdle(mode: .onDevice))
        await waitUntil { session.activeMode == .server }
        XCTAssertFalse(session.startIfIdle(mode: .onDevice))
        XCTAssertEqual(session.requestedMode, .server)
        XCTAssertEqual(modes, [.server])
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(source.stops, 0)
        await session.stop()
        XCTAssertTrue(session.canStartIfIdle)
        XCTAssertTrue(session.startIfIdle(mode: .onDevice))
        await waitUntil { session.activeMode == .onDevice }
        XCTAssertEqual(source.starts, 2)
        await session.stop()
    }

    func testFailedLaunchCanBeRetried() async {
        let session = CaptionSession(selectedSourceKind: .fake)
        session.sourceFactory = { _, _ in
            throw TranscriptionSourceError.unavailable("Missing test credential")
        }
        XCTAssertTrue(session.startIfIdle(mode: .server))
        await waitUntil { session.canStartIfIdle && session.lastError != nil }
        XCTAssertTrue(session.lastError?.contains("Missing test credential") == true)
        let source = Source()
        session.sourceFactory = { _, _ in source }
        XCTAssertTrue(session.startIfIdle(mode: .server))
        await waitUntil { session.activeMode == .server }
        XCTAssertNil(session.lastError)
        await session.stop()
    }

    #if os(iOS)
    func testLaunchDoesNotReplaceInterruptedSessionEvenWithRunningFlagCleared() async {
        let session = CaptionSession(selectedSourceKind: .fake)
        session.store.isRunning = true
        session.routeManager.onAudioInterruption?(.began)
        session.store.isRunning = false
        XCTAssertTrue(session.isInterrupted)
        XCTAssertFalse(session.startIfIdle(mode: .server))
        XCTAssertEqual(session.requestedMode, .onDevice)
        await session.stop()
    }
    #endif
}
