import AVFAudio
import Foundation
import XCTest
@testable import LarmindonKit

@MainActor
final class SonioxFLACEncoderTests: XCTestCase {
    func testStreamHeaderIsFLACMarkerAndStreamInfo() {
        let header = SonioxFLACEncoder.streamHeader(
            sampleRate: 16_000,
            channelCount: 1,
            bitsPerSample: 16,
            blockSize: 320
        )

        let expected: [UInt8] =
            Array("fLaC".utf8)
            + [0x80, 0x00, 0x00, 0x22]  // last block, STREAMINFO, 34 bytes
            + [0x01, 0x40, 0x01, 0x40]  // 320-frame blocks
            + [0, 0, 0, 0, 0, 0]  // frame sizes unknown
            + [0x03, 0xE8, 0x00, 0xF0, 0, 0, 0, 0]  // 16 kHz, mono, 16-bit, length unknown
            + [UInt8](repeating: 0, count: 16)  // no MD5
        XCTAssertEqual([UInt8](header), expected)
    }

    /// Lossless is the point of this encoding: what Soniox decodes must be exactly the
    /// samples PCM would have sent. Decoded here through Apple's own FLAC file reader,
    /// which checks the stream header and every frame.
    func testStreamDecodesToIdenticalSamplesAtEachRate() throws {
        for rate in SonioxFLACSampleRate.allCases {
            let encoder = try XCTUnwrap(SonioxFLACEncoder(sampleRate: rate), "\(rate) unavailable")
            XCTAssertEqual(encoder.diagnosticFields["sample_rate"], String(rate.rawValue))
            XCTAssertEqual(encoder.diagnosticFields["block_frames"], String(rate.rawValue / 50))

            var stream = encoder.startStream()
            var input: [Int16] = []
            // Half a second in odd-sized buffers, so blocks straddle buffer boundaries.
            let bufferFrames = rate.rawValue / 50 + 37
            for index in 0..<(rate.rawValue / 2 / bufferFrames) {
                let buffer = try makeSpeechLikeBuffer(
                    sampleRate: Double(rate.rawValue),
                    frames: bufferFrames,
                    offset: index * bufferFrames
                )
                input += Array(UnsafeBufferPointer(start: buffer.int16ChannelData?[0], count: bufferFrames))
                stream.append(try XCTUnwrap(encoder.encode(buffer), "conversion failed"))
            }

            let blockFrames = rate.rawValue / 50
            let completeBlocks = input.count / blockFrames
            let decoded = try decode(stream, totalSamples: completeBlocks * blockFrames)
            // The encoder still holds the last complete block, waiting for the next to fill.
            XCTAssertEqual(decoded.count, (completeBlocks - 1) * blockFrames, "\(rate)")
            XCTAssertEqual(decoded, Array(input.prefix(decoded.count)), "\(rate) is not lossless")
            XCTAssertLessThan(stream.count, input.count * 2 * 8 / 10, "\(rate) should compress")
        }
    }

    /// Apple's encoder releases a 320-frame block only once the next block has filled, so
    /// up to 40 ms waits in it. A change here changes FLAC's latency against PCM.
    func testEncoderReleasesABlockOnceTheNextHasFilled() throws {
        let encoder = try XCTUnwrap(SonioxFLACEncoder())
        _ = encoder.startStream()

        let held = try XCTUnwrap(encoder.encode(try makeSpeechLikeBuffer(sampleRate: 16_000, frames: 639)))
        XCTAssertTrue(held.isEmpty)

        let released = try XCTUnwrap(
            encoder.encode(try makeSpeechLikeBuffer(sampleRate: 16_000, frames: 1, offset: 639))
        )
        XCTAssertEqual(Array(released.prefix(2)), [0xFF, 0xF8], "starts with a FLAC frame sync code")
        XCTAssertEqual(released[4], 0, "exactly one frame, number 0")
    }

    /// A reconnect is a new stream to Soniox, so frame numbering restarts at zero rather
    /// than continuing from the previous connection.
    func testStartStreamRestartsFrameNumbering() throws {
        let encoder = try XCTUnwrap(SonioxFLACEncoder())
        _ = encoder.startStream()
        let first = try XCTUnwrap(encoder.encode(try makeSpeechLikeBuffer(sampleRate: 16_000, frames: 960)))
        XCTAssertEqual(first[4], 0, "first frame is number 0")

        let header = encoder.startStream()
        XCTAssertEqual(header.prefix(4), Data("fLaC".utf8))
        let restarted = try XCTUnwrap(encoder.encode(try makeSpeechLikeBuffer(sampleRate: 16_000, frames: 640)))
        XCTAssertEqual(Array(restarted.prefix(2)), [0xFF, 0xF8])
        XCTAssertEqual(restarted[4], 0, "numbering restarted")
    }

    func testSonioxSourceSendsFLACHeaderFirstAndRequestsAutoFormat() async throws {
        let transport = FakeWebSocketTransport()
        let diagnostics = DiagnosticRecorder(capacity: 100)
        let source = SonioxTranscriptionSource(
            apiKey: "test-key",
            diagnostics: diagnostics,
            transport: transport,
            // Nothing answers the finish handshake here, so don't wait the real 5 s.
            gracefulShutdownTimeout: .milliseconds(10),
            audioEncoding: .flac,
            flacSampleRate: .hz24000
        )
        let (frames, frameContinuation) = AsyncStream<CapturedAudioFrame>.makeStream()

        try await source.start(audioFrames: frames)
        let configurationMessages = await transport.sentTextMessages
        let configuration = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(configurationMessages.first?.data(using: .utf8))
            ) as? [String: Any]
        )
        XCTAssertEqual(configuration["audio_format"] as? String, "auto")
        XCTAssertNil(configuration["sample_rate"], "STREAMINFO carries the rate")

        await transport.waitForBinaryMessageCount(1)
        let binaryMessages = await transport.sentBinaryMessages
        let header = try XCTUnwrap(binaryMessages.first)
        XCTAssertEqual(header.prefix(4), Data("fLaC".utf8))

        // 48 kHz capture, resampled to 24 kHz: 60 ms is enough for the encoder to release
        // its first block.
        frameContinuation.yield(
            CapturedAudioFrame(buffer: try makeSpeechLikeFloatBuffer(sampleRate: 48_000, frames: 2_880))
        )
        await transport.waitForBinaryMessageCount(2)
        let audio = await transport.sentBinaryMessages[1]
        XCTAssertEqual(Array(audio.prefix(2)), [0xFF, 0xF8])

        frameContinuation.finish()
        await source.stop()

        let events = await diagnostics.snapshot()
        let started = try XCTUnwrap(events.first { $0.name == "run_started" })
        XCTAssertEqual(started.fields["codec"], "flac")
        XCTAssertEqual(started.fields["sample_rate"], "24000")
        XCTAssertEqual(started.fields["encoding"], "flac")
    }

    // MARK: - Helpers

    /// Writes the stream to a file with its length filled in, which `AVAudioFile` needs to
    /// read past the first frame; the live stream leaves it unknown.
    private func decode(_ stream: Data, totalSamples: Int) throws -> [Int16] {
        var bytes = [UInt8](stream)
        // Total samples: the low 36 bits of the 8 bytes after the block sizes and frame sizes.
        let offset = 4 + 4 + 10
        var packed: UInt64 = 0
        for index in 0..<8 { packed = packed << 8 | UInt64(bytes[offset + index]) }
        packed |= UInt64(totalSamples) & 0xF_FFFF_FFFF
        for index in 0..<8 { bytes[offset + index] = UInt8(truncatingIfNeeded: packed >> (8 * (7 - index))) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flac-\(UUID().uuidString).flac")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.int16ChannelData?[0], count: Int(buffer.frameLength)))
    }

    /// A voiced-sounding tone with a little deterministic noise, so FLAC has something
    /// realistic to predict rather than silence or a pure sine.
    private func sample(_ index: Int, sampleRate: Double) -> Double {
        let time = Double(index) / sampleRate
        let voiced = 0.25 * sin(2 * .pi * 140 * time) + 0.12 * sin(2 * .pi * 420 * time)
        let noise = Double((index &* 1_103_515_245 &+ 12_345) % 2_001 - 1_000) / 1_000 * 0.01
        return voiced + noise
    }

    private func makeSpeechLikeBuffer(sampleRate: Double, frames: Int, offset: Int = 0) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false)
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
        for index in 0..<frames {
            samples[index] = Int16(sample(offset + index, sampleRate: sampleRate) * Double(Int16.max))
        }
        return buffer
    }

    private func makeSpeechLikeFloatBuffer(sampleRate: Double, frames: Int) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<frames {
            samples[index] = Float(sample(index, sampleRate: sampleRate))
        }
        return buffer
    }
}
