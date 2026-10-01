import Foundation

/// What the capture pipeline is doing, at the granularity a person can read at a glance.
///
/// This replaces a 20 Hz level meter on the main screen, so it is built to change rarely:
/// a few times a minute at most, and only on a real state transition.
public enum CaptureStatus: String, Equatable, Sendable {
    case stopped, starting, noAudio, listening, captioning, stalled

    public var title: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .noAudio: return "No audio"
        case .listening: return "Listening"
        case .captioning: return "Captioning"
        case .stalled: return "No captions"
        }
    }
}

/// The capture status state machine, kept free of tasks and clocks so every threshold can
/// be tested by passing instants rather than sleeping.
///
/// Inputs record *when* something last happened; `evaluate(at:)` turns that into a status.
/// Entry thresholds decide what the status should be, and a minimum dwell keeps it from
/// flapping between two states on a signal that hovers near a threshold.
struct CaptureStatusTracker {
    /// No audible buffer for this long, from capture running, reads as no audio.
    static let noAudioAfter: Duration = .seconds(2)
    /// Audible audio must have been arriving this long before Listening.
    static let listeningAfter: Duration = .seconds(1)
    /// Captioning holds this long after the last recognizer activity.
    static let captioningHold: Duration = .seconds(10)
    /// Server mode: audio flowing with no recognizer activity this long is a stall.
    static let stallAfter: Duration = .seconds(10)
    /// Minimum time in a state before moving to another running state.
    static let minimumDwell: Duration = .seconds(2)
    /// Snapshot levels are smoothed display levels (RMS × 8), so digital silence decays
    /// toward zero rather than reaching it. Below this — an RMS around -78 dBFS — no real
    /// microphone in a real room sits; a quiet room reads one to two orders higher.
    static let silenceLevel = 0.001

    typealias Instant = ContinuousClock.Instant

    private(set) var status: CaptureStatus = .stopped
    private var statusSince: Instant?
    private var isRunning = false
    private var mode: TranscriptionMode = .onDevice
    private var captureStartedAt: Instant?
    private var lastAudibleAt: Instant?
    private var audibleRunStartedAt: Instant?
    private var lastRecognizerActivityAt: Instant?
    /// Server mode, after a reconnect: stalled until the new connection proves itself.
    private var isAwaitingRecognizerAfterReconnect = false
    private var isReconnecting = false
    private var isInterrupted = false

    static func isEffectivelySilent(_ snapshot: AudioLevelSnapshot) -> Bool {
        snapshot.rawInputLevel < silenceLevel
    }

    /// Whether a result proves the recognizer is alive, which differs by provider.
    ///
    /// Soniox sends a transcript update about once a second even in silence, so in server
    /// mode any ordinary result is a heartbeat. SpeechAnalyzer reports only when it hears
    /// speech, so on-device only results that carry words count.
    static func isRecognizerActivity(_ result: CaptionResult, mode: TranscriptionMode) -> Bool {
        switch result {
        case .failure, .connectionInterrupted, .connectionRestored:
            return false
        case .volatile, .finalized, .volatileSegments, .finalizedSegments:
            return mode == .server || result.carriesTranscription
        }
    }

    /// Session start. Stays `.stalled` if an interruption is still being recovered from.
    mutating func start(mode: TranscriptionMode, at now: Instant) {
        isRunning = true
        self.mode = mode
        captureStartedAt = nil
        lastAudibleAt = nil
        audibleRunStartedAt = nil
        lastRecognizerActivityAt = nil
        isAwaitingRecognizerAfterReconnect = false
        isReconnecting = false
        enter(isInterrupted ? .stalled : .starting, at: now)
    }

    /// Capture is actually delivering, as opposed to the provider still loading. The
    /// no-audio clock starts here, so a slow model load does not read as a dead input.
    mutating func captureDidStart(at now: Instant) {
        guard isRunning, captureStartedAt == nil else { return }
        captureStartedAt = now
    }

    mutating func stop(at now: Instant) {
        isRunning = false
        isReconnecting = false
        _ = evaluate(at: now)
    }

    mutating func audioArrived(silent: Bool, at now: Instant) {
        guard isRunning else { return }
        if silent {
            audibleRunStartedAt = nil
            return
        }
        let continuesRun =
            audibleRunStartedAt != nil
            && lastAudibleAt.map { now - $0 < Self.noAudioAfter } == true
        if !continuesRun {
            audibleRunStartedAt = now
        }
        lastAudibleAt = now
    }

    mutating func recognizerActivity(at now: Instant) {
        guard isRunning else { return }
        lastRecognizerActivityAt = now
        isAwaitingRecognizerAfterReconnect = false
    }

    /// Feeds a provider result through `isRecognizerActivity` for the session's mode.
    mutating func received(_ result: CaptionResult, at now: Instant) {
        guard Self.isRecognizerActivity(result, mode: mode) else { return }
        recognizerActivity(at: now)
    }

    mutating func setConnectionState(reconnecting: Bool, interrupted: Bool, at now: Instant) {
        let wasStalled = isReconnecting || isInterrupted
        isReconnecting = isRunning && reconnecting
        isInterrupted = interrupted
        let isStalled = isReconnecting || isInterrupted
        if isStalled && !wasStalled {
            // Activity from before the drop says nothing about the new connection, so a
            // restored connection stays stalled until it sends something itself.
            lastRecognizerActivityAt = nil
            isAwaitingRecognizerAfterReconnect = isRunning && mode == .server
        }
        _ = evaluate(at: now)
    }

    /// Re-derives the status from what has happened so far and returns it.
    mutating func evaluate(at now: Instant) -> CaptureStatus {
        guard let target = targetStatus(at: now), target != status,
            canMove(to: target, at: now)
        else {
            return status
        }
        enter(target, at: now)
        return status
    }

    /// The status the inputs call for, or nil when nothing has crossed a threshold yet and
    /// the current status should stand.
    private func targetStatus(at now: Instant) -> CaptureStatus? {
        // Interruption recovery tears capture down and rebuilds it while the session is
        // nominally running; it reads as a stall throughout, never as Stopped.
        if isInterrupted { return .stalled }
        guard isRunning else { return .stopped }
        if isReconnecting { return .stalled }

        if let captureStartedAt {
            let lastHeard = max(lastAudibleAt ?? captureStartedAt, captureStartedAt)
            if now - lastHeard >= Self.noAudioAfter { return .noAudio }
        }
        if let lastRecognizerActivityAt, now - lastRecognizerActivityAt < Self.captioningHold {
            return .captioning
        }
        if isAwaitingRecognizerAfterReconnect { return .stalled }
        guard let audibleRunStartedAt else { return nil }

        if isServerStalled(audibleSince: audibleRunStartedAt, at: now) { return .stalled }
        if now - audibleRunStartedAt >= Self.listeningAfter { return .listening }
        return nil
    }

    /// Audio flowing to the server with no recognizer activity for `stallAfter`.
    ///
    /// Only server mode treats silence of results as a stall. SpeechAnalyzer reports only
    /// when it hears speech, so on-device a long gap between results is a quiet room, not a
    /// broken recognizer; it falls back to Listening instead.
    private func isServerStalled(audibleSince: Instant, at now: Instant) -> Bool {
        guard mode == .server, let captureStartedAt else { return false }
        let quietSince = max(
            audibleSince,
            lastRecognizerActivityAt ?? captureStartedAt,
            captureStartedAt
        )
        return now - quietSince >= Self.stallAfter
    }

    private func canMove(to target: CaptureStatus, at now: Instant) -> Bool {
        if target == .stopped { return true }
        if target == .stalled, isReconnecting || isInterrupted { return true }
        // Starting is a moment, not a state to read; its own entry thresholds govern.
        if status == .starting || status == .stopped { return true }
        guard let statusSince else { return true }
        return now - statusSince >= Self.minimumDwell
    }

    private mutating func enter(_ next: CaptureStatus, at now: Instant) {
        guard next != status else { return }
        status = next
        statusSince = now
    }
}
