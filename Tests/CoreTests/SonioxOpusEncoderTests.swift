import AVFAudio
import Foundation
import XCTest
@testable import LarmindonKit

@MainActor
final class SonioxOpusEncoderTests: XCTestCase {
    func testStreamStartsWithOggOpusHeaders() throws {
        let encoder = try XCTUnwrap(SonioxOpusEncoder(), "the platform Opus encoder is unavailable")

        let header = encoder.startStream()

        XCTAssertEqual(header.prefix(4), Data("OggS".utf8))
        XCTAssertNotNil(header.range(of: Data("OpusHead".utf8)))
        XCTAssertNotNil(header.range(of: Data("OpusTags".utf8)))
    }

    /// One second of capture-sized buffers should become about fifty 20 ms packets, at a
    /// small fraction of the 32,000 bytes the same second costs as PCM.
    func testOneSecondOfCaptureEncodesToCompactOggPages() throws {
        let encoder = try XCTUnwrap(SonioxOpusEncoder())
        _ = encoder.startStream()

        var sent = Data()
        var emptyCalls = 0
        for index in 0..<63 {
            let data = try XCTUnwrap(
                encoder.encode(try makeCaptureBuffer(offset: index * 768)),
                "conversion failed"
            )
            if data.isEmpty { emptyCalls += 1 }
            sent.append(data)
        }

        let pageCount = occurrences(of: Data("OggS".utf8), in: sent)
        XCTAssertGreaterThanOrEqual(pageCount, 45)
        XCTAssertLessThan(sent.count, 8_000)
        XCTAssertGreaterThan(sent.count, 1_000)
        // Most buffers yield a packet; the encoder holds the rest until it has 20 ms.
        XCTAssertLessThan(emptyCalls, 20)
    }

    /// Each rate is accepted by the platform encoder and actually changes the upload volume,
    /// rather than being silently clamped to one rate.
    func testEachBitRateCreatesAnEncoderAndScalesOutput() throws {
        var bytesPerSecond: [SonioxOpusBitRate: Int] = [:]
        for rate in SonioxOpusBitRate.allCases {
            let encoder = try XCTUnwrap(SonioxOpusEncoder(bitRate: rate), "\(rate) unavailable")
            XCTAssertEqual(encoder.diagnosticFields["bit_rate_requested"], String(rate.rawValue))
            XCTAssertNotNil(encoder.diagnosticFields["bit_rate_strategy"])
            _ = encoder.startStream()
            var sent = 0
            for index in 0..<63 {
                sent += try XCTUnwrap(encoder.encode(try makeCaptureBuffer(offset: index * 768))).count
            }
            bytesPerSecond[rate] = sent
        }

        let lowest = try XCTUnwrap(bytesPerSecond[.kbps24])
        let highest = try XCTUnwrap(bytesPerSecond[.kbps80])
        XCTAssertGreaterThan(highest, lowest, "rates: \(bytesPerSecond)")
        XCTAssertLessThan(highest, 16_000, "still far below PCM's 32,000 bytes per second")
    }

    /// A reconnect is a new stream to Soniox, so page numbering must restart after the two
    /// header pages rather than continue from the previous connection.
    func testStartStreamRestartsPageSequence() throws {
        let encoder = try XCTUnwrap(SonioxOpusEncoder())
        _ = encoder.startStream()
        for index in 0..<10 {
            _ = encoder.encode(try makeCaptureBuffer(offset: index * 768))
        }

        _ = encoder.startStream()
        var firstPage = Data()
        for index in 0..<10 where firstPage.isEmpty {
            firstPage = try XCTUnwrap(encoder.encode(try makeCaptureBuffer(offset: index * 768)))
        }

        XCTAssertEqual(firstPage.prefix(4), Data("OggS".utf8))
        XCTAssertEqual(littleEndianUInt32(firstPage, at: 18), 2, "first audio page follows the two header pages")
    }

    func testSonioxSourceSendsOggHeaderFirstAndRequestsAutoFormat() async throws {
        let transport = FakeWebSocketTransport()
        let source = SonioxTranscriptionSource(
            apiKey: "test-key",
            diagnostics: DiagnosticRecorder(capacity: 100),
            transport: transport,
            // Nothing answers the finish handshake here, so don't wait the real 5 s.
            gracefulShutdownTimeout: .milliseconds(10),
            audioEncoding: .opus
        )
        let (frames, frameContinuation) = AsyncStream<CapturedAudioFrame>.makeStream()

        try await source.start(audioFrames: frames)
        let configurationMessages = await transport.sentTextMessages
        let configurationData = try XCTUnwrap(
            configurationMessages.first?.data(using: .utf8)
        )
        let configuration = try XCTUnwrap(
            JSONSerialization.jsonObject(with: configurationData) as? [String: Any]
        )
        XCTAssertEqual(configuration["audio_format"] as? String, "auto")
        XCTAssertNil(configuration["sample_rate"], "a container format carries its own rate")
        XCTAssertNil(configuration["num_channels"])

        await transport.waitForBinaryMessageCount(1)
        let headerMessages = await transport.sentBinaryMessages
        let header = try XCTUnwrap(headerMessages.first)
        XCTAssertEqual(header.prefix(4), Data("OggS".utf8))
        XCTAssertNotNil(header.range(of: Data("OpusHead".utf8)))

        for index in 0..<4 {
            frameContinuation.yield(CapturedAudioFrame(buffer: try makeCaptureBuffer(offset: index * 768)))
        }
        await transport.waitForBinaryMessageCount(2)
        let audio = await transport.sentBinaryMessages[1]
        XCTAssertEqual(audio.prefix(4), Data("OggS".utf8))

        frameContinuation.finish()
        await source.stop()
    }

    func testPCMEncodingKeepsRawFormatFields() async throws {
        let transport = FakeWebSocketTransport()
        let source = SonioxTranscriptionSource(
            apiKey: "test-key",
            diagnostics: DiagnosticRecorder(capacity: 100),
            transport: transport,
            // Nothing answers the finish handshake here, so don't wait the real 5 s.
            gracefulShutdownTimeout: .milliseconds(10),
            audioEncoding: .pcm
        )
        let frames = AsyncStream<CapturedAudioFrame> { $0.finish() }

        try await source.start(audioFrames: frames)
        let configurationMessages = await transport.sentTextMessages
        let configurationData = try XCTUnwrap(
            configurationMessages.first?.data(using: .utf8)
        )
        let configuration = try XCTUnwrap(
            JSONSerialization.jsonObject(with: configurationData) as? [String: Any]
        )
        XCTAssertEqual(configuration["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(configuration["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(configuration["num_channels"] as? Int, 1)

        await source.stop()
    }

    // MARK: - Helpers

    /// 768 frames at 48 kHz, the default capture buffer: 16 ms of a speech-band tone.
    private func makeCaptureBuffer(offset: Int) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 768))
        buffer.frameLength = 768
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<768 {
            let time = Float(offset + index) / 48_000
            samples[index] = 0.2 * sin(2 * .pi * 440 * time) + 0.1 * sin(2 * .pi * 1_300 * time)
        }
        return buffer
    }

    private func occurrences(of pattern: Data, in data: Data) -> Int {
        var count = 0
        var searchRange = data.startIndex..<data.endIndex
        while let found = data.range(of: pattern, in: searchRange) {
            count += 1
            searchRange = found.upperBound..<data.endIndex
        }
        return count
    }

    private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return data[start..<start + 4].enumerated().reduce(0) { value, byte in
            value | UInt32(byte.element) << (8 * UInt32(byte.offset))
        }
    }
}
