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
        let configurationMessages = await transport.sentTextMessages
        let configurationData = try XCTUnwrap(
            configurationMessages.first?.data(using: .utf8)
        )
        let configurationJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: configurationData)
                as? [String: Any]
        )
        XCTAssertEqual(
            configurationJSON["language_hints"] as? [String],
            ["en"]
        )

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
                {"tokens":[{"text":"Hello.","start_ms":0,"end_ms":100,"confidence":0.9,"is_final":true,"speaker":"1"}],"final_audio_proc_ms":100,"total_audio_proc_ms":100}
                """
            )
        )
        let result = await resultIterator.next()
        XCTAssertEqual(
            result,
            .finalizedSegments([
                CaptionSegment(text: "Hello.", speakerID: "1")
            ])
        )

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

    func testSpeakerSegmentsFollowTokenSpeakerBoundaries() throws {
        let tokens = try decodeTokens(
            """
            [
              {"text":"Hello","is_final":true,"speaker":"1"},
              {"text":" there.","is_final":true,"speaker":"1"},
              {"text":"Hi","is_final":true,"speaker":"2"},
              {"text":" again.","is_final":true,"speaker":"2"},
              {"text":" Unassigned.","is_final":true}
            ]
            """
        )

        XCTAssertEqual(
            SonioxSpeakerSegmentFormatter.segments(tokens: tokens),
            [
                CaptionSegment(text: "Hello there.", speakerID: "1"),
                CaptionSegment(
                    text: "Hi again. Unassigned.",
                    speakerID: "2"
                ),
            ]
        )
    }

    func testSpeakerSegmentFormatterLeavesUndiarizedTextUnchanged() throws {
        let tokens = try decodeTokens(
            """
            [
              {"text":"No","is_final":false},
              {"text":" speaker","is_final":false},
              {"text":" metadata","is_final":false}
            ]
            """
        )

        XCTAssertEqual(
            SonioxSpeakerSegmentFormatter.segments(tokens: tokens),
            [CaptionSegment(text: "No speaker metadata")]
        )
    }

    func testSpeakerSegmentFormatterNormalizesProviderSpeakerID() throws {
        let tokens = try decodeTokens(
            """
            [
              {"text":"Hello","is_final":false,"speaker":" 7 "}
            ]
            """
        )

        XCTAssertEqual(
            SonioxSpeakerSegmentFormatter.segments(tokens: tokens),
            [CaptionSegment(text: "Hello", speakerID: "7")]
        )
    }

    func testSentenceAccumulatorKeepsFinalWordsLiveUntilPunctuation()
        throws
    {
        var accumulator = SonioxSentenceAccumulator()

        XCTAssertEqual(
            accumulator.consume(
                finalizedTokens: try decodeTokens(
                    """
                    [{"text":"Great","is_final":true,"speaker":"1"}]
                    """
                )
            ),
            []
        )
        XCTAssertEqual(
            accumulator.preview(
                nonFinalTokens: try decodeTokens(
                    """
                    [{"text":" work","is_final":false,"speaker":"1"}]
                    """
                )
            ),
            [CaptionSegment(text: "Great work", speakerID: "1")]
        )
        XCTAssertEqual(
            accumulator.consume(
                finalizedTokens: try decodeTokens(
                    """
                    [
                      {"text":" work","is_final":true,"speaker":"1"},
                      {"text":".","is_final":true,"speaker":"1"}
                    ]
                    """
                )
            ),
            [CaptionSegment(text: "Great work.", speakerID: "1")]
        )
        XCTAssertEqual(accumulator.preview(nonFinalTokens: []), [])
    }

    func testSentenceAccumulatorSplitsCompletedSentenceInsideBatch()
        throws
    {
        var accumulator = SonioxSentenceAccumulator()
        let completed = accumulator.consume(
            finalizedTokens: try decodeTokens(
                """
                [
                  {"text":"First","is_final":true,"speaker":"1"},
                  {"text":".","is_final":true,"speaker":"1"},
                  {"text":" Second","is_final":true,"speaker":"1"},
                  {"text":" continues","is_final":true,"speaker":"1"}
                ]
                """
            )
        )

        XCTAssertEqual(
            completed,
            [CaptionSegment(text: "First.", speakerID: "1")]
        )
        XCTAssertEqual(
            accumulator.preview(nonFinalTokens: []),
            [CaptionSegment(text: "Second continues", speakerID: "1")]
        )
    }

    func testSentenceAccumulatorFlushesWhenSpeakerChanges() throws {
        var accumulator = SonioxSentenceAccumulator()
        let completed = accumulator.consume(
            finalizedTokens: try decodeTokens(
                """
                [
                  {"text":"No punctuation","is_final":true,"speaker":"1"},
                  {"text":"New speaker","is_final":true,"speaker":"2"}
                ]
                """
            )
        )

        XCTAssertEqual(
            completed,
            [CaptionSegment(text: "No punctuation", speakerID: "1")]
        )
        XCTAssertEqual(
            accumulator.preview(nonFinalTokens: []),
            [CaptionSegment(text: "New speaker", speakerID: "2")]
        )
    }

    private func decodeTokens(_ json: String) throws -> [SonioxToken] {
        try JSONDecoder().decode(
            [SonioxToken].self,
            from: try XCTUnwrap(json.data(using: .utf8))
        )
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
