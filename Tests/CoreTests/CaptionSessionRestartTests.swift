import XCTest
@testable import LarmindonKit

@MainActor
final class CaptionSessionRestartTests: XCTestCase {
    private class ControlledSource: TranscriptionSource {
        let name = "Controlled"
        let results: AsyncStream<CaptionResult>
        let continuation: AsyncStream<CaptionResult>.Continuation
        let levelUpdates = AsyncStream<AudioLevelSnapshot> { $0.finish() }
        var started = false
        var stopCount = 0
        var finished = false
        private var stopContinuation: CheckedContinuation<Void, Never>?

        init() {
            (results, continuation) = AsyncStream.makeStream()
        }

        func start() async throws { started = true }

        func stop() async {
            stopCount += 1
            await withCheckedContinuation { stopContinuation = $0 }
            finished = true
        }

        func finish() {
            continuation.finish()
            stopContinuation?.resume()
            stopContinuation = nil
        }
    }

    private final class DrainingSource: ControlledSource,
        BackgroundFinishingTranscriptionSource
    {}

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Lifecycle transition did not complete")
    }

    private final class QuietSource: TranscriptionSource {
        let name = "Quiet"
        let results: AsyncStream<CaptionResult>
        let resultContinuation: AsyncStream<CaptionResult>.Continuation
        let levelUpdates: AsyncStream<AudioLevelSnapshot>
        let levelContinuation: AsyncStream<AudioLevelSnapshot>.Continuation

        init() {
            (results, resultContinuation) = AsyncStream.makeStream()
            (levelUpdates, levelContinuation) = AsyncStream.makeStream()
        }

        func start() async throws {}
        func stop() async {}
    }

    private func quietSession() async -> (CaptionSession, QuietSource) {
        let source = QuietSource()
        let session = CaptionSession(selectedSourceKind: .fake)
        session.sourceFactory = { _, _ in source }
        session.start()
        await waitUntil { session.activeMode != nil }
        return (session, source)
    }

    private func waitForAudioWatchdog() async {
        // Exercise the production three-second timeout, with scheduling headroom.
        try? await Task.sleep(for: .milliseconds(3200))
    }

    func testSessionOwnedCapturePreventsNoAudioWarningEvenForUnchangedZeroLevels() async {
        let (session, _) = await quietSession()
        // The exact delivery boundary used by captureLevelTask in the Soniox path.
        session.receiveAudioLevels(AudioLevelSnapshot())
        await waitForAudioWatchdog()
        XCTAssertNil(session.lastError)
        XCTAssertTrue(session.store.isRunning)
        await session.stop()
    }

    func testProviderOwnedCaptureAlsoPreventsNoAudioWarning() async {
        let (session, source) = await quietSession()
        source.levelContinuation.yield(AudioLevelSnapshot(rawInputLevel: 0.5))
        await waitUntil { session.audioLevels.rawInputLevel == 0.5 }
        await waitForAudioWatchdog()
        XCTAssertNil(session.lastError)
        await session.stop()
    }

    func testLateAudioClearsWarningAndNewSessionStillDetectsMissingAudio() async {
        let (session, _) = await quietSession()
        await waitForAudioWatchdog()
        XCTAssertTrue(session.lastError?.hasPrefix("No audio is arriving") == true)
        session.receiveAudioLevels(AudioLevelSnapshot())
        XCTAssertNil(session.lastError)
        await session.stop()
        session.start()
        await waitUntil { session.activeMode != nil }
        await waitForAudioWatchdog()
        XCTAssertTrue(session.lastError?.hasPrefix("No audio is arriving") == true)
        await session.stop()
    }

    func testAudioDoesNotClearAnUnrelatedProviderFailure() async {
        let (session, source) = await quietSession()
        await waitForAudioWatchdog()
        XCTAssertTrue(session.lastError?.hasPrefix("No audio is arriving") == true)
        source.resultContinuation.yield(.failure("Provider connection failed"))
        await waitUntil { session.lastError == "Provider connection failed" }
        session.receiveAudioLevels(AudioLevelSnapshot())
        XCTAssertEqual(session.lastError, "Provider connection failed")
        await session.stop()
    }

    func testWidgetLaunchDoesNotInterruptLocalStop() async {
        let source = ControlledSource()
        let session = CaptionSession(selectedSourceKind: .fake)
        session.sourceFactory = { _, _ in source }
        session.start()
        await waitUntil { session.activeMode != nil }
        let stop = Task { await session.stop() }
        await waitUntil { source.stopCount == 1 }
        XCTAssertFalse(session.store.isRunning)
        XCTAssertFalse(session.startIfIdle(mode: .server))
        XCTAssertEqual(session.requestedMode, .onDevice)
        source.finish()
        await stop.value
        XCTAssertTrue(session.canStartIfIdle)
    }

    func testRestartDoesNotWaitForRetiredProviderAndIgnoresLateEvents() async {
        let old = DrainingSource()
        let replacement = DrainingSource()
        let session = CaptionSession(selectedSourceKind: .fake)
        var sources: [ControlledSource] = [old, replacement]
        session.sourceFactory = { _, _ in sources.removeFirst() }
        session.start()
        await waitUntil { session.activeMode != nil }

        // Stop and immediately restart without waiting for the Stop caller to return.
        let stop = Task { await session.stop() }
        await waitUntil { old.stopCount == 1 }
        session.start()
        await waitUntil { replacement.started && session.activeMode != nil }
        await stop.value
        XCTAssertFalse(old.finished, "Restart must precede the server's finish reply")

        old.continuation.yield(.failure("late failure from old connection"))
        old.continuation.yield(.volatile("stale words"))
        old.finish()
        await waitUntil { old.finished }
        replacement.continuation.yield(.volatile("new words"))
        await waitUntil { session.lastVolatileResult == "new words" }
        XCTAssertNil(session.lastError)
        XCTAssertTrue(session.store.isRunning)
        XCTAssertEqual(session.speechAnalyzerState, "Running Controlled")
        XCTAssertNotNil(session.activeMode)

        await session.stop()
        await waitUntil { replacement.stopCount == 1 }
        replacement.finish()
        await waitUntil { replacement.finished }
    }

    func testRapidStopStartStopKeepsBothRetiredProvidersIsolated() async {
        let first = DrainingSource()
        let second = DrainingSource()
        let session = CaptionSession(selectedSourceKind: .fake)
        var sources: [ControlledSource] = [first, second]
        session.sourceFactory = { _, _ in sources.removeFirst() }
        session.start()
        await waitUntil { session.activeMode != nil }
        await session.stop()
        session.start()
        await waitUntil { second.started && session.activeMode != nil }
        await session.stop()
        await waitUntil { first.stopCount == 1 && second.stopCount == 1 }
        XCTAssertFalse(first.finished)
        XCTAssertFalse(second.finished)
        second.finish()
        first.finish()
        await waitUntil { first.finished && second.finished }
        XCTAssertFalse(session.store.isRunning)
        XCTAssertNil(session.activeMode)
        XCTAssertEqual(session.speechAnalyzerState, "Stopped")
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(second.stopCount, 1)
    }

    func testSourceOwningCaptureStillFinishesBeforeRestart() async {
        let old = ControlledSource()
        let replacement = DrainingSource()
        let session = CaptionSession(selectedSourceKind: .fake)
        var sources: [ControlledSource] = [old, replacement]
        session.sourceFactory = { _, _ in sources.removeFirst() }
        session.start()
        await waitUntil { session.activeMode != nil }
        let stop = Task { await session.stop() }
        await waitUntil { old.stopCount == 1 }
        session.start()
        // Allow Start to reach the local-stop join while the old microphone is owned.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(replacement.started)
        XCTAssertEqual(old.stopCount, 1)
        old.finish()
        await stop.value
        await waitUntil { replacement.started && session.activeMode != nil }
        await session.stop()
        await waitUntil { replacement.stopCount == 1 }
        replacement.finish()
        await waitUntil { replacement.finished }
    }
}
