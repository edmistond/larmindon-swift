import AVFAudio
import CoreMedia
import Foundation
import Speech

@available(iOS 26.0, macOS 26.0, *)
public final class LiveSpeechAnalyzerTranscriptionSource: TranscriptionSource {
    public let name = "Live SpeechAnalyzer"
    public let results: AsyncStream<CaptionResult>
    public let levelUpdates: AsyncStream<AudioLevelSnapshot>

    private let continuation: AsyncStream<CaptionResult>.Continuation
    private let levelContinuation: AsyncStream<AudioLevelSnapshot>.Continuation
    private let sensitivity: VADSensitivity
    private let audioEngine = AVAudioEngine()
    private let audioState = LiveAudioState()

    private var analyzerTask: Task<Void, Never>?
    private var transcriberTask: Task<Void, Never>?
    private var detectorTask: Task<Void, Never>?
    private var stopPipeline: (() async -> Void)?
    private var reservedLocale: Locale?

    public init(sensitivity: VADSensitivity = .medium) {
        self.sensitivity = sensitivity

        var capturedContinuation: AsyncStream<CaptionResult>.Continuation!
        self.results = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation

        var capturedLevelContinuation: AsyncStream<AudioLevelSnapshot>.Continuation!
        self.levelUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            capturedLevelContinuation = continuation
        }
        self.levelContinuation = capturedLevelContinuation
    }

    public func start() async throws {
        #if os(iOS)
        try configureIOSAudioSession()
        #endif

        try await startSpeechAnalyzerPipeline()
    }

    public func stop() async {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        transcriberTask?.cancel()
        detectorTask?.cancel()
        analyzerTask?.cancel()
        transcriberTask = nil
        detectorTask = nil
        analyzerTask = nil

        await stopPipeline?()
        stopPipeline = nil

        if let reservedLocale {
            await AssetInventory.release(reservedLocale: reservedLocale)
            self.reservedLocale = nil
        }
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

    private func startSpeechAnalyzerPipeline() async throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let locale = try await prepareTranscriberLocale()

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.fastResults, .volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: sensitivity.speechDetectorSensitivityLevel),
            reportResults: true
        )

        let modules: [any SpeechModule] = [detector, transcriber]
        try await validateAssets(for: modules, locale: locale)

        let analyzer = SpeechAnalyzer(modules: modules)
        let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: inputFormat
        ) ?? inputFormat

        try await analyzer.prepareToAnalyze(in: analysisFormat)

        var capturedInputContinuation: AsyncStream<AnalyzerInput>.Continuation!
        let inputStream = AsyncStream(
            bufferingPolicy: .bufferingNewest(32)
        ) { continuation in
            capturedInputContinuation = continuation
        }

        transcriberTask = Task { [continuation, transcriber] in
            var finalizedRanges = Set<String>()

            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    let finalized = result.resultsFinalizationTime.isValid
                    if finalized {
                        let key = result.range.stableKey
                        guard finalizedRanges.insert(key).inserted else {
                            continue
                        }
                        continuation.yield(.finalized(text))
                    } else {
                        continuation.yield(.volatile(text))
                    }
                }
            } catch {
                continuation.yield(.volatile("Speech transcriber error: \(error.localizedDescription)"))
            }
        }

        detectorTask = Task { [audioState, detector, levelContinuation] in
            do {
                for try await result in detector.results {
                    let snapshot = audioState.updateVAD(speechDetected: result.speechDetected)
                    levelContinuation.yield(snapshot)
                }
            } catch {
                levelContinuation.yield(
                    audioState.updateVAD(
                        speechDetected: false,
                        label: "VAD error: \(error.localizedDescription)"
                    )
                )
            }
        }

        let analyzerInputContinuation = capturedInputContinuation!
        stopPipeline = {
            analyzerInputContinuation.finish()
            await analyzer.cancelAndFinishNow()
        }

        let levelContinuation = levelContinuation
        let audioState = audioState
        inputNode.installTap(
            onBus: 0,
            bufferSize: 768,
            format: analysisFormat
        ) { buffer, time in
            guard let copiedBuffer = buffer.copyPCMBuffer() else {
                return
            }

            let rawLevel = AudioLevelMeter.normalizedRMS(from: copiedBuffer)
            levelContinuation.yield(audioState.updateRawLevel(rawLevel))

            let startTime: CMTime?
            if time.sampleTime >= 0, copiedBuffer.format.sampleRate > 0 {
                startTime = CMTime(
                    value: time.sampleTime,
                    timescale: CMTimeScale(copiedBuffer.format.sampleRate.rounded())
                )
            } else {
                startTime = nil
            }

            analyzerInputContinuation.yield(
                AnalyzerInput(buffer: copiedBuffer, bufferStartTime: startTime)
            )
        }

        try audioEngine.start()

        analyzerTask = Task { [analyzer, inputStream, continuation] in
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch {
                continuation.yield(.volatile("SpeechAnalyzer error: \(error.localizedDescription)"))
            }
        }
    }

    private func validateAssets(for modules: [any SpeechModule], locale: Locale) async throws {
        let status = await AssetInventory.status(forModules: modules)
        guard status != .unsupported else {
            throw TranscriptionSourceError.unavailable(
                "SpeechAnalyzer assets for \(locale.identifier) are unsupported on this device or simulator."
            )
        }
    }

    private func prepareTranscriberLocale() async throws -> Locale {
        let requestedLocale = Locale.current.identifier.isEmpty ? Locale(identifier: "en_US") : Locale.current
        var supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
        if supportedLocale == nil {
            supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
        }

        guard let supportedLocale else {
            let supportedLocales = await SpeechTranscriber.supportedLocales
                .map(\.identifier)
                .sorted()
                .joined(separator: ", ")
            throw TranscriptionSourceError.unavailable(
                "SpeechTranscriber does not support \(requestedLocale.identifier). Supported locales: \(supportedLocales)"
            )
        }

        do {
            let didReserve = try await AssetInventory.reserve(locale: supportedLocale)
            guard didReserve else {
                let reservedLocales = await AssetInventory.reservedLocales
                    .map(\.identifier)
                    .sorted()
                    .joined(separator: ", ")
                throw TranscriptionSourceError.unavailable(
                    "Could not reserve SpeechAnalyzer locale \(supportedLocale.identifier). Reserved locales: \(reservedLocales.isEmpty ? "none" : reservedLocales)"
                )
            }
            reservedLocale = supportedLocale
            return supportedLocale
        } catch {
            let installedLocales = await SpeechTranscriber.installedLocales
                .map(\.identifier)
                .sorted()
                .joined(separator: ", ")
            throw TranscriptionSourceError.unavailable(
                "Could not reserve SpeechAnalyzer assets for \(supportedLocale.identifier): \(error.localizedDescription). Installed SpeechTranscriber locales: \(installedLocales.isEmpty ? "none" : installedLocales)"
            )
        }
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

private final class LiveAudioState: @unchecked Sendable {
    private let lock = NSLock()
    private var rawInputLevel = 0.0
    private var processedInputLevel = 0.0
    private var vadAllowsProcessing = true
    private var vadState = "Listening"

    func updateRawLevel(_ rawLevel: Double) -> AudioLevelSnapshot {
        lock.lock()
        defer { lock.unlock() }

        rawInputLevel = AudioLevelMeter.smooth(previous: rawInputLevel, next: rawLevel)
        let nextProcessedLevel = vadAllowsProcessing ? rawInputLevel : 0
        processedInputLevel = AudioLevelMeter.smooth(previous: processedInputLevel, next: nextProcessedLevel)

        return AudioLevelSnapshot(
            rawInputLevel: rawInputLevel,
            processedInputLevel: processedInputLevel,
            vadState: vadState
        )
    }

    func updateVAD(speechDetected: Bool, label: String? = nil) -> AudioLevelSnapshot {
        lock.lock()
        defer { lock.unlock() }

        vadAllowsProcessing = speechDetected
        vadState = label ?? (speechDetected ? "Speech detected" : "No speech")
        let nextProcessedLevel = speechDetected ? rawInputLevel : 0
        processedInputLevel = AudioLevelMeter.smooth(previous: processedInputLevel, next: nextProcessedLevel)

        return AudioLevelSnapshot(
            rawInputLevel: rawInputLevel,
            processedInputLevel: processedInputLevel,
            vadState: vadState
        )
    }
}

private extension CMTimeRange {
    var stableKey: String {
        [
            start.value,
            Int64(start.timescale),
            duration.value,
            Int64(duration.timescale),
        ]
        .map(String.init)
        .joined(separator: ":")
    }
}

private extension AVAudioPCMBuffer {
    func copyPCMBuffer() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }

        copy.frameLength = frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)

        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            guard let source = sourceBuffers[index].mData,
                  let destination = destinationBuffers[index].mData else {
                continue
            }
            memcpy(destination, source, Int(sourceBuffers[index].mDataByteSize))
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }

        return copy
    }
}
