import Foundation

/// What the audio system told us happened, stripped of `AVAudioSession` types.
///
/// Deliberately platform-agnostic: `AVAudioSession` doesn't exist on macOS, and keeping the
/// policy free of it means the decision table below runs in tests on either platform without
/// an audio session, a device, or a real interruption existing. Translation from the
/// notification's `userInfo` happens once, at the observer in `AudioRouteManager`.
public enum AudioInterruptionEvent: Equatable, Sendable {
    /// Something else took the audio system — a call, Siri, an alarm, another recorder.
    /// Buffers stop arriving immediately and the session is already inactive by the time
    /// this lands.
    case began

    /// The interruption finished. `shouldResume` mirrors `AVAudioSession`'s option flag:
    /// when it's false the system is saying the audio focus did *not* come back to us.
    case ended(shouldResume: Bool)

    /// The whole audio stack was torn down and rebuilt. Every engine, session, and format
    /// object we hold is stale regardless of what any resume flag says.
    case mediaServicesReset
}

/// Decides what to do about an interruption. Pure — it reads no state and touches no audio
/// API, so every branch is reachable from a unit test.
///
/// The naive handler is "on `.ended`, start again", and it's wrong in four separate ways
/// that this table encodes:
///
/// - `.ended` can arrive *without* `shouldResume`, meaning the focus didn't come back to us.
/// - It can arrive when we weren't running, where restarting would begin recording something
///   the user never asked for. For a captioning app that's the worst of the four.
/// - Reactivating can fail transiently while the interrupting app finishes letting go, so a
///   single attempt gives up too early.
/// - `mediaServicesReset` needs a rebuild whatever the flags say.
public enum AudioInterruptionPolicy {
    public enum Decision: Equatable, Sendable {
        /// Do nothing. Either there's nothing to recover, or recovering now would be wrong.
        case hold
        /// Tear down and start again immediately.
        case restart
        /// A restart attempt failed in a way that's plausibly transient. Wait, then retry.
        case retry(after: Duration)
        /// Out of road. Surface it to the user — backgrounded, this is the only signal they get.
        case giveUp(reason: AudioInterruptionFailureReason)
    }

    /// Four attempts spans roughly 7.5 seconds of backoff, which comfortably covers the
    /// hand-off after a phone call ends. Beyond that the session isn't coming back on its
    /// own and silently retrying just burns battery in the user's pocket.
    static let maxAttempts = 4

    public static func decision(
        for event: AudioInterruptionEvent,
        wasRunning: Bool,
        attempt: Int
    ) -> Decision {
        // Nothing was running, so there is nothing to resume. Restarting here would start
        // capturing audio the user never asked for — the app would spontaneously begin
        // recording after an unrelated phone call ended.
        guard wasRunning else { return .hold }

        switch event {
        case .began:
            // The session is already inactive and buffers have stopped. There's nothing to
            // do but wait for `.ended`; the running source is left in place so recovery is
            // a plain restart rather than a partial rebuild.
            return .hold

        case .ended(let shouldResume):
            guard shouldResume else {
                return .giveUp(reason: .interruptionEndedWithoutResume)
            }
            guard attempt < maxAttempts else {
                return .giveUp(reason: .restartAttemptsExhausted)
            }
            return .restart

        case .mediaServicesReset:
            guard attempt < maxAttempts else {
                return .giveUp(reason: .restartAttemptsExhausted)
            }
            return .restart
        }
    }

    /// Follow-up decision once a restart has actually been tried and failed.
    ///
    /// Split from `decision(for:wasRunning:attempt:)` because the inputs genuinely differ:
    /// here the interruption is over and the only question is whether the failure looks
    /// transient enough to be worth waiting out.
    public static func decisionAfterFailedRestart(attempt: Int) -> Decision {
        guard attempt < maxAttempts else {
            return .giveUp(reason: .restartAttemptsExhausted)
        }
        return .retry(after: backoff(forAttempt: attempt))
    }

    /// 0.5s, 1s, 2s, 4s. Starts short because the common case — the other app releasing the
    /// session a moment after the interruption ends — resolves almost immediately.
    static func backoff(forAttempt attempt: Int) -> Duration {
        let clamped = max(1, min(attempt, maxAttempts))
        return .milliseconds(500 * (1 << (clamped - 1)))
    }
}

/// Why recovery stopped trying. Carries the user-facing copy because this is what reaches
/// the user through a local notification when they're in another app, and it's the only
/// thing they'll see.
public enum AudioInterruptionFailureReason: Equatable, Sendable {
    case interruptionEndedWithoutResume
    case restartAttemptsExhausted

    public var message: String {
        switch self {
        case .interruptionEndedWithoutResume:
            return "Another app took over the microphone. Captions stopped."
        case .restartAttemptsExhausted:
            return "Captions could not restart after an audio interruption."
        }
    }

    /// Short form for the diagnostics bundle, which is how a backgrounded failure gets
    /// investigated after the fact.
    public var diagnosticID: String {
        switch self {
        case .interruptionEndedWithoutResume:
            return "ended_without_resume"
        case .restartAttemptsExhausted:
            return "attempts_exhausted"
        }
    }
}
