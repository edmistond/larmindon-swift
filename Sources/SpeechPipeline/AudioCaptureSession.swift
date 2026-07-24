import AVFAudio
import Foundation

#if os(macOS)
import AudioToolbox
import CoreAudio
#endif

public struct CapturedAudioFrame: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer

    public init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

@MainActor
public final class AudioCaptureSession {
    public let frames: AsyncStream<CapturedAudioFrame>
    public let levelUpdates: AsyncStream<AudioLevelSnapshot>
    public private(set) var activeVoiceProcessingEnabled: Bool?

    private let frameContinuation: AsyncStream<CapturedAudioFrame>.Continuation
    private let levelContinuation: AsyncStream<AudioLevelSnapshot>.Continuation
    private let inputDeviceID: UInt32?
    private let bufferFrameCount: AVAudioFrameCount
    private let requestedVoiceProcessingEnabled: Bool
    private let diagnostics: DiagnosticRecorder
    private let audioEngine = AVAudioEngine()
    private let telemetry: AudioCaptureTelemetry
    private var isTapInstalled = false
    private var isRunning = false

    #if os(macOS)
    private var directCapture: SharedMacOSAudioDeviceCapture?
    #endif

    public init(
        inputDeviceID: UInt32?,
        bufferFrameCount: Int,
        voiceProcessingEnabled: Bool,
        diagnostics: DiagnosticRecorder = .shared
    ) {
        self.inputDeviceID = inputDeviceID
        self.bufferFrameCount = AVAudioFrameCount(
            AudioCaptureBufferFrames.clamped(bufferFrameCount)
        )
        self.requestedVoiceProcessingEnabled = voiceProcessingEnabled
        self.diagnostics = diagnostics
        self.telemetry = AudioCaptureTelemetry(diagnostics: diagnostics)

        var frameContinuation:
            AsyncStream<CapturedAudioFrame>.Continuation!
        frames = AsyncStream(bufferingPolicy: .bufferingNewest(32)) {
            frameContinuation = $0
        }
        self.frameContinuation = frameContinuation

        var levelContinuation:
            AsyncStream<AudioLevelSnapshot>.Continuation!
        levelUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(16)) {
            levelContinuation = $0
        }
        self.levelContinuation = levelContinuation
    }

    public func start() async throws {
        guard !isRunning else { return }

        let inputNode = audioEngine.inputNode
        let captureFormat: AVAudioFormat
        var strategy = "audio_engine"

        #if os(macOS)
        if let inputDeviceID,
           MacOSAudioCaptureStrategy.forDevice(AudioDeviceID(inputDeviceID))
                == .coreAudioDevice {
            strategy = "core_audio_device"
            activeVoiceProcessingEnabled = false
            captureFormat = try SharedMacOSAudioDeviceCapture.captureFormat(
                deviceID: AudioDeviceID(inputDeviceID)
            )
        } else {
            try inputNode.setVoiceProcessingEnabled(
                requestedVoiceProcessingEnabled
            )
            activeVoiceProcessingEnabled = inputNode.isVoiceProcessingEnabled
            if let inputDeviceID {
                try configureSharedMacOSInputDevice(
                    inputDeviceID,
                    on: inputNode
                )
                captureFormat = try sharedMacOSInputDeviceCaptureFormat(
                    deviceID: AudioDeviceID(inputDeviceID)
                )
            } else {
                captureFormat = inputNode.outputFormat(forBus: 0)
            }
        }
        #else
        try inputNode.setVoiceProcessingEnabled(
            requestedVoiceProcessingEnabled
        )
        activeVoiceProcessingEnabled = inputNode.isVoiceProcessingEnabled
        captureFormat = inputNode.outputFormat(forBus: 0)
        #endif

        let sink = SharedAudioCaptureSink(
            frameContinuation: frameContinuation,
            levelContinuation: levelContinuation,
            telemetry: telemetry
        )

        #if os(macOS)
        if strategy == "core_audio_device", let inputDeviceID {
            let capture = try SharedMacOSAudioDeviceCapture(
                deviceID: AudioDeviceID(inputDeviceID),
                captureFormat: captureFormat,
                onBuffer: sink.handle
            )
            directCapture = capture
            try capture.start()
        } else {
            inputNode.installTap(
                onBus: 0,
                bufferSize: bufferFrameCount,
                format: captureFormat,
                block: makeSharedAudioTapHandler(sink: sink)
            )
            isTapInstalled = true
            try audioEngine.start()
        }
        #else
        inputNode.installTap(
            onBus: 0,
            bufferSize: bufferFrameCount,
            format: captureFormat,
            block: makeSharedAudioTapHandler(sink: sink)
        )
        isTapInstalled = true
        try audioEngine.start()
        #endif

        isRunning = true
        await diagnostics.record(
            category: "audio",
            name: "capture_started",
            fields: [
                "strategy": strategy,
                "sample_rate": String(captureFormat.sampleRate),
                "channels": String(captureFormat.channelCount),
                "format": String(describing: captureFormat.commonFormat),
                "buffer_frames": String(bufferFrameCount),
                "voice_processing_requested":
                    String(requestedVoiceProcessingEnabled),
                "voice_processing_active":
                    activeVoiceProcessingEnabled.map(String.init) ?? "false",
            ]
        )
    }

    public func stop() async {
        guard isRunning else {
            frameContinuation.finish()
            levelContinuation.finish()
            return
        }

        #if os(macOS)
        directCapture?.stop()
        directCapture = nil
        #endif
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        audioEngine.stop()
        isRunning = false
        frameContinuation.finish()
        levelContinuation.finish()

        let snapshot = telemetry.snapshot()
        await diagnostics.record(
            category: "audio",
            name: "capture_stopped",
            fields: [
                "callbacks": String(snapshot.callbacks),
                "frames": String(snapshot.frames),
                "dropped_buffers": String(snapshot.droppedBuffers),
            ]
        )
    }
}

private struct SharedAudioCaptureSink: @unchecked Sendable {
    let frameContinuation: AsyncStream<CapturedAudioFrame>.Continuation
    let levelContinuation: AsyncStream<AudioLevelSnapshot>.Continuation
    let telemetry: AudioCaptureTelemetry

    func handle(_ buffer: AVAudioPCMBuffer) {
        let rawLevel = AudioLevelMeter.normalizedRMS(from: buffer)
        levelContinuation.yield(
            AudioLevelSnapshot(
                rawInputLevel: rawLevel,
                processedInputLevel: rawLevel,
                speechDetected: rawLevel > 0.01,
                vadState: "Server stream",
                observedCallbackFrameLength: Int(buffer.frameLength)
            )
        )

        guard let copied = buffer.copyPCMBuffer() else {
            telemetry.record(
                frameCount: Int(buffer.frameLength),
                dropped: true
            )
            return
        }
        let result = frameContinuation.yield(
            CapturedAudioFrame(buffer: copied)
        )
        if case .dropped = result {
            telemetry.record(
                frameCount: Int(buffer.frameLength),
                dropped: true
            )
        } else {
            telemetry.record(
                frameCount: Int(buffer.frameLength),
                dropped: false
            )
        }
    }
}

// AVAudioEngine invokes tap blocks on a real-time audio queue. Constructing this
// closure outside AudioCaptureSession prevents it from inheriting @MainActor
// isolation and triggering Swift's runtime executor check on that queue.
private func makeSharedAudioTapHandler(
    sink: SharedAudioCaptureSink
) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
    { buffer, _ in
        sink.handle(buffer)
    }
}

private final class AudioCaptureTelemetry: @unchecked Sendable {
    struct Snapshot {
        let callbacks: Int
        let frames: Int
        let droppedBuffers: Int
    }

    private let lock = NSLock()
    private let diagnostics: DiagnosticRecorder
    private var callbacks = 0
    private var frames = 0
    private var droppedBuffers = 0

    init(diagnostics: DiagnosticRecorder) {
        self.diagnostics = diagnostics
    }

    func record(frameCount: Int, dropped: Bool) {
        lock.lock()
        callbacks += 1
        frames += frameCount
        if dropped {
            droppedBuffers += 1
        }
        let shouldReport = callbacks.isMultiple(of: 100)
        let snapshot = Snapshot(
            callbacks: callbacks,
            frames: frames,
            droppedBuffers: droppedBuffers
        )
        lock.unlock()

        if shouldReport {
            Task { [diagnostics] in
                await diagnostics.record(
                    category: "audio",
                    name: "capture_aggregate",
                    fields: [
                        "callbacks": String(snapshot.callbacks),
                        "frames": String(snapshot.frames),
                        "dropped_buffers":
                            String(snapshot.droppedBuffers),
                    ]
                )
            }
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            callbacks: callbacks,
            frames: frames,
            droppedBuffers: droppedBuffers
        )
    }
}

#if os(macOS)
private final class SharedMacOSAudioDeviceCapture: @unchecked Sendable {
    private let deviceID: AudioDeviceID
    private let captureFormat: AVAudioFormat
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let ioQueue = DispatchQueue(
        label: "com.davidedmiston.larmindon.shared-core-audio-input",
        qos: .userInteractive
    )
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    init(
        deviceID: AudioDeviceID,
        captureFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        try Self.validateInputStreamFormats(deviceID: deviceID)
        self.deviceID = deviceID
        self.captureFormat = captureFormat
        self.onBuffer = onBuffer
    }

    deinit {
        stop()
    }

    static func captureFormat(
        deviceID: AudioDeviceID
    ) throws -> AVAudioFormat {
        try validateInputStreamFormats(deviceID: deviceID)
        let sampleRate = try sharedMacOSNominalSampleRate(
            deviceID: deviceID
        )
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriptionSourceError.unavailable(
                "Could not build direct Core Audio capture format."
            )
        }
        return format
    }

    func start() throws {
        guard ioProcID == nil else { return }

        var newProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID,
            deviceID,
            ioQueue
        ) { [captureFormat, onBuffer] _, inputData, _, _, _ in
            guard let buffer = Self.makeMonoBuffer(
                from: inputData,
                format: captureFormat
            ) else {
                return
            }
            onBuffer(buffer)
        }
        guard status == noErr, let newProcID else {
            throw TranscriptionSourceError.unavailable(
                "Could not create direct Core Audio capture: \(status)"
            )
        }
        ioProcID = newProcID

        let startStatus = AudioDeviceStart(deviceID, newProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, newProcID)
            ioProcID = nil
            throw TranscriptionSourceError.unavailable(
                "Could not start direct Core Audio capture: \(startStatus)"
            )
        }
        isRunning = true
    }

    func stop() {
        guard let ioProcID else { return }
        if isRunning {
            AudioDeviceStop(deviceID, ioProcID)
            isRunning = false
        }
        AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        self.ioProcID = nil
    }

    private static func validateInputStreamFormats(
        deviceID: AudioDeviceID
    ) throws {
        let streamIDs = try inputStreamIDs(deviceID: deviceID)
        guard !streamIDs.isEmpty else {
            throw TranscriptionSourceError.unavailable(
                "The selected macOS audio device has no input streams."
            )
        }

        for streamID in streamIDs {
            var format = AudioStreamBasicDescription()
            var dataSize = UInt32(
                MemoryLayout<AudioStreamBasicDescription>.size
            )
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
            let requiredFlags =
                kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            guard status == noErr,
                  format.mFormatID == kAudioFormatLinearPCM,
                  format.mBitsPerChannel == 32,
                  format.mFormatFlags & requiredFlags == requiredFlags else {
                throw TranscriptionSourceError.unavailable(
                    "Direct Core Audio capture requires packed 32-bit float PCM."
                )
            }
        }
    }

    private static func inputStreamIDs(
        deviceID: AudioDeviceID
    ) throws -> [AudioStreamID] {
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
                "Could not read input streams: \(sizeStatus)"
            )
        }
        let count = Int(dataSize) / MemoryLayout<AudioStreamID>.size
        guard count > 0 else { return [] }

        var streamIDs = [AudioStreamID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &streamIDs
        )
        guard status == noErr else {
            throw TranscriptionSourceError.unavailable(
                "Could not read input stream IDs: \(status)"
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
        let sources = buffers.compactMap {
            buffer -> SharedMacOSFloatInput? in
            guard let data = buffer.mData,
                  buffer.mNumberChannels > 0 else {
                return nil
            }
            let channels = Int(buffer.mNumberChannels)
            let frameCount = Int(buffer.mDataByteSize)
                / (MemoryLayout<Float>.size * channels)
            guard frameCount > 0 else { return nil }
            return SharedMacOSFloatInput(
                samples: data.assumingMemoryBound(to: Float.self),
                channelCount: channels,
                frameCount: frameCount
            )
        }
        guard let frameCount = sources.map(\.frameCount).min(),
              frameCount > 0,
              let output = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let samples = output.floatChannelData?[0] else {
            return nil
        }
        output.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            var mixed = Float(0)
            for source in sources {
                var sourceSample = Float(0)
                for channel in 0..<source.channelCount {
                    sourceSample += source.samples[
                        frame * source.channelCount + channel
                    ]
                }
                mixed += sourceSample / Float(source.channelCount)
            }
            samples[frame] = min(1, max(-1, mixed))
        }
        return output
    }
}

private struct SharedMacOSFloatInput {
    let samples: UnsafePointer<Float>
    let channelCount: Int
    let frameCount: Int
}

private func configureSharedMacOSInputDevice(
    _ deviceID: UInt32,
    on inputNode: AVAudioInputNode
) throws {
    guard let audioUnit = inputNode.audioUnit else {
        throw TranscriptionSourceError.unavailable(
            "Could not access the input audio unit."
        )
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
            "Could not select macOS input \(deviceID): \(status)"
        )
    }
}

private func sharedMacOSInputDeviceCaptureFormat(
    deviceID: AudioDeviceID
) throws -> AVAudioFormat {
    let sampleRate = try sharedMacOSNominalSampleRate(deviceID: deviceID)
    let channelCount = try sharedMacOSInputChannelCount(deviceID: deviceID)
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channelCount,
        interleaved: false
    ) else {
        throw TranscriptionSourceError.unavailable(
            "Could not build the selected macOS input format."
        )
    }
    return format
}

private func sharedMacOSNominalSampleRate(
    deviceID: AudioDeviceID
) throws -> Double {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var sampleRate = Float64(0)
    var dataSize = UInt32(MemoryLayout<Float64>.size)
    let status = AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &dataSize,
        &sampleRate
    )
    guard status == noErr, sampleRate > 0 else {
        throw TranscriptionSourceError.unavailable(
            "Could not read the selected input sample rate: \(status)"
        )
    }
    return sampleRate
}

private func sharedMacOSInputChannelCount(
    deviceID: AudioDeviceID
) throws -> AVAudioChannelCount {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
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
    guard sizeStatus == noErr, dataSize > 0,
          let allocation = malloc(Int(dataSize)) else {
        throw TranscriptionSourceError.unavailable(
            "Could not read the selected input channel layout."
        )
    }
    defer { free(allocation) }

    let list = allocation.bindMemory(
        to: AudioBufferList.self,
        capacity: 1
    )
    let status = AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &dataSize,
        list
    )
    guard status == noErr else {
        throw TranscriptionSourceError.unavailable(
            "Could not read the selected input channels: \(status)"
        )
    }
    let channels = UnsafeMutableAudioBufferListPointer(list)
        .reduce(0) { $0 + Int($1.mNumberChannels) }
    guard channels > 0, channels <= Int(UInt32.max) else {
        throw TranscriptionSourceError.unavailable(
            "The selected input has no usable channels."
        )
    }
    return AVAudioChannelCount(channels)
}
#endif
