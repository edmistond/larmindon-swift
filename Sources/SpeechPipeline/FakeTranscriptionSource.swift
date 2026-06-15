import Foundation

public final class FakeTranscriptionSource: TranscriptionSource {
    public let name = "Fake"
    public let results: AsyncStream<CaptionResult>

    private let continuation: AsyncStream<CaptionResult>.Continuation
    private var task: Task<Void, Never>?

    private let script: [CaptionResult] = [
        .volatile("Can you hear me"),
        .volatile("Can you hear me in the back"),
        .finalized("Can you hear me in the back?"),
        .volatile("This is Larmindon"),
        .volatile("This is Larmindon running on device"),
        .finalized("This is Larmindon running on device."),
        .volatile("The final text stays stable"),
        .volatile("The final text stays stable while this tail changes"),
        .finalized("The final text stays stable while this tail changes."),
        .volatile("Use it in a noisy room"),
        .volatile("Use it in a noisy room or in the car"),
        .finalized("Use it in a noisy room or in the car."),
    ]

    public init() {
        var capturedContinuation: AsyncStream<CaptionResult>.Continuation!
        self.results = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    public func start() async throws {
        guard task == nil else { return }

        task = Task { [script, continuation] in
            var index = 0
            while !Task.isCancelled {
                continuation.yield(script[index % script.count])
                index += 1
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    public func stop() async {
        task?.cancel()
        task = nil
    }
}
