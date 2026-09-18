#if os(iOS)
import XCTest
@testable import LarmindonKit

/// Covers the wiring rather than the decision table — that `AudioRouteManager`'s callback
/// reaches `CaptionSession`, and that a give-up actually reaches the user.
///
/// iOS-only because interruptions are an `AVAudioSession` concept. Runs in the Simulator:
/// nothing here starts a live source, so SpeechAnalyzer's device-only restriction doesn't
/// apply. Interruptions are injected through the public `onAudioInterruption` callback,
/// which is the same entry point the real notification observer uses.
@MainActor
final class CaptionSessionInterruptionTests: XCTestCase {

    private final class SpyNotifier: CaptionFailureNotifying {
        private(set) var prepareCount = 0
        private(set) var notifiedReasons: [AudioInterruptionFailureReason] = []

        func prepare() async { prepareCount += 1 }

        func notifyCaptionsStopped(reason: AudioInterruptionFailureReason) async {
            notifiedReasons.append(reason)
        }
    }

    private func makeSession(notifier: SpyNotifier) -> CaptionSession {
        CaptionSession(failureNotifier: notifier)
    }

    /// Recovery tests use the fake source so the restart genuinely succeeds in the
    /// Simulator. With `.live` the restart would fail on SpeechAnalyzer's device-only
    /// restriction, and the test would be asserting the failure path by accident.
    private func makeRecoverableSession(notifier: SpyNotifier) -> CaptionSession {
        CaptionSession(selectedSourceKind: .fake, failureNotifier: notifier)
    }

    /// Polls rather than sleeping a fixed interval: the give-up path hands off to a Task,
    /// and a hard sleep would either be flaky or slow.
    private func waitUntil(
        _ condition: () -> Bool,
        timeout: Duration = .seconds(2)
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testInterruptionEndingWithoutResumeNotifiesTheUser() async {
        let notifier = SpyNotifier()
        let session = makeSession(notifier: notifier)
        session.store.isRunning = true

        session.routeManager.onAudioInterruption?(.began)
        XCTAssertEqual(session.speechAnalyzerState, "Interrupted")

        session.routeManager.onAudioInterruption?(.ended(shouldResume: false))
        await waitUntil { !notifier.notifiedReasons.isEmpty }

        XCTAssertEqual(notifier.notifiedReasons, [.interruptionEndedWithoutResume])
        XCTAssertEqual(
            session.lastError,
            AudioInterruptionFailureReason
                .interruptionEndedWithoutResume.message)
        XCTAssertFalse(session.store.isRunning)
        // Resolved, not still pending: the session is stopped, not interrupted.
        XCTAssertFalse(session.isInterrupted)
    }

    /// The failure mode that matters most: the app must never decide to start capturing on
    /// its own because an unrelated interruption ended.
    func testInterruptionEndingWhileStoppedDoesNotStartCaptions() async {
        let notifier = SpyNotifier()
        let session = makeSession(notifier: notifier)
        XCTAssertFalse(session.store.isRunning)

        session.routeManager.onAudioInterruption?(.began)
        session.routeManager.onAudioInterruption?(.ended(shouldResume: true))
        // Short: this asserts something never happens, so the wait is pure cost. A Task hop
        // needs milliseconds, not seconds.
        await waitUntil({ session.store.isRunning }, timeout: .milliseconds(300))

        XCTAssertFalse(session.store.isRunning)
        XCTAssertTrue(notifier.notifiedReasons.isEmpty)
    }

    /// Stopping captions during a call, then having them resume when it ends, would be the
    /// app overriding an explicit decision.
    func testStoppingDuringAnInterruptionDisarmsTheResume() async {
        let notifier = SpyNotifier()
        let session = makeSession(notifier: notifier)
        session.store.isRunning = true

        session.routeManager.onAudioInterruption?(.began)
        await session.stop()

        session.routeManager.onAudioInterruption?(.ended(shouldResume: true))
        await waitUntil({ session.store.isRunning }, timeout: .milliseconds(300))

        XCTAssertFalse(session.store.isRunning)
        XCTAssertTrue(notifier.notifiedReasons.isEmpty)
    }

    func testInterruptionEndingWithResumeRestartsCaptions() async {
        let notifier = SpyNotifier()
        let session = makeRecoverableSession(notifier: notifier)
        session.store.isRunning = true

        session.routeManager.onAudioInterruption?(.began)
        // Running, but nothing is arriving — the status line has to say so rather than
        // keep claiming "Listening".
        XCTAssertTrue(session.isInterrupted)

        session.routeManager.onAudioInterruption?(.ended(shouldResume: true))
        await waitUntil { session.activeMode != nil }

        XCTAssertTrue(session.store.isRunning)
        XCTAssertNotNil(session.activeMode)
        XCTAssertFalse(session.isInterrupted)
        XCTAssertTrue(notifier.notifiedReasons.isEmpty)
    }

    /// A media-server reset arrives on its own, with no `.began` to pair with it. Reading
    /// only the latched "were we running?" flag would leave this case permanently
    /// unrecovered — a restart of the audio stack would silently end the session.
    func testMediaServicesResetRecoversWithoutAPrecedingBegan() async {
        let notifier = SpyNotifier()
        let session = makeRecoverableSession(notifier: notifier)
        session.store.isRunning = true

        session.routeManager.onAudioInterruption?(.mediaServicesReset)
        await waitUntil { session.activeMode != nil }

        XCTAssertTrue(session.store.isRunning)
        XCTAssertNotNil(session.activeMode)
        XCTAssertTrue(notifier.notifiedReasons.isEmpty)
    }

    /// Same event, opposite expectation: a reset while stopped must stay stopped.
    func testMediaServicesResetWhileStoppedStaysStopped() async {
        let notifier = SpyNotifier()
        let session = makeRecoverableSession(notifier: notifier)

        session.routeManager.onAudioInterruption?(.mediaServicesReset)
        await waitUntil({ session.store.isRunning }, timeout: .milliseconds(300))

        XCTAssertFalse(session.store.isRunning)
        XCTAssertNil(session.activeMode)
    }

    /// A give-up notification is worth reading precisely because it's rare. Repeated
    /// interruptions must not each produce one.
    func testOnlyGiveUpNotifiesNotEveryInterruption() async {
        let notifier = SpyNotifier()
        let session = makeSession(notifier: notifier)
        session.store.isRunning = true

        session.routeManager.onAudioInterruption?(.began)
        await waitUntil(
            { !notifier.notifiedReasons.isEmpty },
            timeout: .milliseconds(200)
        )

        XCTAssertTrue(notifier.notifiedReasons.isEmpty)
    }
}
#endif
