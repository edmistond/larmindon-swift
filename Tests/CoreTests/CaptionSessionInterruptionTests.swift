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
        XCTAssertEqual(session.lastError, AudioInterruptionFailureReason
            .interruptionEndedWithoutResume.message)
        XCTAssertFalse(session.store.isRunning)
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
