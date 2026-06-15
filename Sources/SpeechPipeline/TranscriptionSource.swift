import Foundation

public enum CaptionResult: Equatable, Sendable {
    case volatile(String)
    case finalized(String)
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
