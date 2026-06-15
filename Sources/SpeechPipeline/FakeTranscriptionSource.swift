import Foundation

public final class FakeTranscriptionSource: TranscriptionSource {
    public let name = "Fake"
    public let results: AsyncStream<CaptionResult>
    public let levelUpdates: AsyncStream<AudioLevelSnapshot>

    private let continuation: AsyncStream<CaptionResult>.Continuation
    private let levelContinuation: AsyncStream<AudioLevelSnapshot>.Continuation
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

        var capturedLevelContinuation: AsyncStream<AudioLevelSnapshot>.Continuation!
        self.levelUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            capturedLevelContinuation = continuation
        }
        self.levelContinuation = capturedLevelContinuation
    }

    public func start() async throws {
        guard task == nil else { return }

        task = Task { [script, continuation, levelContinuation] in
            var index = 0
            var phase = 0.0
            var raw = 0.0
            var processed = 0.0

            while !Task.isCancelled {
                continuation.yield(script[index % script.count])
                index += 1

                phase += 0.64
                let nextRaw = max(0.04, min(1.0, 0.18 + abs(sin(phase)) * 0.74))
                let speechGateOpen = nextRaw > 0.18
                let nextProcessed = speechGateOpen ? nextRaw : 0
                raw = AudioLevelMeter.smooth(previous: raw, next: nextRaw)
                processed = AudioLevelMeter.smooth(previous: processed, next: nextProcessed)
                levelContinuation.yield(
                    AudioLevelSnapshot(
                        rawInputLevel: raw,
                        processedInputLevel: processed,
                        speechDetected: speechGateOpen,
                        vadState: speechGateOpen ? "Speech likely" : "Gated"
                    )
                )

                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    public func stop() async {
        task?.cancel()
        task = nil
    }
}
