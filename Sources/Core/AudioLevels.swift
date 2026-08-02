import AVFAudio
import Foundation

public struct AudioLevelSnapshot: Equatable, Sendable {
    public var rawInputLevel: Double
    public var processedInputLevel: Double
    public var speechDetected: Bool
    public var vadState: String
    public var observedCallbackFrameLength: Int?

    public init(
        rawInputLevel: Double = 0,
        processedInputLevel: Double = 0,
        speechDetected: Bool = false,
        vadState: String = "Unknown",
        observedCallbackFrameLength: Int? = nil
    ) {
        self.rawInputLevel = rawInputLevel
        self.processedInputLevel = processedInputLevel
        self.speechDetected = speechDetected
        self.vadState = vadState
        self.observedCallbackFrameLength = observedCallbackFrameLength
    }
}

/// Raw signal measurements for one capture buffer, both relative to full scale.
///
/// These are deliberately unscaled. `AudioLevelMeter.normalizedRMS` applies a display gain
/// and clamps to 1, so it saturates long before a signal actually clips and cannot tell a
/// loud input from a distorting one. Diagnostics need the untouched values, and `peak`
/// specifically answers the question a frame count cannot: whether the buffers that arrived
/// contained anything at all.
public struct AudioSignalMeasurement: Equatable, Sendable {
    public let rms: Double
    public let peak: Double

    public init(rms: Double = 0, peak: Double = 0) {
        self.rms = rms
        self.peak = peak
    }

    /// True when every sample in the buffer was exactly zero, which distinguishes a device
    /// delivering digital silence from one delivering a very quiet room.
    public var isDigitalSilence: Bool {
        peak == 0
    }
}

public enum AudioLevelMeter {
    /// Speech RMS sits well below full scale, so the meter bar would barely move without a
    /// display gain. This scaling is presentation-only and never applied to `measure`.
    private static let displayGain = 8.0

    public static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Double {
        displayLevel(for: measure(from: buffer))
    }

    public static func displayLevel(for measurement: AudioSignalMeasurement) -> Double {
        min(1, max(0, measurement.rms * displayGain))
    }

    public static func measure(from buffer: AVAudioPCMBuffer) -> AudioSignalMeasurement {
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else {
            return AudioSignalMeasurement()
        }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData else {
                return AudioSignalMeasurement()
            }
            return measure(
                channelData: channelData,
                channelCount: channelCount,
                frameLength: frameLength,
                isInterleaved: buffer.format.isInterleaved
            )
        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData else {
                return AudioSignalMeasurement()
            }
            return measure(
                channelData: channelData,
                channelCount: channelCount,
                frameLength: frameLength,
                isInterleaved: buffer.format.isInterleaved
            )
        default:
            return AudioSignalMeasurement()
        }
    }

    private static func measure(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameLength: Int,
        isInterleaved: Bool
    ) -> AudioSignalMeasurement {
        let sampleCount = channelCount * frameLength
        var sum: Float = 0
        var peak: Float = 0

        if isInterleaved {
            let samples = channelData[0]
            for sampleIndex in 0..<sampleCount {
                let sample = samples[sampleIndex]
                sum += sample * sample
                peak = max(peak, abs(sample))
            }
        } else {
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for frame in 0..<frameLength {
                    let sample = samples[frame]
                    sum += sample * sample
                    peak = max(peak, abs(sample))
                }
            }
        }

        let meanSquare = sum / Float(sampleCount)
        return AudioSignalMeasurement(
            rms: max(0, Double(sqrt(meanSquare))),
            peak: min(1, max(0, Double(peak)))
        )
    }

    private static func measure(
        channelData: UnsafePointer<UnsafeMutablePointer<Int16>>,
        channelCount: Int,
        frameLength: Int,
        isInterleaved: Bool
    ) -> AudioSignalMeasurement {
        let sampleCount = channelCount * frameLength
        var sum: Float = 0
        var peak: Float = 0

        if isInterleaved {
            let samples = channelData[0]
            for sampleIndex in 0..<sampleCount {
                let sample = Float(samples[sampleIndex]) / Float(Int16.max)
                sum += sample * sample
                peak = max(peak, abs(sample))
            }
        } else {
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for frame in 0..<frameLength {
                    let sample = Float(samples[frame]) / Float(Int16.max)
                    sum += sample * sample
                    peak = max(peak, abs(sample))
                }
            }
        }

        let meanSquare = sum / Float(sampleCount)
        return AudioSignalMeasurement(
            rms: max(0, Double(sqrt(meanSquare))),
            peak: min(1, max(0, Double(peak)))
        )
    }

    /// Formats a full-scale magnitude as dBFS for diagnostics. Digital silence has no
    /// logarithm, so it reports as `-inf` rather than a misleading large negative number.
    public static func dBFSDescription(_ magnitude: Double) -> String {
        guard magnitude > 0 else { return "-inf" }
        return String(format: "%.1f", 20 * log10(magnitude))
    }

    public static func smooth(previous: Double, next: Double, attack: Double = 0.35, release: Double = 0.12) -> Double {
        let factor = next > previous ? attack : release
        return previous + (next - previous) * factor
    }
}
