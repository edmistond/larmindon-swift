import Foundation

public enum CaptionResult: Equatable, Sendable {
    case volatile(String)
    case finalized(String)
    case volatileSegments([CaptionSegment])
    case finalizedSegments([CaptionSegment])
    /// Terminal provider or delivery failure. Display as an error and stop the session.
    /// Cancellation requested by stop() must not emit a failure.
    case failure(String)
    /// The provider lost its connection and is reconnecting on its own. Capture keeps
    /// running; the session stays up. Not terminal — `connectionRestored` or `failure`
    /// follows.
    case connectionInterrupted(String)
    case connectionRestored

    /// Whether this result actually carries transcribed words.
    ///
    /// Arrival alone doesn't mean the backend is producing anything: Soniox emits a transcript
    /// update roughly once a second whether or not it heard speech, and
    /// `SonioxTranscriptionSource` yields `.volatileSegments` for every one of them. Only the
    /// ones with text mean the provider is doing work, which is what the server-mode level
    /// meter reports.
    public var carriesTranscription: Bool {
        switch self {
        case .volatile(let text), .finalized(let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .volatileSegments(let segments), .finalizedSegments(let segments):
            return segments.contains {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case .failure, .connectionInterrupted, .connectionRestored:
            return false
        }
    }
}

@MainActor
public protocol TranscriptionSource: AnyObject {
    var results: AsyncStream<CaptionResult> { get }
    var levelUpdates: AsyncStream<AudioLevelSnapshot> { get }
    var name: String { get }

    func start() async throws
    func stop() async
}

public enum TranscriptionSourceError: LocalizedError, Equatable {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}

/// Opt-in for providers whose capture is owned by CaptionSession and whose stop is
/// bounded. After capture ends they may drain independently, without accessing the
/// shared audio session. Sources that own their microphone must stop synchronously.
@MainActor
protocol BackgroundFinishingTranscriptionSource: TranscriptionSource {}
