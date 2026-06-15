import AVFAudio
import Foundation

public struct AudioLevelSnapshot: Equatable, Sendable {
    public var rawInputLevel: Double
    public var processedInputLevel: Double
    public var vadState: String

    public init(rawInputLevel: Double = 0, processedInputLevel: Double = 0, vadState: String = "Unknown") {
        self.rawInputLevel = rawInputLevel
        self.processedInputLevel = processedInputLevel
        self.vadState = vadState
    }
}

public enum AudioLevelMeter {
    public static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData else {
            return 0
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else {
            return 0
        }

        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sum += sample * sample
            }
        }

        let meanSquare = sum / Float(channelCount * frameLength)
        let rms = sqrt(meanSquare)
        return min(1, max(0, Double(rms) * 8))
    }

    public static func smooth(previous: Double, next: Double, attack: Double = 0.35, release: Double = 0.12) -> Double {
        let factor = next > previous ? attack : release
        return previous + (next - previous) * factor
    }
}
