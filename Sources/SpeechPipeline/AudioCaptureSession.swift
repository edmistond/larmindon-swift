import AVFAudio
import Foundation

#if os(macOS)
import AudioToolbox
import CoreAudio
#endif

public struct CapturedAudioFrame: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    /// When the tap delivered the buffer: its last sample's capture time plus the device's
    /// I/O latency. The origin for every age a provider measures from this audio.
    public let capturedAt: ContinuousClock.Instant

    public init(buffer: AVAudioPCMBuffer, capturedAt: ContinuousClock.Instant = .now) {
        self.buffer = buffer
        self.capturedAt = capturedAt
    }
}

@MainActor
public final class AudioCaptureSession {
    public let frames: AsyncStream<CapturedAudioFrame>
    public let levelUpdates: AsyncStream<AudioLevelSnapshot>
    public private(set) var activeVoiceProcessingEnabled: Bool?

    private let frameContinuation: AsyncStream<CapturedAudioFrame>.Continuation
    private let levelContinuation: AsyncStream<AudioLevelSnapshot>.Continuation
    private let driver: any AudioCaptureDriving
    private let requestPermission: @MainActor () async throws -> Void
    private let diagnostics: DiagnosticRecorder
    private let telemetry: AudioCaptureTelemetry
    private let levelReporter = ServerAudioLevelReporter()
    private enum State { case idle, starting, running, stopped }
    private var state = State.idle
    private var ownsDriverResources = false
    private var stallCheckTask: Task<Void, Never>?

    public convenience init(
        inputDeviceID: UInt32?,
        bufferFrameCount: Int,
        voiceProcessingEnabled: Bool,
        diagnostics: DiagnosticRecorder = .shared
    ) {
        self.init(
            driver: SystemAudioCaptureDriver(
                inputDeviceID: inputDeviceID,
                bufferFrameCount: bufferFrameCount,
                voiceProcessingEnabled: voiceProcessingEnabled
            ),
            requestPermission: { try await MicrophonePermission.ensureGranted() },
            diagnostics: diagnostics
        )
    }

    init(
        driver: any AudioCaptureDriving,
        requestPermission: @escaping @MainActor () async throws -> Void = {},
        diagnostics: DiagnosticRecorder = .shared
    ) {
        self.driver = driver
        self.requestPermission = requestPermission
        self.diagnostics = diagnostics
        telemetry = AudioCaptureTelemetry(diagnostics: diagnostics)
        (frames, frameContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
        (levelUpdates, levelContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    public func start() async throws {
        if state == .running { return }
        guard state == .idle else { throw CancellationError() }
        state = .starting
        do {
            try await requestPermission()
            try Task.checkCancellation()
            guard state == .starting else { throw CancellationError() }
            let sink = SharedAudioCaptureSink(
                frameContinuation: frameContinuation,
                levelContinuation: levelContinuation,
                telemetry: telemetry,
                levelReporter: levelReporter
            )
            // A driver may acquire a tap before throwing. Ownership begins before start.
            ownsDriverResources = true
            let info = try driver.start(onBuffer: sink.handle)
            activeVoiceProcessingEnabled = info.voiceProcessingEnabled
            state = .running
            stallCheckTask = telemetry.scheduleStallCheck(fields: info.fields)
            await diagnostics.record(category: "audio", name: "capture_started", fields: info.fields)
            try Task.checkCancellation()
            guard state == .running else { throw CancellationError() }
        } catch {
            await stop()
            throw error
        }
    }

    /// Marks the provider as alive, turning the level meter's hot state on.
    public func noteProviderActivity() {
        levelReporter.noteProviderActivity()
    }

    public func stop() async {
        stallCheckTask?.cancel()
        stallCheckTask = nil
        guard state != .stopped else { return }
        state = .stopped
        if ownsDriverResources {
            driver.stop()
            ownsDriverResources = false
        }
        frameContinuation.finish()
        levelContinuation.finish()
        await diagnostics.record(
            category: "audio", name: "capture_stopped", fields: telemetry.snapshot().diagnosticFields
        )
    }
}

struct AudioCaptureStartInfo {
    let voiceProcessingEnabled: Bool
    let fields: [String: String]
}

/// A single capture attempt. stop() also releases resources acquired by a failed start.
@MainActor
protocol AudioCaptureDriving: AnyObject {
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws -> AudioCaptureStartInfo
    func stop()
}

@MainActor
private final class SystemAudioCaptureDriver: AudioCaptureDriving {
    private let inputDeviceID: UInt32?
    private let bufferFrameCount: AVAudioFrameCount
    private let requestedVoiceProcessingEnabled: Bool
    private let audioEngine = AVAudioEngine()
    private var isTapInstalled = false
    private var activeVoiceProcessingEnabled: Bool?
    #if os(macOS)
    private var directCapture: SharedMacOSAudioDeviceCapture?
    #endif

    init(inputDeviceID: UInt32?, bufferFrameCount: Int, voiceProcessingEnabled: Bool) {
        self.inputDeviceID = inputDeviceID
        self.bufferFrameCount = AVAudioFrameCount(AudioCaptureBufferFrames.clamped(bufferFrameCount))
        self.requestedVoiceProcessingEnabled = voiceProcessingEnabled
    }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws -> AudioCaptureStartInfo {
        let inputNode = audioEngine.inputNode
        let captureFormat: AVAudioFormat
        var strategy = "audio_engine"
        var configuration: AudioEngineInputConfiguration?

        #if os(macOS)
        if let inputDeviceID,
            MacOSAudioCaptureStrategy.forDevice(AudioDeviceID(inputDeviceID))
                == .coreAudioDevice
        {
            strategy = "core_audio_device"
            activeVoiceProcessingEnabled = false
            captureFormat = try SharedMacOSAudioDeviceCapture.captureFormat(
                deviceID: AudioDeviceID(inputDeviceID)
            )
        } else {
            let resolved = try AudioEngineInputConfigurator.configure(
                inputNode: inputNode,
                requestedVoiceProcessingEnabled:
                    requestedVoiceProcessingEnabled
            )
            configuration = resolved
            captureFormat = resolved.nodeFormat
            activeVoiceProcessingEnabled = resolved.activeVoiceProcessingEnabled
        }
        #else
        let resolved = try AudioEngineInputConfigurator.configure(
            inputNode: inputNode,
            requestedVoiceProcessingEnabled: requestedVoiceProcessingEnabled
        )
        configuration = resolved
        captureFormat = resolved.nodeFormat
        activeVoiceProcessingEnabled = resolved.activeVoiceProcessingEnabled
        #endif

        #if os(macOS)
        if strategy == "core_audio_device", let inputDeviceID {
            let capture = try SharedMacOSAudioDeviceCapture(
                deviceID: AudioDeviceID(inputDeviceID),
                captureFormat: captureFormat,
                onBuffer: onBuffer
            )
            directCapture = capture
            try capture.start()
        } else {
            installEngineTap(on: inputNode, onBuffer: onBuffer)
            try audioEngine.start()
        }
        #else
        installEngineTap(on: inputNode, onBuffer: onBuffer)
        try audioEngine.start()
        #endif

        return AudioCaptureStartInfo(
            voiceProcessingEnabled: activeVoiceProcessingEnabled ?? false,
            fields: [
                "strategy": strategy,
                "sample_rate": String(captureFormat.sampleRate),
                "channels": String(captureFormat.channelCount),
                "format": String(describing: captureFormat.commonFormat),
                "buffer_frames": String(bufferFrameCount),
                "voice_processing_requested": String(requestedVoiceProcessingEnabled),
                "voice_processing_active": activeVoiceProcessingEnabled.map(String.init) ?? "false",
                "voice_processing_skipped": configuration?.voiceProcessingSkippedReason ?? "none",
            ]
        )
    }

    // Nil format preserves the node's exact bus format and avoids an Objective-C exception.
    private func installEngineTap(
        on inputNode: AVAudioInputNode,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) {
        inputNode.installTap(
            onBus: 0,
            bufferSize: bufferFrameCount,
            format: nil,
            block: makeSharedAudioTapHandler(onBuffer: onBuffer)
        )
        isTapInstalled = true
    }

    func stop() {
        #if os(macOS)
        directCapture?.stop()
        directCapture = nil
        #endif
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        audioEngine.stop()
    }
}

private struct SharedAudioCaptureSink: @unchecked Sendable {
    let frameContinuation: AsyncStream<CapturedAudioFrame>.Continuation
    let levelContinuation: AsyncStream<AudioLevelSnapshot>.Continuation
    let telemetry: AudioCaptureTelemetry
    let levelReporter: ServerAudioLevelReporter

    func handle(_ buffer: AVAudioPCMBuffer) {
        // First, before any work on this thread can delay it.
        let capturedAt = ContinuousClock.now
        // One measurement pass serves both the meter and telemetry; this runs on the
        // real-time audio thread, so the buffer is walked once.
        let measurement = AudioLevelMeter.measure(from: buffer)
        if let snapshot = levelReporter.update(
            rawLevel: AudioLevelMeter.displayLevel(for: measurement),
            observedCallbackFrameLength: Int(buffer.frameLength)
        ) {
            levelContinuation.yield(snapshot)
        }

        guard let copied = buffer.copyPCMBuffer() else {
            telemetry.record(
                frameCount: Int(buffer.frameLength),
                dropped: true,
                measurement: measurement
            )
            return
        }
        let result = frameContinuation.yield(
            CapturedAudioFrame(buffer: copied, capturedAt: capturedAt)
        )
        if case .dropped = result {
            telemetry.record(
                frameCount: Int(buffer.frameLength),
                dropped: true,
                measurement: measurement
            )
        } else {
            telemetry.record(
                frameCount: Int(buffer.frameLength),
                dropped: false,
                measurement: measurement
            )
        }
    }
}

/// Drives the level meter in server mode.
///
/// The encoding is **length = am I capturing audio, colour = is the backend producing
/// anything**, which matches on-device mode where colour means VAD is hot. The hot state used
/// to be `smoothedLevel > 0.01` — a near-zero noise gate that was on whenever the room wasn't
/// silent, and which specifically could not show the failure that matters: hit a dead zone,
/// the websocket stalls, no captions arrive, and the meter still looks healthy because the mic
/// is fine. Driving it from token arrival makes it an end-to-end signal covering capture,
/// network, and auth, so a grey-but-moving bar reads as "audio fine, backend not producing."
final class ServerAudioLevelReporter: @unchecked Sendable {
    static let defaultUpdateInterval: TimeInterval = 0.25
    /// How long one burst of tokens keeps the meter hot. Long enough to bridge the gaps
    /// between words so the bar doesn't strobe, short enough that a stall goes grey while
    /// it still matters.
    static let defaultActivityWindow: TimeInterval = 2

    private let lock = NSLock()
    private let updateInterval: TimeInterval
    private let activityWindow: TimeInterval
    private var smoothedLevel = 0.0
    private var lastPublishedAt: TimeInterval?
    private var lastProviderActivityAt: TimeInterval?

    init(
        updateInterval: TimeInterval = defaultUpdateInterval,
        activityWindow: TimeInterval = defaultActivityWindow
    ) {
        self.updateInterval = max(0, updateInterval)
        self.activityWindow = max(0, activityWindow)
    }

    /// Records that the provider returned transcribed words. Called from the main actor as
    /// results arrive, while `update` runs on the audio thread — hence the lock.
    func noteProviderActivity(
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        lock.lock()
        defer { lock.unlock() }
        lastProviderActivityAt = timestamp
    }

    func update(
        rawLevel: Double,
        observedCallbackFrameLength: Int,
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> AudioLevelSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        smoothedLevel = AudioLevelMeter.smooth(
            previous: smoothedLevel,
            next: rawLevel
        )

        if let lastPublishedAt {
            let elapsed = timestamp - lastPublishedAt
            guard elapsed < 0 || elapsed >= updateInterval else {
                return nil
            }
        }
        lastPublishedAt = timestamp

        let isProviderActive =
            lastProviderActivityAt.map {
                timestamp - $0 < activityWindow
            } ?? false

        return AudioLevelSnapshot(
            rawInputLevel: smoothedLevel,
            processedInputLevel: smoothedLevel,
            speechDetected: isProviderActive,
            vadState: isProviderActive
                ? "Server returning tokens"
                : "Server idle",
            observedCallbackFrameLength: observedCallbackFrameLength
        )
    }
}

// AVAudioEngine invokes tap blocks on a real-time audio queue. Constructing this
// closure outside AudioCaptureSession prevents it from inheriting @MainActor
// isolation and triggering Swift's runtime executor check on that queue.
private func makeSharedAudioTapHandler(
    onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
    { buffer, _ in
        onBuffer(buffer)
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
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
        else {
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
            guard
                let buffer = Self.makeMonoBuffer(
                    from: inputData,
                    format: captureFormat
                )
            else {
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
                format.mFormatFlags & requiredFlags == requiredFlags
            else {
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
                buffer.mNumberChannels > 0
            else {
                return nil
            }
            let channels = Int(buffer.mNumberChannels)
            let frameCount =
                Int(buffer.mDataByteSize)
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
            let samples = output.floatChannelData?[0]
        else {
            return nil
        }
        output.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            var mixed = Float(0)
            for source in sources {
                var sourceSample = Float(0)
                for channel in 0..<source.channelCount {
                    sourceSample +=
                        source.samples[
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

#endif
