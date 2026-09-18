import Foundation

/// Runtime recognition errors end the result stream; they are never caption text.
/// Stop marks this first so late errors from framework cancellation stay silent.
@MainActor
final class TranscriptionFailureReporter {
    private let continuation: AsyncStream<CaptionResult>.Continuation
    private var isTerminated = false

    init(continuation: AsyncStream<CaptionResult>.Continuation) {
        self.continuation = continuation
    }

    func report(_ error: any Error, context: String) {
        guard !isTerminated, !Task.isCancelled else { return }
        isTerminated = true
        continuation.yield(.failure("\(context): \(error.localizedDescription)"))
        continuation.finish()
    }

    func stop() {
        isTerminated = true
        continuation.finish()
    }
}
