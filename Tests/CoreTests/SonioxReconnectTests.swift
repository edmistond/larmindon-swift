import AVFAudio
import Foundation
import XCTest
@testable import LarmindonKit

/// Network changes mid-session: bundle `larmindon-diagnostics-BBE900D2` showed every
/// transport loss (Wi-Fi → cellular while driving, a timeout in the background) ending the
/// whole session. In the foreground that meant pressing Start again; in the background it
/// stopped capture, iOS suspended the app, and captions were simply gone.
@MainActor
final class SonioxReconnectTests: XCTestCase {
    private let delay = ManualDelay()

    private func makeSource(
        transports: FakeWebSocketTransportSequence,
        path: FakeNetworkPath,
        diagnostics: DiagnosticRecorder = DiagnosticRecorder(capacity: 200)
    ) -> SonioxTranscriptionSource {
        let source = SonioxTranscriptionSource(
            apiKey: "test-key",
            diagnostics: diagnostics,
            makeTransport: { transports.next() },
            makePathObserver: { path }
        )
        source.delay = delay.dependency
        return source
    }

    private func next(
        _ iterator: inout AsyncStream<CaptionResult>.Iterator,
        where predicate: (CaptionResult) -> Bool
    ) async -> CaptionResult? {
        while let result = await iterator.next(isolation: #isolation) {
            if predicate(result) { return result }
        }
        return nil
    }

    private static func isFinalized(_ result: CaptionResult) -> Bool {
        if case .finalizedSegments = result { return true }
        return false
    }

    private static func isVolatile(_ result: CaptionResult) -> Bool {
        if case .volatileSegments = result { return true }
        return false
    }

    private static func isInterrupted(_ result: CaptionResult) -> Bool {
        if case .connectionInterrupted = result { return true }
        return false
    }

    private static func isRestoredOrFailed(_ result: CaptionResult) -> Bool {
        switch result {
        case .connectionRestored, .failure: return true
        default: return false
        }
    }

    func testDroppedConnectionReconnectsAndKeepsStreaming() async throws {
        let transports = FakeWebSocketTransportSequence(count: 2)
        let diagnostics = DiagnosticRecorder(capacity: 200)
        let source = makeSource(transports: transports, path: FakeNetworkPath(), diagnostics: diagnostics)
        let (frames, frameContinuation) = AsyncStream<CapturedAudioFrame>.makeStream()
        var results = source.results.makeAsyncIterator()
        try await source.start(audioFrames: frames)

        // Words already final but not yet a sentence are still in the preview when the
        // network drops. A new stream won't know about them.
        await transports[0].enqueue(.text(#"{"tokens":[{"text":"Great","is_final":true,"speaker":"1"}]}"#))
        let preview = await next(&results, where: Self.isVolatile)
        XCTAssertEqual(preview, .volatileSegments([CaptionSegment(text: "Great", speakerID: "1")]))

        await transports[0].dropConnection()

        let flushed = await next(&results, where: Self.isFinalized)
        XCTAssertEqual(flushed, .finalizedSegments([CaptionSegment(text: "Great", speakerID: "1")]))
        let interrupted = await next(&results, where: Self.isInterrupted)
        XCTAssertEqual(interrupted, .connectionInterrupted(SonioxTranscriptionSource.connectionLostMessage))
        let restored = await next(&results, where: Self.isRestoredOrFailed)
        XCTAssertEqual(restored, .connectionRestored)
        XCTAssertEqual(transports.connectionsRequested, 2)
        let replacementConfiguration = await transports[1].sentTextMessages
        XCTAssertEqual(replacementConfiguration.count, 1, "the new stream must be configured")

        // Capture was never interrupted; its frames now go to the new connection.
        frameContinuation.yield(CapturedAudioFrame(buffer: try makeTenMillisecondBuffer()))
        await transports[1].waitForBinaryMessageCount(1)

        await transports[1].enqueue(.text(#"{"tokens":[{"text":"Back.","is_final":true}]}"#))
        let resumed = await next(&results, where: Self.isFinalized)
        XCTAssertEqual(resumed, .finalizedSegments([CaptionSegment(text: "Back.")]))

        // Stop still finishes the (new) stream gracefully.
        frameContinuation.finish()
        let stop = Task { await source.stop() }
        await transports[1].waitForTextMessageCount(2)
        await transports[1].enqueue(.text(#"{"tokens":[],"finished":true}"#))
        await stop.value
        let closeCodes = await transports[1].closeCodes
        XCTAssertEqual(closeCodes.last, .normalClosure)

        let names = await diagnostics.snapshot().map(\.name)
        XCTAssertTrue(names.contains("soniox_connection_lost"))
        XCTAssertTrue(names.contains("soniox_reconnected"))
        XCTAssertFalse(names.contains("soniox_error"))
    }

    func testReconnectWaitsForUsableNetworkPath() async throws {
        let transports = FakeWebSocketTransportSequence(count: 2)
        let path = FakeNetworkPath(isSatisfied: false)
        let source = makeSource(transports: transports, path: path)
        let (frames, frameContinuation) = AsyncStream<CapturedAudioFrame>.makeStream()
        var results = source.results.makeAsyncIterator()
        try await source.start(audioFrames: frames)

        await transports[0].dropConnection()
        _ = await next(&results, where: Self.isInterrupted)
        await path.waitUntilSomeoneIsWaiting()
        XCTAssertEqual(transports.connectionsRequested, 1, "no attempt while the path is down")

        path.setSatisfied(true)
        let restored = await next(&results, where: Self.isRestoredOrFailed)
        XCTAssertEqual(restored, .connectionRestored)
        XCTAssertEqual(transports.connectionsRequested, 2)

        frameContinuation.finish()
        let stop = Task { await source.stop() }
        await transports[1].waitForTextMessageCount(2)
        await transports[1].enqueue(.text(#"{"tokens":[],"finished":true}"#))
        await stop.value
    }

    func testFailedAttemptsBackOffAndANetworkChangeCutsTheWaitShort() async throws {
        let transports = FakeWebSocketTransportSequence(count: 4)
        await transports[1].failConnect(with: .connectionFailed("The Internet connection appears to be offline."))
        await transports[2].failConnect(with: .connectionFailed("The Internet connection appears to be offline."))
        let path = FakeNetworkPath()
        let diagnostics = DiagnosticRecorder(capacity: 200)
        let source = makeSource(transports: transports, path: path, diagnostics: diagnostics)
        let (frames, frameContinuation) = AsyncStream<CapturedAudioFrame>.makeStream()
        var results = source.results.makeAsyncIterator()
        try await source.start(audioFrames: frames)

        await transports[0].dropConnection()

        // Attempt 1 is immediate and fails; attempt 2 waits out a 1 s backoff.
        await delay.waitUntilScheduled(.seconds(1))
        XCTAssertEqual(transports.connectionsRequested, 2)
        await delay.advance(by: .seconds(1))

        // Attempt 2 fails too. Attempt 3's 2 s backoff is cut short by Wi-Fi joining.
        await delay.waitUntilScheduled(.seconds(2))
        XCTAssertEqual(transports.connectionsRequested, 3)
        await path.waitUntilSomeoneIsWaiting()
        path.setSatisfied(true)

        let restored = await next(&results, where: Self.isRestoredOrFailed)
        XCTAssertEqual(restored, .connectionRestored)
        XCTAssertEqual(transports.connectionsRequested, 4)
        let failures = await diagnostics.snapshot().filter { $0.name == "soniox_reconnect_failed" }
        XCTAssertEqual(failures.count, 2)

        frameContinuation.finish()
        let stop = Task { await source.stop() }
        await transports[3].waitForTextMessageCount(2)
        await transports[3].enqueue(.text(#"{"tokens":[],"finished":true}"#))
        await stop.value
    }

    func testRejectedCredentialsFailWithoutReconnecting() async throws {
        let transports = FakeWebSocketTransportSequence(count: 1)
        let source = makeSource(transports: transports, path: FakeNetworkPath())
        let (frames, frameContinuation) = AsyncStream<CapturedAudioFrame>.makeStream()
        var results = source.results.makeAsyncIterator()
        try await source.start(audioFrames: frames)

        await transports[0].enqueue(
            .text(#"{"tokens":[],"error_code":401,"error_type":"unauthenticated","error_message":"Invalid API key."}"#)
        )
        let failure = await next(&results) {
            if case .failure = $0 { return true }
            return Self.isInterrupted($0)
        }
        XCTAssertEqual(failure, .failure("Invalid API key."))
        XCTAssertEqual(transports.connectionsRequested, 1)

        frameContinuation.finish()
        await source.stop()
    }

    func testRecoverableErrorsAreTransportLossAndProviderRetryableErrors() {
        XCTAssertTrue(SonioxTranscriptionSource.isRecoverable(SonioxRealtimeClientError.transport("lost")))
        XCTAssertTrue(
            SonioxTranscriptionSource.isRecoverable(
                SonioxRealtimeClientError.provider(
                    SonioxProviderError(
                        code: 413, type: "max_duration_reached", message: "", moreInfo: nil, requestID: nil)
                )
            )
        )
        XCTAssertFalse(
            SonioxTranscriptionSource.isRecoverable(
                SonioxRealtimeClientError.provider(
                    SonioxProviderError(
                        code: 401, type: "unauthenticated", message: "", moreInfo: nil, requestID: nil)
                )
            )
        )
        XCTAssertFalse(SonioxTranscriptionSource.isRecoverable(SonioxRealtimeClientError.invalidResponse("junk")))
        XCTAssertFalse(SonioxTranscriptionSource.isRecoverable(SonioxRealtimeClientError.cancelled))
    }

    func testSilentSocketIsTreatedAsLostAndReplaced() async throws {
        let transports = FakeWebSocketTransportSequence(count: 2)
        let source = makeSource(transports: transports, path: FakeNetworkPath())
        let (frames, frameContinuation) = AsyncStream<CapturedAudioFrame>.makeStream()
        var results = source.results.makeAsyncIterator()
        try await source.start(audioFrames: frames)

        // Nothing from the server, and nothing from URLSession either.
        await delay.waitUntilScheduled(.seconds(20))
        await delay.advance(by: .seconds(20))

        let interrupted = await next(&results, where: Self.isInterrupted)
        XCTAssertNotNil(interrupted)
        let restored = await next(&results, where: Self.isRestoredOrFailed)
        XCTAssertEqual(restored, .connectionRestored)
        XCTAssertEqual(transports.connectionsRequested, 2)
        let staleCloses = await transports[0].closeCodes
        XCTAssertTrue(staleCloses.contains(.goingAway), "the stalled socket must be closed")

        frameContinuation.finish()
        let stop = Task { await source.stop() }
        await transports[1].waitForTextMessageCount(2)
        await transports[1].enqueue(.text(#"{"tokens":[],"finished":true}"#))
        await stop.value
    }

    func testGivesUpAfterMaximumOutage() async throws {
        let transports = FakeWebSocketTransportSequence(count: 1)
        let path = FakeNetworkPath(isSatisfied: false)
        let diagnostics = DiagnosticRecorder(capacity: 200)
        let source = makeSource(transports: transports, path: path, diagnostics: diagnostics)
        let (frames, frameContinuation) = AsyncStream<CapturedAudioFrame>.makeStream()
        var results = source.results.makeAsyncIterator()
        try await source.start(audioFrames: frames)

        await transports[0].dropConnection()
        _ = await next(&results, where: Self.isInterrupted)
        await delay.waitUntilScheduled(.seconds(600))
        await delay.advance(by: .seconds(600))

        let failure = await next(&results, where: Self.isRestoredOrFailed)
        XCTAssertEqual(failure, .failure(SonioxTranscriptionSource.reconnectGaveUpMessage))
        XCTAssertEqual(transports.connectionsRequested, 1)
        let names = await diagnostics.snapshot().map(\.name)
        XCTAssertTrue(names.contains("soniox_reconnect_gave_up"))

        frameContinuation.finish()
        await source.stop()
    }

    func testStopWhileReconnectingEndsCleanly() async throws {
        let transports = FakeWebSocketTransportSequence(count: 1)
        let path = FakeNetworkPath(isSatisfied: false)
        let source = makeSource(transports: transports, path: path)
        let (frames, frameContinuation) = AsyncStream<CapturedAudioFrame>.makeStream()
        var results = source.results.makeAsyncIterator()
        try await source.start(audioFrames: frames)

        await transports[0].dropConnection()
        _ = await next(&results, where: Self.isInterrupted)
        await path.waitUntilSomeoneIsWaiting()

        frameContinuation.finish()
        await source.stop()

        var remaining: [CaptionResult] = []
        while let result = await results.next(isolation: #isolation) { remaining.append(result) }
        XCTAssertFalse(remaining.contains { if case .failure = $0 { return true }; return false })
        XCTAssertEqual(transports.connectionsRequested, 1)
    }

    private func makeTenMillisecondBuffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<480 { samples[index] = sin(Float(index) * 0.1) * 0.2 }
        }
        return buffer
    }
}

@MainActor
final class CaptionSessionReconnectTests: XCTestCase {
    private final class ScriptedSource: TranscriptionSource {
        let name = "Scripted"
        let results: AsyncStream<CaptionResult>
        let continuation: AsyncStream<CaptionResult>.Continuation
        let levelUpdates = AsyncStream<AudioLevelSnapshot> { $0.finish() }

        init() { (results, continuation) = AsyncStream.makeStream() }
        func start() async throws {}
        func stop() async {}
    }

    private final class SpyNotifier: CaptionFailureNotifying {
        private(set) var messages: [String] = []
        func prepare() async {}
        func notifyCaptionsStopped(message: String) async { messages.append(message) }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Transition did not complete")
    }

    private func runningSession(notifier: SpyNotifier = SpyNotifier()) async -> (CaptionSession, ScriptedSource) {
        let source = ScriptedSource()
        let session = CaptionSession(selectedSourceKind: .fake, failureNotifier: notifier)
        session.sourceFactory = { _, _ in source }
        session.delay = ManualDelay().dependency
        session.start()
        await waitUntil { session.activeMode != nil }
        return (session, source)
    }

    func testReconnectKeepsTheSessionRunningAndSaysSo() async {
        let (session, source) = await runningSession()

        source.continuation.yield(.connectionInterrupted("Lost the connection."))
        await waitUntil { session.isReconnecting }
        XCTAssertTrue(session.store.isRunning, "a reconnect must not stop captions")
        XCTAssertEqual(session.lastError, "Lost the connection.")
        XCTAssertEqual(session.speechAnalyzerState, "Reconnecting")

        source.continuation.yield(.connectionRestored)
        await waitUntil { !session.isReconnecting }
        XCTAssertTrue(session.store.isRunning)
        XCTAssertNil(session.lastError)
        XCTAssertEqual(session.speechAnalyzerState, "Running Scripted")

        await session.stop()
    }

    func testProviderFailureStopsAndNotifies() async {
        let notifier = SpyNotifier()
        let (session, source) = await runningSession(notifier: notifier)

        source.continuation.yield(.connectionInterrupted("Lost the connection."))
        source.continuation.yield(.failure("Couldn’t reconnect."))
        await waitUntil { !session.store.isRunning && !notifier.messages.isEmpty }
        XCTAssertFalse(session.isReconnecting)
        XCTAssertEqual(session.lastError, "Couldn’t reconnect.")
        XCTAssertEqual(notifier.messages, ["Couldn’t reconnect."])
    }
}
