import AVFAudio
import Foundation

#if os(macOS)
import AudioToolbox
import CoreAudio
#endif

/// Outcome of configuring an `AVAudioEngine` input node for capture.
struct AudioEngineInputConfiguration {
    /// The format the node reports it will produce, recorded for diagnostics. Taps are
    /// installed with a nil format so the node's own format always wins.
    let nodeFormat: AVAudioFormat
    let activeVoiceProcessingEnabled: Bool
    /// Set when voice processing was requested but deliberately not applied.
    let voiceProcessingSkippedReason: String?
}

/// Identifies which call failed while configuring the engine, so a diagnostics bundle
/// pins the failure to a step instead of just carrying an OSStatus.
struct AudioEngineConfigurationFailure: LocalizedError {
    let step: String
    let underlying: Error

    var errorDescription: String? { underlying.localizedDescription }
}

enum AudioEngineInputConfigurator {
    /// Whether a format reported by an input node can carry a tap.
    ///
    /// Changing the current device can briefly leave the node reporting 0 Hz or no
    /// channels.
    static func isUsableCaptureFormat(
        sampleRate: Double,
        channelCount: AVAudioChannelCount
    ) -> Bool {
        sampleRate > 0 && channelCount > 0
    }

    /// Configures an input node for capture.
    ///
    /// This mutates the engine, so callers must run it with no `await` between this call
    /// and `AVAudioEngine.start()`. An intervening HAL change can invalidate the node's
    /// configuration and make `start()` fail.
    ///
    /// Only ever used for the system default input on macOS; other devices are read
    /// directly through Core Audio. See `MacOSAudioCaptureStrategy`.
    static func configure(
        inputNode: AVAudioInputNode,
        requestedVoiceProcessingEnabled: Bool
    ) throws -> AudioEngineInputConfiguration {
        var voiceProcessingEnabled = requestedVoiceProcessingEnabled
        var voiceProcessingSkippedReason: String?

        #if os(macOS)
        if voiceProcessingEnabled {
            // Voice processing spans input and output as a single duplex unit, and on
            // macOS that pairing has to be built across whatever the default input and
            // default output happen to be. Those are separate devices with independent
            // sample rates, and when they disagree — a 48 kHz microphone against a
            // 44.1 kHz virtual output, say — the unit fails engine start with
            // kAudioUnitErr_FailedInitialization instead of degrading. Pointing it at an
            // explicitly chosen input is fragile for the same reason.
            //
            // iOS applies the same processing through the audio session category and mode
            // rather than through this unit, so it is unaffected and keeps echo
            // cancellation and automatic gain control.
            voiceProcessingEnabled = false
            voiceProcessingSkippedReason = "unsupported_on_macos"
        }
        #endif

        do {
            try inputNode.setVoiceProcessingEnabled(voiceProcessingEnabled)
        } catch {
            // Some inputs reject voice processing outright. Losing echo cancellation is
            // better than refusing to caption at all.
            guard voiceProcessingEnabled else {
                throw AudioEngineConfigurationFailure(
                    step: "voice_processing_disable",
                    underlying: error
                )
            }
            voiceProcessingEnabled = false
            voiceProcessingSkippedReason = "rejected_by_input"
            do {
                try inputNode.setVoiceProcessingEnabled(false)
            } catch {
                throw AudioEngineConfigurationFailure(
                    step: "voice_processing_fallback",
                    underlying: error
                )
            }
        }

        return AudioEngineInputConfiguration(
            nodeFormat: inputNode.outputFormat(forBus: 0),
            activeVoiceProcessingEnabled: inputNode.isVoiceProcessingEnabled,
            voiceProcessingSkippedReason: voiceProcessingSkippedReason
        )
    }
}

#if os(macOS)
func macOSDefaultInputDeviceID() -> AudioDeviceID? {
    var deviceID = AudioDeviceID(0)
    var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &dataSize,
        &deviceID
    ) == noErr, deviceID != 0 else {
        return nil
    }
    return deviceID
}

#endif

/// Rolling capture counters, reported periodically so a diagnostics bundle shows whether
/// audio kept flowing after `capture_started`.
final class AudioCaptureTelemetry: @unchecked Sendable {
    struct Snapshot {
        let callbacks: Int
        let frames: Int
        let droppedBuffers: Int
        let meanRMS: Double
        let peak: Double
        let silentCallbacks: Int
    }

    private let lock = NSLock()
    private let diagnostics: DiagnosticRecorder
    private var callbacks = 0
    private var frames = 0
    private var droppedBuffers = 0
    private var weightedSquareSum = 0.0
    private var peak = 0.0
    private var silentCallbacks = 0

    init(diagnostics: DiagnosticRecorder) {
        self.diagnostics = diagnostics
    }

    func record(
        frameCount: Int,
        dropped: Bool,
        measurement: AudioSignalMeasurement = AudioSignalMeasurement()
    ) {
        lock.lock()
        callbacks += 1
        frames += frameCount
        if dropped {
            droppedBuffers += 1
        }
        // Weighting by frame count keeps the session mean correct if buffer sizes vary.
        weightedSquareSum += measurement.rms * measurement.rms * Double(frameCount)
        peak = max(peak, measurement.peak)
        if measurement.isDigitalSilence {
            silentCallbacks += 1
        }
        let shouldReport = callbacks.isMultiple(of: 100)
        let snapshot = makeSnapshotLocked()
        lock.unlock()

        if shouldReport {
            Task { [diagnostics] in
                await diagnostics.record(
                    category: "audio",
                    name: "capture_aggregate",
                    fields: snapshot.diagnosticFields
                )
            }
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshotLocked()
    }

    /// Caller must hold `lock`.
    private func makeSnapshotLocked() -> Snapshot {
        Snapshot(
            callbacks: callbacks,
            frames: frames,
            droppedBuffers: droppedBuffers,
            meanRMS: frames > 0 ? (weightedSquareSum / Double(frames)).squareRoot() : 0,
            peak: peak,
            silentCallbacks: silentCallbacks
        )
    }

    /// Reports if no audio arrived shortly after capture started, so a bundle tells
    /// "started but silent" apart from "never started" or "stopped before audio flowed".
    /// The caller owns the returned task and should cancel it when capture stops.
    func scheduleStallCheck(
        after duration: Duration = .seconds(3),
        fields: [String: String]
    ) -> Task<Void, Never> {
        Task { [self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            let snapshot = snapshot()
            guard snapshot.callbacks == 0 else { return }
            await diagnostics.record(
                category: "error",
                name: "capture_stalled",
                fields: fields.merging(snapshot.diagnosticFields) { current, _ in current }
            )
        }
    }
}

extension AudioCaptureTelemetry.Snapshot {
    var diagnosticFields: [String: String] {
        [
            "callbacks": String(callbacks),
            "frames": String(frames),
            "dropped_buffers": String(droppedBuffers),
            // Frame counts prove audio kept flowing but not that it contained anything.
            // These distinguish "captured speech" from "captured silence", which is
            // otherwise unanswerable from a bundle alone.
            "rms_dbfs": AudioLevelMeter.dBFSDescription(meanRMS),
            "peak_dbfs": AudioLevelMeter.dBFSDescription(peak),
            "silent_callbacks": String(silentCallbacks),
        ]
    }
}
