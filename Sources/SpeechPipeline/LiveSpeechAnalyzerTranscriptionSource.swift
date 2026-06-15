import AVFAudio
import Foundation
import Speech

public final class LiveSpeechAnalyzerTranscriptionSource: TranscriptionSource {
    public let name = "Live SpeechAnalyzer"
    public let results: AsyncStream<CaptionResult>

    private let continuation: AsyncStream<CaptionResult>.Continuation
    private let sensitivity: VADSensitivity
    private let audioEngine = AVAudioEngine()

    public init(sensitivity: VADSensitivity = .medium) {
        self.sensitivity = sensitivity

        var capturedContinuation: AsyncStream<CaptionResult>.Continuation!
        self.results = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    public func start() async throws {
        #if os(iOS)
        try configureIOSAudioSession()
        #endif

        if #available(iOS 26.0, macOS 26.0, *) {
            try await startSpeechAnalyzerPipeline()
        } else {
            throw TranscriptionSourceError.unavailable("SpeechAnalyzer requires iOS 26 or macOS 26 in the installed SDK/runtime.")
        }
    }

    public func stop() async {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    #if os(iOS)
    private func configureIOSAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        if session.isInputGainSettable {
            try? session.setInputGain(1)
        }
        try session.setActive(true, options: [])
    }
    #endif

    @available(iOS 26.0, macOS 26.0, *)
    private func startSpeechAnalyzerPipeline() async throws {
        let transcriber = SpeechTranscriber(
            locale: .current,
            preset: .progressiveTranscription
        )
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: sensitivity.speechDetectorSensitivityLevel),
            reportResults: true
        )

        _ = SpeechAnalyzer(modules: [detector, transcriber])

        // TODO: Bridge AVAudioEngine PCM buffers into AnalyzerInput and feed them to
        // SpeechAnalyzer. The architectural boundary is in place so this can become
        // a real microphone pipeline without changing the UI or CaptionStore.
        throw TranscriptionSourceError.unavailable("Live SpeechAnalyzer capture is scaffolded but not wired to AnalyzerInput yet. Use Fake mode for simulator evaluation.")
    }
}

@available(iOS 26.0, macOS 26.0, *)
private extension VADSensitivity {
    var speechDetectorSensitivityLevel: SpeechDetector.SensitivityLevel {
        switch self {
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        }
    }
}
