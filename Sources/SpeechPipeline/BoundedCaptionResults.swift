import Foundation

/// Partial previews are replaceable. Finalized speech is not: any eviction of a
/// final event ends delivery with an explicit error instead of a successful transcript.
@MainActor
final class BoundedCaptionResults {
    static let overflowMessage =
        "Caption delivery fell behind and finalized text was lost. Restart captioning to continue."
    let stream: AsyncStream<CaptionResult>
    private let continuation: AsyncStream<CaptionResult>.Continuation
    private var isFinished = false
    private(set) var didFail = false

    init(capacity: Int = 64) {
        precondition(capacity > 0)
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(capacity))
    }

    /// False ends publishing. Only failed delivery should retire the connection;
    /// a cancelled consumer may still want the provider to finish gracefully.
    @discardableResult
    func yield(_ result: CaptionResult) -> Bool {
        guard !isFinished else { return false }
        if case .failure = result {
            didFail = true
            continuation.yield(result)
            finish()
            return false
        }
        switch continuation.yield(result) {
        case .enqueued:
            return true
        case .dropped(let dropped):
            switch dropped {
            case .volatile, .volatileSegments:
                return true
            case .finalized, .finalizedSegments, .failure:
                didFail = true
                // bufferingNewest guarantees the terminal error itself is retained.
                continuation.yield(.failure(Self.overflowMessage))
                finish()
                return false
            }
        case .terminated:
            finish()
            return false
        @unknown default:
            didFail = true
            continuation.yield(.failure(Self.overflowMessage))
            finish()
            return false
        }
    }

    func finish() {
        isFinished = true
        continuation.finish()
    }
}
