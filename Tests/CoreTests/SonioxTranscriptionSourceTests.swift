import AVFAudio
import Foundation
import XCTest
@testable import LarmindonKit

@MainActor
final class SonioxTranscriptionSourceTests: XCTestCase {
    func testCapturedFloatAudioIsConvertedAndSentAs16KMonoPCM()
        async throws
    {
        let transport = FakeWebSocketTransport()
        let diagnostics = DiagnosticRecorder(capacity: 100)
        let source = SonioxTranscriptionSource(
            apiKey: "test-key",
            diagnostics: diagnostics,
            transport: transport
        )
        let (frames, frameContinuation) =
            AsyncStream<CapturedAudioFrame>.makeStream()
        let results = source.results
        var resultIterator = results.makeAsyncIterator()

        try await source.start(audioFrames: frames)
        frameContinuation.yield(
            CapturedAudioFrame(buffer: try makeTenMillisecondBuffer())
        )
        await transport.waitForBinaryMessageCount(1)

        let sentFrames = await transport.sentBinaryMessages
        XCTAssertEqual(sentFrames.count, 1)
        XCTAssertEqual(sentFrames[0].count, 320)

        await transport.enqueue(
            .text(
                """
                {"tokens":[{"text":"Hello","start_ms":0,"end_ms":100,"confidence":0.9,"is_final":true,"speaker":"1"}],"final_audio_proc_ms":100,"total_audio_proc_ms":100}
                """
            )
        )
        let result = await resultIterator.next()
        XCTAssertEqual(result, .finalized("Hello"))

        frameContinuation.finish()
        let stopTask = Task {
            await source.stop()
        }
        await transport.waitForBinaryMessageCount(2)
        await transport.enqueue(
            .text(
                """
                {"tokens":[],"final_audio_proc_ms":100,"total_audio_proc_ms":100,"finished":true}
                """
            )
        )
        await stopTask.value

        let completionFrames = await transport.sentBinaryMessages
        XCTAssertEqual(completionFrames.last, Data())
        let closeCodes = await transport.closeCodes
        XCTAssertEqual(closeCodes.last, .normalClosure)
    }

    private func makeTenMillisecondBuffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 480
            )
        )
        buffer.frameLength = 480
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<480 {
                samples[index] = sin(Float(index) * 0.1) * 0.2
            }
        }
        return buffer
    }
}
