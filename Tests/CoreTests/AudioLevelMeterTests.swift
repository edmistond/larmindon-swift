import AVFAudio
import XCTest
@testable import LarmindonKit

final class AudioLevelMeterTests: XCTestCase {
    func testMeasuresUnscaledRMSAndPeakForFloatBuffers() throws {
        let buffer = try makeFloatBuffer([0.5, -0.5, 0.5, -0.5])
        let measurement = AudioLevelMeter.measure(from: buffer)

        // Constant magnitude means RMS equals that magnitude, unscaled by display gain.
        XCTAssertEqual(measurement.rms, 0.5, accuracy: 0.0001)
        XCTAssertEqual(measurement.peak, 0.5, accuracy: 0.0001)
        XCTAssertFalse(measurement.isDigitalSilence)
    }

    func testPeakCapturesTransientAboveRMS() throws {
        let buffer = try makeFloatBuffer([0, 0, 0, 0, 0, 0, 0, 0.9])
        let measurement = AudioLevelMeter.measure(from: buffer)

        // A single loud sample in an otherwise quiet buffer is exactly what an averaged
        // level hides, which is why peak is reported separately.
        XCTAssertEqual(measurement.peak, 0.9, accuracy: 0.0001)
        XCTAssertLessThan(measurement.rms, 0.35)
        XCTAssertFalse(measurement.isDigitalSilence)
    }

    func testDigitalSilenceIsDistinguishedFromQuietSignal() throws {
        let silent = AudioLevelMeter.measure(from: try makeFloatBuffer([0, 0, 0, 0]))
        XCTAssertTrue(silent.isDigitalSilence)
        XCTAssertEqual(silent.peak, 0)

        let quiet = AudioLevelMeter.measure(
            from: try makeFloatBuffer([0.0005, -0.0005, 0.0005, -0.0005])
        )
        XCTAssertFalse(quiet.isDigitalSilence)
        XCTAssertGreaterThan(quiet.peak, 0)
    }

    func testInt16BuffersMeasureTheSameAsFloat() throws {
        let float = AudioLevelMeter.measure(from: try makeFloatBuffer([0.5, -0.5]))
        let int16 = AudioLevelMeter.measure(
            from: try makeInt16Buffer([Int16(Float(Int16.max) * 0.5), Int16(Float(Int16.max) * -0.5)])
        )

        XCTAssertEqual(int16.rms, float.rms, accuracy: 0.001)
        XCTAssertEqual(int16.peak, float.peak, accuracy: 0.001)
    }

    func testDisplayLevelAppliesGainAndClamps() throws {
        let quiet = AudioSignalMeasurement(rms: 0.05, peak: 0.05)
        XCTAssertEqual(AudioLevelMeter.displayLevel(for: quiet), 0.4, accuracy: 0.0001)

        // The display scale saturates well below full scale, which is why the meter cannot
        // be used to detect clipping and peak is reported separately for diagnostics.
        let loud = AudioSignalMeasurement(rms: 0.5, peak: 0.9)
        XCTAssertEqual(AudioLevelMeter.displayLevel(for: loud), 1)
    }

    func testNormalizedRMSStillMatchesDisplayLevel() throws {
        let buffer = try makeFloatBuffer([0.05, -0.05, 0.05, -0.05])
        let measurement = AudioLevelMeter.measure(from: buffer)

        XCTAssertEqual(
            AudioLevelMeter.normalizedRMS(from: buffer),
            AudioLevelMeter.displayLevel(for: measurement),
            accuracy: 0.0001
        )
    }

    func testDBFSDescriptionReportsSilenceAsNegativeInfinity() {
        XCTAssertEqual(AudioLevelMeter.dBFSDescription(0), "-inf")
        XCTAssertEqual(AudioLevelMeter.dBFSDescription(1), "0.0")
        XCTAssertEqual(AudioLevelMeter.dBFSDescription(0.5), "-6.0")
    }

    // MARK: - Helpers

    private func makeFloatBuffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData)
        for (index, sample) in samples.enumerated() {
            channel[0][index] = sample
        }
        return buffer
    }

    private func makeInt16Buffer(_ samples: [Int16]) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.int16ChannelData)
        for (index, sample) in samples.enumerated() {
            channel[0][index] = sample
        }
        return buffer
    }
}
