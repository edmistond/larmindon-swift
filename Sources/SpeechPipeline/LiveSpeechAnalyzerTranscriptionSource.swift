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
    public let requestedVoiceProcessingEnabled: Bool
    public private(set) var activeVoiceProcessingEnabled: Bool?
    private let profanityFilterEnabled: Bool
    private let audioEngine = AVAudioEngine()
    private let audioState = LiveAudioState()
    private let diagnostics: DiagnosticRecorder
    private let telemetry: AudioCaptureTelemetry
    private var isCaptureRunning = false

    private var analyzerTask: Task<Void, Never>?
    private var audioConversionTask: Task<Void, Never>?
    private var transcriberTask: Task<Void, Never>?
    private var detectorTask: Task<Void, Never>?
    private var stopPipeline: (() async -> Void)?
    private var reservedLocale: Locale?
    private var stallCheckTask: Task<Void, Never>?
    private var isAudioEngineTapInstalled = false

    #if os(macOS)
    private var directAudioDeviceCapture: MacOSDirectAudioDeviceCapture?
    #endif

    public init(
        sensitivity: VADSensitivity = .medium,
        inputDeviceID: UInt32? = nil,
        bufferFrameCount: Int = AudioCaptureBufferFrames.defaultValue,
        voiceProcessingEnabled: Bool = VoiceProcessingPreference.defaultValue,
        profanityFilterEnabled: Bool = false,
        diagnostics: DiagnosticRecorder = .shared
    ) {
        self.sensitivity = sensitivity
        self.inputDeviceID = inputDeviceID
        self.bufferFrameCount = AVAudioFrameCount(
            AudioCaptureBufferFrames.clamped(bufferFrameCount)
        )
        self.requestedVoiceProcessingEnabled = voiceProcessingEnabled
        self.profanityFilterEnabled = profanityFilterEnabled
        self.diagnostics = diagnostics
        self.telemetry = AudioCaptureTelemetry(diagnostics: diagnostics)

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
        try await MicrophonePermission.ensureGranted()
        try await startSpeechAnalyzerPipeline()
    }

    public func stop() async {
        stallCheckTask?.cancel()
        stallCheckTask = nil

        #if os(macOS)
        directAudioDeviceCapture?.stop()
        directAudioDeviceCapture = nil
        #endif

        if isAudioEngineTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isAudioEngineTapInstalled = false
        }
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

        if isCaptureRunning {
            isCaptureRunning = false
            await diagnostics.record(
                category: "audio",
                name: "capture_stopped",
                fields: telemetry.snapshot().diagnosticFields
            )
        }
    }

    private func startSpeechAnalyzerPipeline() async throws {
        let inputNode = audioEngine.inputNode
        var usesDirectMacOSCapture = false
        var directCaptureFormat: AVAudioFormat?
        // macOS device format, used as the analyzer hint and as a fallback if the input
        // node reports an unusable format once the device is selected.
        var selectedDeviceFormat: AVAudioFormat?

        #if os(macOS)
        if let inputDeviceID,
           MacOSAudioCaptureStrategy.forDevice(AudioDeviceID(inputDeviceID)) == .coreAudioDevice {
            usesDirectMacOSCapture = true
            directCaptureFormat = try MacOSDirectAudioDeviceCapture.captureFormat(
                deviceID: AudioDeviceID(inputDeviceID)
            )
        } else if let inputDeviceID {
            selectedDeviceFormat = try macOSInputDeviceCaptureFormat(
                deviceID: AudioDeviceID(inputDeviceID)
            )
        }
        #endif

        // Only a hint for picking the analysis format. Everything from here to the engine
        // block awaits, so the engine must not be mutated yet: configuring the input node
        // and starting the engine have to stay adjacent, or an intervening HAL change
        // invalidates the configuration and `start()` fails with -10875.
        let hintFormat = directCaptureFormat
            ?? selectedDeviceFormat
            ?? inputNode.outputFormat(forBus: 0)

        let locale = try await prepareTranscriberLocale()
        await recordStage(
            "locale_reserved",
            fields: ["locale": locale.identifier, "reserved": String(reservedLocale != nil)]
        )

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: profanityFilterEnabled ? [.etiquetteReplacements] : [],
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
            considering: hintFormat
        ) ?? hintFormat
        // The real capture format is resolved later and may differ from the hint; the
        // converter re-creates itself whenever its input format changes, so conversion to
        // `analysisFormat` holds either way.
        let bufferConverter = DynamicAudioBufferConverter(outputFormat: analysisFormat)

        try await analyzer.prepareToAnalyze(in: analysisFormat)
        await recordStage(
            "analyzer_prepared",
            fields: [
                "analysis_sample_rate": String(analysisFormat.sampleRate),
                "analysis_channels": String(analysisFormat.channelCount),
            ]
        )

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

        let audioSink = AudioTapSink(
            levelContinuation: levelContinuation,
            audioState: audioState,
            captureContinuation: captureContinuation,
            telemetry: telemetry
        )

        // Engine configuration and start, with no `await` in between. See `hintFormat`.
        let strategy: String
        let captureFormat: AVAudioFormat
        var configuration: AudioEngineInputConfiguration?

        do {
            #if os(macOS)
            if usesDirectMacOSCapture, let inputDeviceID, let directCaptureFormat {
                strategy = "core_audio_device"
                captureFormat = directCaptureFormat
                activeVoiceProcessingEnabled = false
                let capture = try MacOSDirectAudioDeviceCapture(
                    deviceID: AudioDeviceID(inputDeviceID),
                    captureFormat: directCaptureFormat,
                    sink: audioSink
                )
                directAudioDeviceCapture = capture
                try capture.start()
            } else {
                strategy = "audio_engine"
                let resolved = try AudioEngineInputConfigurator.configure(
                    inputNode: inputNode,
                    requestedVoiceProcessingEnabled: requestedVoiceProcessingEnabled
                )
                configuration = resolved
                captureFormat = resolved.nodeFormat
                activeVoiceProcessingEnabled = resolved.activeVoiceProcessingEnabled
                try installEngineTap(on: inputNode, sink: audioSink)
            }
            #else
            strategy = "audio_engine"
            let resolved = try AudioEngineInputConfigurator.configure(
                inputNode: inputNode,
                requestedVoiceProcessingEnabled: requestedVoiceProcessingEnabled
            )
            configuration = resolved
            captureFormat = resolved.nodeFormat
            activeVoiceProcessingEnabled = resolved.activeVoiceProcessingEnabled
            try installEngineTap(on: inputNode, sink: audioSink)
            #endif
        } catch {
            await recordCaptureFailure(error, hintFormat: hintFormat)
            throw error
        }

        isCaptureRunning = true
        stallCheckTask = telemetry.scheduleStallCheck(
            fields: [
                "strategy": strategy,
                "sample_rate": String(captureFormat.sampleRate),
                "channels": String(captureFormat.channelCount),
                "voice_processing_active":
                    activeVoiceProcessingEnabled.map(String.init) ?? "false",
            ]
        )

        await diagnostics.record(
            category: "audio",
            name: "capture_started",
            fields: [
                "strategy": strategy,
                "sample_rate": String(captureFormat.sampleRate),
                "channels": String(captureFormat.channelCount),
                "format": String(describing: captureFormat.commonFormat),
                "buffer_frames": String(bufferFrameCount),
                "voice_processing_requested": String(requestedVoiceProcessingEnabled),
                "voice_processing_active":
                    activeVoiceProcessingEnabled.map(String.init) ?? "false",
                "voice_processing_skipped":
                    configuration?.voiceProcessingSkippedReason ?? "none",
                "hint_sample_rate": String(hintFormat.sampleRate),
                "hint_channels": String(hintFormat.channelCount),
            ]
        )
    }

    /// Installs the tap with a nil format so the node's own format is used verbatim.
    /// Passing a format that disagrees with the bus makes `installTap` raise an
    /// Objective-C exception, which Swift cannot catch and which takes the app down.
    private func installEngineTap(
        on inputNode: AVAudioInputNode,
        sink: AudioTapSink
    ) throws {
        inputNode.installTap(
            onBus: 0,
            bufferSize: bufferFrameCount,
            format: nil,
            block: makeAudioTapHandler(sink: sink)
        )
        isAudioEngineTapInstalled = true

        do {
            try audioEngine.start()
        } catch {
            throw AudioEngineConfigurationFailure(step: "engine_start", underlying: error)
        }
    }

    private func recordCaptureFailure(
        _ error: Error,
        hintFormat: AVAudioFormat
    ) async {
        let nodeFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        await diagnostics.record(
            category: "error",
            name: "capture_failed",
            fields: [
                "step": (error as? AudioEngineConfigurationFailure)?.step ?? "unknown",
                "message": error.localizedDescription,
                "voice_processing_requested": String(requestedVoiceProcessingEnabled),
                "node_sample_rate": String(nodeFormat.sampleRate),
                "node_channels": String(nodeFormat.channelCount),
                "hint_sample_rate": String(hintFormat.sampleRate),
                "hint_channels": String(hintFormat.channelCount),
            ]
        )
    }

    private func recordStage(_ stage: String, fields: [String: String] = [:]) async {
        var fields = fields
        fields["stage"] = stage
        await diagnostics.record(
            category: "state",
            name: "speech_pipeline_stage",
            fields: fields
        )
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

        // Two failure shapes, deliberately kept apart. A *thrown* error is a real asset
        // problem and still aborts the start. A `false` return is not: it means the OS
        // declined the reservation without saying why, and it is what a long-idle process
        // starts doing after a session has been stopped — see the `larmindon-diagnostics-
        // C0F09A8C` bundle, where every start after a >75 minute background stretch failed
        // this way while `reservedLocales` was empty and en_US was installed. A reservation
        // only keeps the OS from purging assets that are already on disk, so a refusal is
        // recorded and the pipeline continues unreserved rather than refusing to start.
        let didReserve: Bool
        do {
            didReserve = try await AssetInventory.reserve(locale: supportedLocale)
        } catch {
            await recordReservationDiagnostics(
                name: "locale_reservation_failed",
                category: "error",
                locale: supportedLocale,
                extra: ["error": error.localizedDescription]
            )
            let installedLocales = await SpeechTranscriber.installedLocales
                .map(\.identifier)
                .sorted()
                .joined(separator: ", ")
            throw TranscriptionSourceError.unavailable(
                "Could not reserve SpeechAnalyzer assets for \(supportedLocale.identifier): \(error.localizedDescription). Installed SpeechTranscriber locales: \(installedLocales.isEmpty ? "none" : installedLocales)"
            )
        }

        let reservedLocales = await AssetInventory.reservedLocales
        guard didReserve || reservedLocales.contains(where: { $0.identifier == supportedLocale.identifier }) else {
            await recordReservationDiagnostics(
                name: "locale_reservation_refused",
                category: "state",
                locale: supportedLocale,
                extra: ["did_reserve": String(didReserve)]
            )
            // `reservedLocale` stays nil, so `stop()` will not release a reservation we
            // never held.
            return supportedLocale
        }

        reservedLocale = supportedLocale
        return supportedLocale
    }

    /// Everything the Speech framework will tell us about why a reservation did not happen.
    /// The previous wording nested our own guard message inside the `catch`'s wrapper, which
    /// made a refusal and a thrown error indistinguishable in an exported bundle.
    private func recordReservationDiagnostics(
        name: String,
        category: String,
        locale: Locale,
        extra: [String: String]
    ) async {
        let reservedLocales = await AssetInventory.reservedLocales
            .map(\.identifier)
            .sorted()
            .joined(separator: ", ")
        let installedLocales = await SpeechTranscriber.installedLocales
            .map(\.identifier)
            .sorted()
            .joined(separator: ", ")
        let probe = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        let moduleStatus = await AssetInventory.status(forModules: [probe])

        var fields = extra
        fields["locale"] = locale.identifier
        fields["reserved_locales"] = reservedLocales.isEmpty ? "none" : reservedLocales
        fields["maximum_reserved_locales"] = String(AssetInventory.maximumReservedLocales)
        fields["module_status"] = String(describing: moduleStatus)
        fields["installed_locales"] = installedLocales.isEmpty ? "none" : installedLocales

        await diagnostics.record(category: category, name: name, fields: fields)
    }
}

#if os(macOS)
enum MacOSAudioCaptureStrategy: Equatable {
    case audioEngine
    case coreAudioDevice

    static func forTransportType(_ transportType: UInt32) -> Self {
        switch transportType {
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual:
            .coreAudioDevice
        default:
            .audioEngine
        }
    }

    static func forDevice(_ deviceID: AudioDeviceID) -> Self {
        // AVAudioEngine only captures reliably from the system default input on macOS.
        // Setting kAudioOutputUnitProperty_CurrentDevice returns noErr but leaves the
        // input node on the previous device's format, so the tap installs at the wrong
        // rate and engine start fails with kAudioUnitErr_FormatNotSupported. Read any
        // other device directly instead.
        if let defaultInputDeviceID = macOSDefaultInputDeviceID(),
           deviceID != defaultInputDeviceID {
            return .coreAudioDevice
        }

        var transportType = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &transportType
        )
        guard status == noErr else {
            return .audioEngine
        }
        return forTransportType(transportType)
    }
}

private final class MacOSDirectAudioDeviceCapture: @unchecked Sendable {
    private let deviceID: AudioDeviceID
    private let captureFormat: AVAudioFormat
    private let sink: AudioTapSink
    private let ioQueue = DispatchQueue(
        label: "com.davidedmiston.larmindon.core-audio-input",
        qos: .userInteractive
    )

    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    init(
        deviceID: AudioDeviceID,
        captureFormat: AVAudioFormat,
        sink: AudioTapSink
    ) throws {
        try Self.validateInputStreamFormats(deviceID: deviceID)
        self.deviceID = deviceID
        self.captureFormat = captureFormat
        self.sink = sink
    }

    deinit {
        stop()
    }

    static func captureFormat(deviceID: AudioDeviceID) throws -> AVAudioFormat {
        try validateInputStreamFormats(deviceID: deviceID)
        let sampleRate = try macOSInputDeviceNominalSampleRate(deviceID: deviceID)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriptionSourceError.unavailable(
                "Could not build direct Core Audio format for macOS audio device \(deviceID)"
            )
        }
        return format
    }

    func start() throws {
        guard ioProcID == nil else {
            return
        }

        var newProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID,
            deviceID,
            ioQueue
        ) { [captureFormat, sink] _, inputData, _, _, _ in
            guard let buffer = Self.makeMonoBuffer(
                from: inputData,
                format: captureFormat
            ) else {
                return
            }
            sink.handle(buffer: buffer)
        }

        guard createStatus == noErr, let newProcID else {
            throw TranscriptionSourceError.unavailable(
                "Could not create direct Core Audio capture for macOS audio device \(deviceID): \(createStatus)"
            )
        }
        ioProcID = newProcID

        let startStatus = AudioDeviceStart(deviceID, newProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, newProcID)
            ioProcID = nil
            throw TranscriptionSourceError.unavailable(
                "Could not start direct Core Audio capture for macOS audio device \(deviceID): \(startStatus)"
            )
        }
        isRunning = true
    }

    func stop() {
        guard let ioProcID else {
            return
        }
        if isRunning {
            AudioDeviceStop(deviceID, ioProcID)
            isRunning = false
        }
        AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        self.ioProcID = nil
    }

    private static func validateInputStreamFormats(deviceID: AudioDeviceID) throws {
        let streamIDs = try inputStreamIDs(deviceID: deviceID)
        guard !streamIDs.isEmpty else {
            throw TranscriptionSourceError.unavailable(
                "The selected macOS audio device \(deviceID) has no input streams"
            )
        }

        for streamID in streamIDs {
            var format = AudioStreamBasicDescription()
            var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectGetPropertyData(
                streamID,
                &address,
                0,
                nil,
                &dataSize,
                &format
            )
            guard status == noErr else {
                throw TranscriptionSourceError.unavailable(
                    "Could not read the Core Audio stream format for macOS audio device \(deviceID): \(status)"
                )
            }

            let requiredFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mBitsPerChannel == 32,
                  format.mFormatFlags & requiredFlags == requiredFlags else {
                throw TranscriptionSourceError.unavailable(
                    "Direct Core Audio capture requires 32-bit float PCM input for macOS audio device \(deviceID)"
                )
            }
        }
    }

    private static func inputStreamIDs(deviceID: AudioDeviceID) throws -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr else {
            throw TranscriptionSourceError.unavailable(
                "Could not read input streams for macOS audio device \(deviceID): \(sizeStatus)"
            )
        }

        let streamCount = Int(dataSize) / MemoryLayout<AudioStreamID>.size
        guard streamCount > 0 else {
            return []
        }

        var streamIDs = [AudioStreamID](repeating: 0, count: streamCount)
        let dataStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &streamIDs
        )
        guard dataStatus == noErr else {
            throw TranscriptionSourceError.unavailable(
                "Could not read input streams for macOS audio device \(deviceID): \(dataStatus)"
            )
        }
        return streamIDs
    }

    private static func makeMonoBuffer(
        from inputData: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let sources = buffers.compactMap { buffer -> MacOSFloatInputStream? in
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else {
                return nil
            }
            let channelCount = Int(buffer.mNumberChannels)
            let bytesPerFrame = MemoryLayout<Float>.size * channelCount
            let frameCount = Int(buffer.mDataByteSize) / bytesPerFrame
            guard frameCount > 0 else {
                return nil
            }
            return MacOSFloatInputStream(
                samples: data.assumingMemoryBound(to: Float.self),
                channelCount: channelCount,
                frameCount: frameCount
            )
        }
        guard let frameCount = sources.map(\.frameCount).min(),
              frameCount > 0,
              frameCount <= Int(UInt32.max),
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let output = outputBuffer.floatChannelData?[0] else {
            return nil
        }

        outputBuffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            var mixedSample = Float(0)
            for source in sources {
                var streamSample = Float(0)
                let frameOffset = frame * source.channelCount
                for channel in 0..<source.channelCount {
                    streamSample += source.samples[frameOffset + channel]
                }
                mixedSample += streamSample / Float(source.channelCount)
            }
            output[frame] = min(1, max(-1, mixedSample))
        }
        return outputBuffer
    }
}

private struct MacOSFloatInputStream {
    let samples: UnsafePointer<Float>
    let channelCount: Int
    let frameCount: Int
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
    let telemetry: AudioCaptureTelemetry

    func handle(buffer: AVAudioPCMBuffer) {
        // One measurement pass serves both the meter and telemetry; this runs on the
        // real-time audio thread, so the buffer is walked once.
        let measurement = AudioLevelMeter.measure(from: buffer)
        levelContinuation.yield(
            audioState.updateRawLevel(
                AudioLevelMeter.displayLevel(for: measurement),
                observedCallbackFrameLength: Int(buffer.frameLength)
            )
        )

        let frameCount = Int(buffer.frameLength)
        guard let copiedBuffer = buffer.copyPCMBuffer() else {
            telemetry.record(
                frameCount: frameCount,
                dropped: true,
                measurement: measurement
            )
            return
        }

        let result = captureContinuation.yield(
            CapturedAudioBuffer(buffer: copiedBuffer)
        )
        if case .dropped = result {
            telemetry.record(
                frameCount: frameCount,
                dropped: true,
                measurement: measurement
            )
        } else {
            telemetry.record(
                frameCount: frameCount,
                dropped: false,
                measurement: measurement
            )
        }
    }
}

private func makeAudioTapHandler(
    sink: AudioTapSink
) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
    { buffer, _ in
        sink.handle(buffer: buffer)
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

extension AVAudioPCMBuffer {
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
