import AVFAudio
import CoreMedia
import Foundation
import Speech

#if os(macOS)
import AudioToolbox
#endif

@available(iOS 26.0, macOS 26.0, *)
public final class LiveSpeechAnalyzerTranscriptionSource: TranscriptionSource {
    public let name = "Live SpeechAnalyzer"
    public let results: AsyncStream<CaptionResult>
    public let levelUpdates: AsyncStream<AudioLevelSnapshot>

    private let continuation: AsyncStream<CaptionResult>.Continuation
    private let levelContinuation: AsyncStream<AudioLevelSnapshot>.Continuation
    private let sensitivity: VADSensitivity
    private let inputDeviceID: UInt32?
    private let bufferFrameCount: AVAudioFrameCount
    private let audioEngine = AVAudioEngine()
    private let audioState = LiveAudioState()

    private var analyzerTask: Task<Void, Never>?
    private var audioConversionTask: Task<Void, Never>?
    private var transcriberTask: Task<Void, Never>?
    private var detectorTask: Task<Void, Never>?
    private var stopPipeline: (() async -> Void)?
    private var reservedLocale: Locale?

    public init(
        sensitivity: VADSensitivity = .medium,
        inputDeviceID: UInt32? = nil,
        bufferFrameCount: Int = AudioCaptureBufferFrames.defaultValue
    ) {
        self.sensitivity = sensitivity
        self.inputDeviceID = inputDeviceID
        self.bufferFrameCount = AVAudioFrameCount(
            AudioCaptureBufferFrames.clamped(bufferFrameCount)
        )

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
        audioConversionTask?.cancel()
        analyzerTask?.cancel()
        transcriberTask = nil
        detectorTask = nil
        audioConversionTask = nil
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
        let captureFormat: AVAudioFormat

        #if os(macOS)
        if let inputDeviceID {
            try configureMacOSInputDevice(inputDeviceID, on: inputNode)
            captureFormat = try macOSInputDeviceCaptureFormat(deviceID: AudioDeviceID(inputDeviceID))
        } else {
            captureFormat = inputNode.outputFormat(forBus: 0)
        }
        #else
        captureFormat = inputNode.outputFormat(forBus: 0)
        #endif

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
        let analyzer = SpeechAnalyzer(modules: modules)
        let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: captureFormat
        ) ?? captureFormat
        let bufferConverter = DynamicAudioBufferConverter(outputFormat: analysisFormat)

        try await analyzer.prepareToAnalyze(in: analysisFormat)

        var capturedInputContinuation: AsyncStream<AnalyzerInput>.Continuation!
        let inputStream = AsyncStream(
            bufferingPolicy: .bufferingNewest(32)
        ) { continuation in
            capturedInputContinuation = continuation
        }
        var capturedAudioContinuation: AsyncStream<CapturedAudioBuffer>.Continuation!
        let capturedAudioStream = AsyncStream(
            bufferingPolicy: .bufferingNewest(32)
        ) { continuation in
            capturedAudioContinuation = continuation
        }

        transcriberTask = Task { [audioState, continuation, levelContinuation, transcriber] in
            var finalizedRanges = Set<String>()

            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    levelContinuation.yield(audioState.updateSpeechActivity())

                    let finalized = SpeechResultFinalization.isFinalized(
                        range: result.range,
                        resultsFinalizationTime: result.resultsFinalizationTime
                    )
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
        let captureContinuation = capturedAudioContinuation!
        stopPipeline = {
            captureContinuation.finish()
            analyzerInputContinuation.finish()
            await analyzer.cancelAndFinishNow()
        }

        audioConversionTask = Task { [capturedAudioStream, bufferConverter, analyzerInputContinuation] in
            for await packet in capturedAudioStream {
                if Task.isCancelled {
                    break
                }

                guard let analyzerBuffer = bufferConverter.convert(packet.buffer) else {
                    continue
                }

                analyzerInputContinuation.yield(
                    AnalyzerInput(buffer: analyzerBuffer)
                )
            }

            analyzerInputContinuation.finish()
        }

        analyzerTask = Task { [analyzer, inputStream, continuation] in
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch {
                continuation.yield(.volatile("SpeechAnalyzer error: \(error.localizedDescription)"))
            }
        }

        let tapHandler = makeAudioTapHandler(
            sink: AudioTapSink(
                levelContinuation: levelContinuation,
                audioState: audioState,
                captureContinuation: captureContinuation
            )
        )
        inputNode.installTap(
            onBus: 0,
            bufferSize: bufferFrameCount,
            format: captureFormat,
            block: tapHandler
        )

        try audioEngine.start()
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
            let reservedLocales = await AssetInventory.reservedLocales
            guard didReserve || reservedLocales.contains(where: { $0.identifier == supportedLocale.identifier }) else {
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

#if os(macOS)
@available(macOS 26.0, *)
private func configureMacOSInputDevice(_ deviceID: UInt32, on inputNode: AVAudioInputNode) throws {
    guard let audioUnit = inputNode.audioUnit else {
        throw TranscriptionSourceError.unavailable("Could not access AVAudioEngine input audio unit")
    }

    var mutableDeviceID = AudioDeviceID(deviceID)
    let status = AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &mutableDeviceID,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard status == noErr else {
        throw TranscriptionSourceError.unavailable(
            "Could not open selected macOS input device \(deviceID): \(status)"
        )
    }
}

private func macOSInputDeviceCaptureFormat(deviceID: AudioDeviceID) throws -> AVAudioFormat {
    let sampleRate = try macOSInputDeviceNominalSampleRate(deviceID: deviceID)
    let channelCount = try macOSInputDeviceInputChannelCount(deviceID: deviceID)

    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channelCount,
        interleaved: false
    ) else {
        throw TranscriptionSourceError.unavailable(
            "Could not build input format for macOS audio device \(deviceID): \(channelCount) ch at \(sampleRate) Hz"
        )
    }

    return format
}

private func macOSInputDeviceNominalSampleRate(deviceID: AudioDeviceID) throws -> Double {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var sampleRate = Float64(0)
    var dataSize = UInt32(MemoryLayout<Float64>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate)

    guard status == noErr, sampleRate > 0 else {
        throw TranscriptionSourceError.unavailable(
            "Could not read nominal sample rate for macOS audio device \(deviceID): \(status)"
        )
    }

    return Double(sampleRate)
}

private func macOSInputDeviceInputChannelCount(deviceID: AudioDeviceID) throws -> AVAudioChannelCount {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)

    guard sizeStatus == noErr, dataSize > 0 else {
        throw TranscriptionSourceError.unavailable(
            "Could not read input channel layout for macOS audio device \(deviceID): \(sizeStatus)"
        )
    }

    guard let rawBufferList = malloc(Int(dataSize)) else {
        throw TranscriptionSourceError.unavailable(
            "Could not allocate input channel layout buffer for macOS audio device \(deviceID)"
        )
    }
    defer {
        free(rawBufferList)
    }

    let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
    let dataStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, audioBufferList)
    guard dataStatus == noErr else {
        throw TranscriptionSourceError.unavailable(
            "Could not read input channel layout for macOS audio device \(deviceID): \(dataStatus)"
        )
    }

    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    let channelCount = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }

    guard channelCount > 0, channelCount <= Int(UInt32.max) else {
        throw TranscriptionSourceError.unavailable(
            "Invalid input channel count for macOS audio device \(deviceID): \(channelCount)"
        )
    }

    return AVAudioChannelCount(channelCount)
}
#endif

private struct AudioTapSink: @unchecked Sendable {
    let levelContinuation: AsyncStream<AudioLevelSnapshot>.Continuation
    let audioState: LiveAudioState
    let captureContinuation: AsyncStream<CapturedAudioBuffer>.Continuation

    func handle(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let rawLevel = AudioLevelMeter.normalizedRMS(from: buffer)
        levelContinuation.yield(
            audioState.updateRawLevel(
                rawLevel,
                observedCallbackFrameLength: Int(buffer.frameLength)
            )
        )

        guard let copiedBuffer = buffer.copyPCMBuffer() else {
            return
        }

        captureContinuation.yield(CapturedAudioBuffer(buffer: copiedBuffer))
    }
}

private func makeAudioTapHandler(
    sink: AudioTapSink
) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
    { buffer, time in
        sink.handle(buffer: buffer, time: time)
    }
}

private struct CapturedAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

private final class DynamicAudioBufferConverter: @unchecked Sendable {
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inputFormat = buffer.format
        if inputFormat.isEquivalent(to: outputFormat) {
            return buffer.copyPCMBuffer()
        }

        lock.lock()
        defer { lock.unlock() }

        if converterInputFormat?.isEquivalent(to: inputFormat) != true {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converterInputFormat = inputFormat
        }

        guard let converter else {
            return nil
        }

        let sampleRateRatio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(
            max(1, ceil(Double(buffer.frameLength) * sampleRateRatio) + 16)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            return nil
        }

        let inputProvider = AudioConverterInputProvider(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError
        ) { _, inputStatus in
            inputProvider.nextBuffer(inputStatus: inputStatus)
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return outputBuffer.frameLength > 0 ? outputBuffer : nil
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }
}

private final class AudioConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(
        inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        guard !didProvideInput else {
            inputStatus.pointee = .noDataNow
            return nil
        }

        didProvideInput = true
        inputStatus.pointee = .haveData
        return buffer
    }
}

private extension AVAudioFormat {
    func isEquivalent(to other: AVAudioFormat) -> Bool {
        commonFormat == other.commonFormat &&
            sampleRate == other.sampleRate &&
            channelCount == other.channelCount &&
            isInterleaved == other.isInterleaved
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
    private static let speechActivityHoldDuration: TimeInterval = 1.2

    private let lock = NSLock()
    private var rawInputLevel = 0.0
    private var processedInputLevel = 0.0
    private var detectorSpeechDetected = false
    private var speechActivityExpiresAt: Date?
    private var vadError: String?
    private var observedCallbackFrameLength: Int?

    func updateRawLevel(_ rawLevel: Double, observedCallbackFrameLength: Int) -> AudioLevelSnapshot {
        lock.lock()
        defer { lock.unlock() }

        rawInputLevel = AudioLevelMeter.smooth(previous: rawInputLevel, next: rawLevel)
        self.observedCallbackFrameLength = observedCallbackFrameLength
        return makeSnapshot(now: Date())
    }

    func updateVAD(speechDetected: Bool, label: String? = nil) -> AudioLevelSnapshot {
        lock.lock()
        defer { lock.unlock() }

        detectorSpeechDetected = speechDetected
        vadError = label

        return makeSnapshot(now: Date())
    }

    func updateSpeechActivity() -> AudioLevelSnapshot {
        lock.lock()
        defer { lock.unlock() }

        speechActivityExpiresAt = Date().addingTimeInterval(Self.speechActivityHoldDuration)
        return makeSnapshot(now: Date())
    }

    private func makeSnapshot(now: Date) -> AudioLevelSnapshot {
        let speechDetected = isSpeechActive(now: now)
        let nextProcessedLevel = speechDetected ? rawInputLevel : 0
        processedInputLevel = AudioLevelMeter.smooth(previous: processedInputLevel, next: nextProcessedLevel)

        return AudioLevelSnapshot(
            rawInputLevel: rawInputLevel,
            processedInputLevel: processedInputLevel,
            speechDetected: speechDetected,
            vadState: vadState(now: now),
            observedCallbackFrameLength: observedCallbackFrameLength
        )
    }

    private func isSpeechActive(now: Date) -> Bool {
        detectorSpeechDetected || speechActivityExpiresAt.map { now < $0 } == true
    }

    private func vadState(now: Date) -> String {
        if let vadError {
            return vadError
        }

        if detectorSpeechDetected {
            return "Speech detected"
        }

        if speechActivityExpiresAt.map({ now < $0 }) == true {
            return "Speech recognized"
        }

        return "No speech"
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
