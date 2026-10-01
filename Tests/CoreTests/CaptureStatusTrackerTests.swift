import XCTest
@testable import LarmindonKit

final class CaptureStatusTrackerTests: XCTestCase {
    private let origin = ContinuousClock.now

    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        origin + .milliseconds(Int((seconds * 1000).rounded()))
    }

    /// A tracker started at t=0 whose capture is running from t=0.
    private func running(_ mode: TranscriptionMode) -> CaptureStatusTracker {
        var tracker = CaptureStatusTracker()
        tracker.start(mode: mode, at: at(0))
        tracker.captureDidStart(at: at(0))
        return tracker
    }

    /// Delivers a buffer every 100 ms over [from, to), evaluating after each, as capture does.
    private func feedAudio(
        _ tracker: inout CaptureStatusTracker,
        from start: Double,
        to end: Double,
        silent: Bool = false
    ) {
        var time = start
        while time < end - 0.0001 {
            tracker.audioArrived(silent: silent, at: at(time))
            _ = tracker.evaluate(at: at(time))
            time += 0.1
        }
    }

    // MARK: Start and stop

    func testStartIsStartingAndStopIsImmediate() {
        var tracker = CaptureStatusTracker()
        XCTAssertEqual(tracker.status, .stopped)
        tracker.start(mode: .onDevice, at: at(0))
        XCTAssertEqual(tracker.status, .starting)
        tracker.stop(at: at(0.1))
        XCTAssertEqual(tracker.status, .stopped)
    }

    func testStopIsImmediateEvenWithinTheDwell() {
        var tracker = running(.onDevice)
        tracker.recognizerActivity(at: at(0.5))
        XCTAssertEqual(tracker.evaluate(at: at(0.5)), .captioning)
        tracker.stop(at: at(0.6))
        XCTAssertEqual(tracker.status, .stopped)
    }

    func testInputsAreIgnoredWhileStopped() {
        var tracker = CaptureStatusTracker()
        tracker.audioArrived(silent: false, at: at(0))
        tracker.recognizerActivity(at: at(0))
        XCTAssertEqual(tracker.evaluate(at: at(5)), .stopped)
    }

    // MARK: No audio

    func testNoAudioAfterTwoSecondsWithNoBuffers() {
        var tracker = running(.onDevice)
        XCTAssertEqual(tracker.evaluate(at: at(1.9)), .starting)
        XCTAssertEqual(tracker.evaluate(at: at(2.0)), .noAudio)
    }

    func testOnlySilentBuffersIsNoAudio() {
        var tracker = running(.onDevice)
        feedAudio(&tracker, from: 0, to: 1.9, silent: true)
        XCTAssertEqual(tracker.status, .starting)
        feedAudio(&tracker, from: 1.9, to: 2.1, silent: true)
        XCTAssertEqual(tracker.status, .noAudio)
    }

    func testNoAudioClockWaitsForCaptureToBeRunning() {
        var tracker = CaptureStatusTracker()
        tracker.start(mode: .onDevice, at: at(0))
        // A slow model load is still Starting, not a dead input.
        XCTAssertEqual(tracker.evaluate(at: at(5)), .starting)
        tracker.captureDidStart(at: at(5))
        XCTAssertEqual(tracker.evaluate(at: at(6.9)), .starting)
        XCTAssertEqual(tracker.evaluate(at: at(7)), .noAudio)
    }

    func testAudioStoppingMidSessionIsNoAudioAfterTwoSeconds() {
        var tracker = running(.onDevice)
        feedAudio(&tracker, from: 0, to: 5)
        XCTAssertEqual(tracker.status, .listening)
        XCTAssertEqual(tracker.evaluate(at: at(6.85)), .listening)
        XCTAssertEqual(tracker.evaluate(at: at(6.95)), .noAudio)
    }

    func testNoAudioTakesPriorityOverServerHeartbeats() {
        // Soniox keeps sending updates while it is fed digital silence.
        var tracker = running(.server)
        var time = 0.0
        while time < 3 {
            tracker.audioArrived(silent: true, at: at(time))
            tracker.received(.volatileSegments([]), at: at(time))
            _ = tracker.evaluate(at: at(time))
            time += 0.25
        }
        // Captioning at once from Starting, then No audio once the dwell allows.
        XCTAssertEqual(tracker.evaluate(at: at(3)), .noAudio)
    }

    // MARK: Listening

    func testListeningAfterOneSecondOfAudibleAudio() {
        var tracker = running(.onDevice)
        feedAudio(&tracker, from: 0, to: 0.95)
        XCTAssertEqual(tracker.status, .starting)
        feedAudio(&tracker, from: 1.0, to: 1.05)
        XCTAssertEqual(tracker.status, .listening)
    }

    func testSilentBufferRestartsTheAudibleRun() {
        var tracker = running(.onDevice)
        feedAudio(&tracker, from: 0, to: 0.8)
        tracker.audioArrived(silent: true, at: at(0.8))
        feedAudio(&tracker, from: 0.9, to: 1.85)
        XCTAssertEqual(tracker.status, .starting)
        feedAudio(&tracker, from: 1.9, to: 1.95)
        XCTAssertEqual(tracker.status, .listening)
    }

    func testAudioReturningAfterNoAudioNeedsOneSecondAndTheDwell() {
        var tracker = running(.onDevice)
        XCTAssertEqual(tracker.evaluate(at: at(2)), .noAudio)
        feedAudio(&tracker, from: 2.5, to: 3.45)
        XCTAssertEqual(tracker.status, .noAudio)
        // A second of audio by 3.5, but No audio only began at 2.
        feedAudio(&tracker, from: 3.5, to: 3.95)
        XCTAssertEqual(tracker.status, .noAudio)
        feedAudio(&tracker, from: 4.0, to: 4.05)
        XCTAssertEqual(tracker.status, .listening)
    }

    // MARK: Captioning

    func testRecognizerActivityFromStartingIsImmediate() {
        var tracker = running(.onDevice)
        tracker.audioArrived(silent: false, at: at(0.2))
        tracker.received(.volatile("hello"), at: at(0.3))
        XCTAssertEqual(tracker.evaluate(at: at(0.3)), .captioning)
    }

    func testOnDeviceCaptioningFallsBackToListeningAfterTenQuietSeconds() {
        var tracker = running(.onDevice)
        feedAudio(&tracker, from: 0, to: 2)
        tracker.received(.finalized("hello"), at: at(2))
        XCTAssertEqual(tracker.evaluate(at: at(2)), .listening, "dwell holds Listening")
        feedAudio(&tracker, from: 2, to: 11.95)
        XCTAssertEqual(tracker.status, .captioning)
        feedAudio(&tracker, from: 12, to: 12.05)
        XCTAssertEqual(tracker.status, .listening)
    }

    func testOnDeviceNeverStallsWhenResultsGoQuiet() {
        // SpeechAnalyzer reports only on speech: a long quiet stretch is not a stall.
        var tracker = running(.onDevice)
        feedAudio(&tracker, from: 0, to: 0.5)
        tracker.received(.volatile("hello"), at: at(0.5))
        feedAudio(&tracker, from: 0.5, to: 120)
        XCTAssertEqual(tracker.status, .listening)
    }

    func testOnDeviceIgnoresResultsWithoutWords() {
        var tracker = running(.onDevice)
        feedAudio(&tracker, from: 0, to: 1.5)
        tracker.received(.volatile("  "), at: at(1.5))
        tracker.received(.volatileSegments([]), at: at(1.5))
        feedAudio(&tracker, from: 1.5, to: 5)
        XCTAssertEqual(tracker.status, .listening)
    }

    func testActivityClassificationByMode() {
        let words = CaptionResult.volatile("hi")
        let empty = CaptionResult.volatileSegments([])
        XCTAssertTrue(CaptureStatusTracker.isRecognizerActivity(words, mode: .onDevice))
        XCTAssertFalse(CaptureStatusTracker.isRecognizerActivity(empty, mode: .onDevice))
        XCTAssertTrue(CaptureStatusTracker.isRecognizerActivity(words, mode: .server))
        XCTAssertTrue(CaptureStatusTracker.isRecognizerActivity(empty, mode: .server))
        for mode in [TranscriptionMode.onDevice, .server] {
            XCTAssertFalse(CaptureStatusTracker.isRecognizerActivity(.failure("x"), mode: mode))
            XCTAssertFalse(
                CaptureStatusTracker.isRecognizerActivity(.connectionInterrupted("x"), mode: mode))
            XCTAssertFalse(CaptureStatusTracker.isRecognizerActivity(.connectionRestored, mode: mode))
        }
    }

    // MARK: Server stall

    func testServerHeartbeatsKeepCaptioningInSilence() {
        var tracker = running(.server)
        var time = 0.0
        while time < 60 {
            tracker.audioArrived(silent: false, at: at(time))
            if time.truncatingRemainder(dividingBy: 1) < 0.01 {
                tracker.received(.volatileSegments([]), at: at(time))
            }
            _ = tracker.evaluate(at: at(time))
            time += 0.25
        }
        XCTAssertEqual(tracker.status, .captioning)
    }

    func testServerStallsAfterTenSecondsOfAudioWithoutActivity() {
        var tracker = running(.server)
        feedAudio(&tracker, from: 0, to: 9.95)
        XCTAssertEqual(tracker.status, .listening)
        feedAudio(&tracker, from: 10, to: 10.05)
        XCTAssertEqual(tracker.status, .stalled)
    }

    func testServerCaptioningGoesQuietToStalledNotListening() {
        var tracker = running(.server)
        feedAudio(&tracker, from: 0, to: 0.5)
        tracker.received(.volatileSegments([]), at: at(0.5))
        feedAudio(&tracker, from: 0.5, to: 10.45)
        XCTAssertEqual(tracker.status, .captioning)
        feedAudio(&tracker, from: 10.5, to: 10.55)
        XCTAssertEqual(tracker.status, .stalled)
        // A heartbeat returning clears it, once the dwell has passed.
        feedAudio(&tracker, from: 10.6, to: 11)
        tracker.received(.volatileSegments([]), at: at(11))
        feedAudio(&tracker, from: 11, to: 12.45)
        XCTAssertEqual(tracker.status, .stalled)
        feedAudio(&tracker, from: 12.5, to: 12.55)
        XCTAssertEqual(tracker.status, .captioning)
    }

    func testServerDoesNotStallWithoutAudio() {
        var tracker = running(.server)
        XCTAssertEqual(tracker.evaluate(at: at(30)), .noAudio)
    }

    // MARK: Dwell

    func testDwellDelaysListeningToCaptioning() {
        var tracker = running(.onDevice)
        feedAudio(&tracker, from: 0, to: 1.05)
        XCTAssertEqual(tracker.status, .listening)  // entered at 1.0
        tracker.received(.volatile("hi"), at: at(1.5))
        feedAudio(&tracker, from: 1.5, to: 2.95)
        XCTAssertEqual(tracker.status, .listening)
        feedAudio(&tracker, from: 3.0, to: 3.05)
        XCTAssertEqual(tracker.status, .captioning)
    }

    // MARK: Reconnect and interruption

    func testReconnectStallsImmediatelyAndHoldsUntilFreshActivity() {
        var tracker = running(.server)
        feedAudio(&tracker, from: 0, to: 0.5)
        tracker.received(.volatileSegments([]), at: at(0.5))
        feedAudio(&tracker, from: 0.5, to: 1)
        XCTAssertEqual(tracker.status, .captioning)

        tracker.setConnectionState(reconnecting: true, interrupted: false, at: at(1))
        XCTAssertEqual(tracker.status, .stalled, "reconnect bypasses the dwell")
        // Capture keeps running while the provider reconnects.
        feedAudio(&tracker, from: 1, to: 4)
        XCTAssertEqual(tracker.status, .stalled)

        tracker.setConnectionState(reconnecting: false, interrupted: false, at: at(4))
        // Activity from before the drop doesn't count; the new connection must speak.
        feedAudio(&tracker, from: 4, to: 20)
        XCTAssertEqual(tracker.status, .stalled)
        tracker.received(.volatileSegments([]), at: at(20))
        XCTAssertEqual(tracker.evaluate(at: at(20)), .captioning)
    }

    func testReconnectThenHeartbeatIsCaptioning() {
        var tracker = running(.server)
        feedAudio(&tracker, from: 0, to: 3)
        tracker.setConnectionState(reconnecting: true, interrupted: false, at: at(3))
        feedAudio(&tracker, from: 3, to: 6)
        tracker.setConnectionState(reconnecting: false, interrupted: false, at: at(6))
        tracker.received(.volatileSegments([]), at: at(6.5))
        XCTAssertEqual(tracker.evaluate(at: at(6.5)), .captioning)
    }

    func testInterruptionHoldsStalledAcrossRecoveryRestart() {
        var tracker = running(.onDevice)
        feedAudio(&tracker, from: 0, to: 3)
        XCTAssertEqual(tracker.status, .listening)

        tracker.setConnectionState(reconnecting: false, interrupted: true, at: at(3))
        XCTAssertEqual(tracker.status, .stalled)

        // Recovery stops and starts as one motion; neither shows through.
        tracker.stop(at: at(3.1))
        XCTAssertEqual(tracker.status, .stalled)
        tracker.start(mode: .onDevice, at: at(3.2))
        XCTAssertEqual(tracker.status, .stalled)
        tracker.captureDidStart(at: at(3.3))
        feedAudio(&tracker, from: 3.3, to: 5)
        XCTAssertEqual(tracker.status, .stalled)

        tracker.setConnectionState(reconnecting: false, interrupted: false, at: at(5))
        XCTAssertEqual(tracker.status, .listening)
    }

    func testInterruptionEndingWhileStoppedIsStopped() {
        var tracker = running(.onDevice)
        tracker.setConnectionState(reconnecting: false, interrupted: true, at: at(1))
        tracker.stop(at: at(1.5))
        XCTAssertEqual(tracker.status, .stalled)
        tracker.setConnectionState(reconnecting: false, interrupted: false, at: at(1.6))
        XCTAssertEqual(tracker.status, .stopped)
    }

    func testReconnectingIsIgnoredWhileStopped() {
        var tracker = CaptureStatusTracker()
        tracker.setConnectionState(reconnecting: true, interrupted: false, at: at(0))
        XCTAssertEqual(tracker.status, .stopped)
    }

    // MARK: Silence threshold

    func testEffectiveSilenceThreshold() {
        XCTAssertTrue(CaptureStatusTracker.isEffectivelySilent(AudioLevelSnapshot()))
        XCTAssertTrue(
            CaptureStatusTracker.isEffectivelySilent(AudioLevelSnapshot(rawInputLevel: 0.0009)))
        XCTAssertFalse(
            CaptureStatusTracker.isEffectivelySilent(AudioLevelSnapshot(rawInputLevel: 0.001)))
        // A quiet room around -60 dBFS RMS, after the meter's display gain.
        XCTAssertFalse(
            CaptureStatusTracker.isEffectivelySilent(AudioLevelSnapshot(rawInputLevel: 0.008)))
    }
}

@MainActor
final class CaptionSessionCaptureStatusTests: XCTestCase {
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

    private final class TestClock {
        var now = ContinuousClock.now
    }

    private let manualDelay = ManualDelay()
    private let clock = TestClock()

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Capture status did not settle")
    }

    private func runningSession(mode: TranscriptionMode) async -> (CaptionSession, QuietSource) {
        let source = QuietSource()
        let session = CaptionSession(selectedSourceKind: .fake, requestedMode: mode)
        session.sourceFactory = { _, _ in source }
        session.delay = manualDelay.dependency
        session.captureStatusClock = { [clock] in clock.now }
        XCTAssertEqual(session.captureStatus, .stopped)
        session.start()
        await waitUntil { session.activeMode != nil }
        return (session, source)
    }

    /// Advances both clocks by one tick and lets the status task run.
    private func tick() async {
        await manualDelay.waitUntilScheduled(.seconds(1))
        clock.now += .seconds(1)
        await manualDelay.advance(by: .seconds(1))
    }

    func testTickMovesStartingToNoAudioAndStopIsImmediate() async {
        let (session, _) = await runningSession(mode: .onDevice)
        XCTAssertEqual(session.captureStatus, .starting)
        await tick()
        XCTAssertEqual(session.captureStatus, .starting)
        await tick()
        await waitUntil { session.captureStatus == .noAudio }
        await session.stop()
        XCTAssertEqual(session.captureStatus, .stopped)
        XCTAssertNil(session.captureStatusTask)
    }

    func testServerReconnectStallsUntilTheProviderSpeaksAgain() async {
        let (session, source) = await runningSession(mode: .server)
        source.resultContinuation.yield(.volatileSegments([]))
        await waitUntil { session.captureStatus == .captioning }

        source.resultContinuation.yield(.connectionInterrupted("Connection lost"))
        await waitUntil { session.captureStatus == .stalled }
        source.resultContinuation.yield(.connectionRestored)
        await waitUntil { !session.isReconnecting }
        XCTAssertEqual(session.captureStatus, .stalled)

        clock.now += .seconds(3)
        session.receiveAudioLevels(AudioLevelSnapshot(rawInputLevel: 0.2))
        source.resultContinuation.yield(.volatileSegments([]))
        await waitUntil { session.captureStatus == .captioning }
        await session.stop()
        XCTAssertEqual(session.captureStatus, .stopped)
    }
}
