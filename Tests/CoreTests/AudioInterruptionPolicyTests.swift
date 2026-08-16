import XCTest
@testable import LarmindonKit

/// The recovery table from `AudioInterruptionPolicy`. These run on macOS and the iOS
/// Simulator alike — the policy holds no `AVAudioSession` types precisely so that the
/// branches that only occur during a real phone call are still reachable in CI.
final class AudioInterruptionPolicyTests: XCTestCase {

    // MARK: - Nothing running

    /// The bug this exists to prevent: captions were stopped, an unrelated call ends, and
    /// the app starts recording on its own. Worse for a captioning app than a dropped
    /// session, because the user never asked for it and may not notice.
    func testEndedWhileStoppedDoesNotStartCaptions() {
        XCTAssertEqual(
            AudioInterruptionPolicy.decision(
                for: .ended(shouldResume: true),
                wasRunning: false,
                attempt: 0
            ),
            .hold
        )
    }

    func testMediaServicesResetWhileStoppedDoesNothing() {
        XCTAssertEqual(
            AudioInterruptionPolicy.decision(
                for: .mediaServicesReset,
                wasRunning: false,
                attempt: 0
            ),
            .hold
        )
    }

    // MARK: - Interruption begins

    func testBeganHoldsRatherThanTearingDown() {
        XCTAssertEqual(
            AudioInterruptionPolicy.decision(for: .began, wasRunning: true, attempt: 0),
            .hold
        )
    }

    // MARK: - Interruption ends

    func testEndedWithResumeRestarts() {
        XCTAssertEqual(
            AudioInterruptionPolicy.decision(
                for: .ended(shouldResume: true),
                wasRunning: true,
                attempt: 0
            ),
            .restart
        )
    }

    /// No `shouldResume` means the audio focus did not come back to us. Restarting anyway
    /// mostly just fails, and it's a case the user has to be told about rather than one to
    /// retry silently.
    func testEndedWithoutResumeGivesUpAndSaysWhy() {
        XCTAssertEqual(
            AudioInterruptionPolicy.decision(
                for: .ended(shouldResume: false),
                wasRunning: true,
                attempt: 0
            ),
            .giveUp(reason: .interruptionEndedWithoutResume)
        )
    }

    // MARK: - Media services reset

    /// A reset invalidates every engine and session object regardless of resume flags, so
    /// it must not be filtered through the same `shouldResume` check as `.ended`.
    func testMediaServicesResetRestartsRegardlessOfResumeSemantics() {
        XCTAssertEqual(
            AudioInterruptionPolicy.decision(
                for: .mediaServicesReset,
                wasRunning: true,
                attempt: 0
            ),
            .restart
        )
    }

    // MARK: - Retry and exhaustion

    func testFailedRestartRetriesWithBackoff() {
        XCTAssertEqual(
            AudioInterruptionPolicy.decisionAfterFailedRestart(attempt: 1),
            .retry(after: .milliseconds(500))
        )
        XCTAssertEqual(
            AudioInterruptionPolicy.decisionAfterFailedRestart(attempt: 2),
            .retry(after: .milliseconds(1000))
        )
        XCTAssertEqual(
            AudioInterruptionPolicy.decisionAfterFailedRestart(attempt: 3),
            .retry(after: .milliseconds(2000))
        )
    }

    /// Bounded, not infinite: an unrecoverable session would otherwise retry forever in the
    /// user's pocket.
    func testRepeatedRestartFailuresGiveUpRatherThanLoop() {
        XCTAssertEqual(
            AudioInterruptionPolicy.decisionAfterFailedRestart(
                attempt: AudioInterruptionPolicy.maxAttempts
            ),
            .giveUp(reason: .restartAttemptsExhausted)
        )
    }

    func testEndedStopsRestartingOnceAttemptsAreExhausted() {
        XCTAssertEqual(
            AudioInterruptionPolicy.decision(
                for: .ended(shouldResume: true),
                wasRunning: true,
                attempt: AudioInterruptionPolicy.maxAttempts
            ),
            .giveUp(reason: .restartAttemptsExhausted)
        )
    }

    func testBackoffGrowsMonotonicallyAndStaysBounded() {
        let delays = (1...AudioInterruptionPolicy.maxAttempts).map {
            AudioInterruptionPolicy.backoff(forAttempt: $0)
        }
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertEqual(delays.last, .milliseconds(4000))
    }

    // MARK: - User-facing copy

    /// Both reasons reach the user through a local notification while they're in another
    /// app, so neither may be empty or a bare enum name.
    func testEveryFailureReasonCarriesAMessageAndDiagnosticID() {
        for reason: AudioInterruptionFailureReason in [
            .interruptionEndedWithoutResume,
            .restartAttemptsExhausted,
        ] {
            XCTAssertFalse(reason.message.isEmpty)
            XCTAssertFalse(reason.diagnosticID.isEmpty)
        }
    }
}
