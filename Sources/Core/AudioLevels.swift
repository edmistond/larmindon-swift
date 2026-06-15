import AVFAudio
import Foundation

public struct AudioLevelSnapshot: Equatable, Sendable {
    public var rawInputLevel: Double
    public var processedInputLevel: Double
    public var speechDetected: Bool
    public var vadState: String

    public init(
        rawInputLevel: Double = 0,
        processedInputLevel: Double = 0,
        speechDetected: Bool = false,
        vadState: String = "Unknown"
    ) {
        self.rawInputLevel = rawInputLevel
        self.processedInputLevel = processedInputLevel
        self.speechDetected = speechDetected
        self.vadState = vadState
    }
}

public enum AudioLevelMeter {
    public static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Double {
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else {
            return 0
        }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData else {
                return 0
            }
            return normalizedRMS(
                channelData: channelData,
                channelCount: channelCount,
                frameLength: frameLength,
                isInterleaved: buffer.format.isInterleaved
            )
        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData else {
                return 0
            }
            return normalizedRMS(
                channelData: channelData,
                channelCount: channelCount,
                frameLength: frameLength,
                isInterleaved: buffer.format.isInterleaved
            )
        default:
            return 0
        }
    }

    private static func normalizedRMS(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameLength: Int,
        isInterleaved: Bool
    ) -> Double {
        let sampleCount = channelCount * frameLength
        var sum: Float = 0

        if isInterleaved {
            let samples = channelData[0]
            for sampleIndex in 0..<sampleCount {
                let sample = samples[sampleIndex]
                sum += sample * sample
            }
        } else {
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for frame in 0..<frameLength {
                    let sample = samples[frame]
                    sum += sample * sample
                }
            }
        }

        let meanSquare = sum / Float(sampleCount)
        let rms = sqrt(meanSquare)
        return min(1, max(0, Double(rms) * 8))
    }

    private static func normalizedRMS(
        channelData: UnsafePointer<UnsafeMutablePointer<Int16>>,
        channelCount: Int,
        frameLength: Int,
        isInterleaved: Bool
    ) -> Double {
        let sampleCount = channelCount * frameLength
        var sum: Float = 0

        if isInterleaved {
            let samples = channelData[0]
            for sampleIndex in 0..<sampleCount {
                let sample = Float(samples[sampleIndex]) / Float(Int16.max)
                sum += sample * sample
            }
        } else {
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for frame in 0..<frameLength {
                    let sample = Float(samples[frame]) / Float(Int16.max)
                    sum += sample * sample
                }
            }
        }

        let meanSquare = sum / Float(sampleCount)
        let rms = sqrt(meanSquare)
        return min(1, max(0, Double(rms) * 8))
    }

    public static func smooth(previous: Double, next: Double, attack: Double = 0.35, release: Double = 0.12) -> Double {
        let factor = next > previous ? attack : release
        return previous + (next - previous) * factor
    }
}
