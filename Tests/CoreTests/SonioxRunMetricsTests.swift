import AVFAudio
import Foundation
import XCTest
@testable import LarmindonKit

final class SonioxRunMetricsTests: XCTestCase {
    // MARK: - Timeline

    /// A position inside a buffer maps to that buffer's delivery time minus the audio still
    /// to come after it, so the end of the buffer reads as its delivery time.
    func testTimelineMapsStreamPositionsToCaptureTime() throws {
        let origin = ContinuousClock.now
        var timeline = SonioxStreamTimeline()
        timeline.append(duration: .milliseconds(20), capturedAt: origin + .milliseconds(20))
        // A late buffer: delivered 50 ms after the first rather than 20.
        timeline.append(duration: .milliseconds(20), capturedAt: origin + .milliseconds(70))

        XCTAssertEqual(timeline.capturedAt(streamMilliseconds: 0), origin)
        XCTAssertEqual(timeline.capturedAt(streamMilliseconds: 20), origin + .milliseconds(20))
        XCTAssertEqual(timeline.capturedAt(streamMilliseconds: 30), origin + .milliseconds(60))
        XCTAssertEqual(timeline.capturedAt(streamMilliseconds: 40), origin + .milliseconds(70))
        XCTAssertNil(timeline.capturedAt(streamMilliseconds: 41), "never sent")
    }

    func testTimelineForgetsAudioBeforeTheFinalizedWatermark() {
        let origin = ContinuousClock.now
        var timeline = SonioxStreamTimeline()
        for index in 1...5 {
            timeline.append(duration: .milliseconds(10), capturedAt: origin + .milliseconds(10 * index))
        }

        timeline.discard(before: 25)

        XCTAssertNil(timeline.capturedAt(streamMilliseconds: 10))
        XCTAssertEqual(timeline.capturedAt(streamMilliseconds: 25), origin + .milliseconds(25))
        XCTAssertEqual(timeline.capturedAt(streamMilliseconds: 50), origin + .milliseconds(50))
    }

    /// If Soniox never finalizes, memory stays bounded and old positions read as unknown.
    func testTimelineIsBoundedWhenNothingIsFinalized() {
        let origin = ContinuousClock.now
        var timeline = SonioxStreamTimeline()
        let total = SonioxStreamTimeline.maximumSpans + 2_000
        for index in 1...total {
            timeline.append(duration: .milliseconds(10), capturedAt: origin + .milliseconds(10 * index))
        }

        XCTAssertNil(timeline.capturedAt(streamMilliseconds: 0))
        XCTAssertEqual(
            timeline.capturedAt(streamMilliseconds: total * 10),
            origin + .milliseconds(total * 10)
        )
    }

    // MARK: - Histogram

    func testHistogramQuantilesAreBucketBoundsClampedToTheMaximum() {
        var histogram = LatencyHistogram()
        for milliseconds in [5, 15, 15, 40, 400] {
            histogram.record(milliseconds: milliseconds)
        }

        XCTAssertEqual(histogram.quantileMilliseconds(0.5), 20)
        XCTAssertEqual(histogram.quantileMilliseconds(0.8), 40)
        XCTAssertEqual(histogram.quantileMilliseconds(1.0), 400, "clamped to the largest value seen")
        XCTAssertEqual(histogram.maximumMilliseconds, 400)
        XCTAssertEqual(histogram.fields(prefix: "x")["x_mean_ms"], "95.0")
        XCTAssertTrue(histogram.bucketDescription.hasPrefix("le5:1,le10:0,le20:2,le30:0,le40:1,"))
    }

    func testEmptyHistogramReportsACountRatherThanZeroLatency() {
        let fields = LatencyHistogram().fields(prefix: "processed_age")
        XCTAssertEqual(fields, ["processed_age_count": "0"])
    }

    func testMergedHistogramsAddBuckets() {
        var first = LatencyHistogram()
        first.record(milliseconds: 5)
        var second = LatencyHistogram()
        second.record(milliseconds: 35_000)

        first.merge(second)

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.maximumMilliseconds, 35_000)
        XCTAssertEqual(first.counts.first, 1)
        XCTAssertEqual(first.counts.last, 1)
    }

    // MARK: - Freshness

    func testStaleIntervalOpensAboveTheThresholdAndClosesOnCatchUp() {
        let start = ContinuousClock.now
        var freshness = SonioxFreshness()

        XCTAssertNil(freshness.observe(processedAge: .seconds(1), at: start))
        XCTAssertEqual(freshness.observe(processedAge: .seconds(4), at: start + .seconds(1)), .began)
        XCTAssertNil(freshness.observe(processedAge: .seconds(6), at: start + .seconds(2)))
        XCTAssertEqual(
            freshness.observe(processedAge: .milliseconds(800), at: start + .seconds(5)),
            .ended(duration: .seconds(4), worstAge: .seconds(6))
        )
        XCTAssertEqual(freshness.fields()["stale_intervals"], "1")
        XCTAssertEqual(freshness.fields()["stale_ms"], "4000")
    }

    // MARK: - Send window

    func testSendWindowReportsRateOverAudioTime() {
        var window = SonioxSendWindow()
        for _ in 0..<50 {
            window.recordFrame(audioDuration: .milliseconds(20), encode: .microseconds(150), queueAge: .milliseconds(3))
        }
        window.recordSend(bytes: 4_000, send: .milliseconds(2))

        let fields = window.fields()
        XCTAssertEqual(fields["audio_ms"], "1000")
        XCTAssertEqual(fields["kbps"], "32")
        XCTAssertEqual(fields["encode_ms"], "7")
        XCTAssertEqual(fields["encode_max_us"], "150")
        XCTAssertEqual(fields["queue_age_p95_ms"], "3")
        XCTAssertEqual(fields["sends"], "1")
    }
}

@MainActor
final class SonioxRunInstrumentationTests: XCTestCase {
    /// The events a codec comparison is scored from: a manifest up front, an age for every
    /// update measured from capture time, and a summary at the end, all under one run ID.
    func testRunIsBracketedAndUpdatesCarryCaptureAges() async throws {
        let transport = FakeWebSocketTransport()
        let diagnostics = DiagnosticRecorder(capacity: 200)
        let source = SonioxTranscriptionSource(
            apiKey: "test-key",
            diagnostics: diagnostics,
            transport: transport,
            gracefulShutdownTimeout: .milliseconds(200)
        )
        let (frames, frameContinuation) = AsyncStream<CapturedAudioFrame>.makeStream()
        let consumer = Task { for await _ in source.results {} }

        try await source.start(audioFrames: frames)
        let capturedAt = ContinuousClock.now - .milliseconds(500)
        frameContinuation.yield(CapturedAudioFrame(buffer: try makeTenMillisecondBuffer(), capturedAt: capturedAt))
        await transport.waitForBinaryMessageCount(1)
        await transport.enqueue(
            .text(
                """
                {"tokens":[{"text":"Hi","start_ms":0,"end_ms":10,"is_final":false}],"final_audio_proc_ms":0,"total_audio_proc_ms":10}
                """
            )
        )
        let update = try await waitForEvent(named: "soniox_update", in: diagnostics)

        frameContinuation.finish()
        let stop = Task { await source.stop() }
        await transport.waitForTextMessageCount(2)
        await transport.enqueue(.text("{\"tokens\":[],\"finished\":true}"))
        await stop.value
        consumer.cancel()

        let runID = source.runID.uuidString
        let events = await diagnostics.snapshot()
        let started = try XCTUnwrap(events.first { $0.name == "run_started" })
        XCTAssertEqual(started.fields["run_id"], runID)
        XCTAssertEqual(started.fields["requested_encoding"], "pcm")
        XCTAssertEqual(update.fields["run_id"], runID)
        XCTAssertEqual(update.fields["connection"], "1")
        XCTAssertEqual(update.fields["sent_audio_ms"], "10")
        let age = try XCTUnwrap(Int(try XCTUnwrap(update.fields["visible_token_age_ms"])))
        XCTAssertGreaterThanOrEqual(age, 500, "measured from the frame's capture time")
        XCTAssertNotNil(Int(try XCTUnwrap(update.fields["processed_age_ms"])))

        let completed = try XCTUnwrap(events.last { $0.name == "run_completed" })
        XCTAssertEqual(completed.fields["run_id"], runID)
        XCTAssertEqual(completed.fields["finish_outcome"], "finished")
        XCTAssertEqual(completed.fields["frames"], "1")
        XCTAssertEqual(completed.fields["bytes_total"], "320")
        XCTAssertEqual(completed.fields["visible_token_age_count"], "1")
        XCTAssertEqual(completed.fields["source_format"], "48000Hz/1ch")
    }

    /// The delay each encoding adds before audio leaves the phone, measured the same way for
    /// all three: PCM none, Opus a packet plus lookahead, FLAC up to two blocks.
    func testEncoderHoldIsReportedForEachEncoding() async throws {
        var means: [SonioxAudioEncoding: Double] = [:]
        for encoding in SonioxAudioEncoding.allCases {
            let transport = FakeWebSocketTransport()
            let diagnostics = DiagnosticRecorder(capacity: 200)
            let source = SonioxTranscriptionSource(
                apiKey: "test-key",
                diagnostics: diagnostics,
                transport: transport,
                gracefulShutdownTimeout: .seconds(5),
                audioEncoding: encoding
            )
            let (frames, frameContinuation) = AsyncStream<CapturedAudioFrame>.makeStream()
            let consumer = Task { for await _ in source.results {} }
            try await source.start(audioFrames: frames)
            for _ in 0..<100 {
                frameContinuation.yield(CapturedAudioFrame(buffer: try makeTenMillisecondBuffer()))
            }
            frameContinuation.finish()
            // Answer the finish handshake, so every frame is encoded before the run ends.
            let stop = Task { await source.stop() }
            await transport.waitForTextMessageCount(2)
            await transport.enqueue(.text("{\"tokens\":[],\"finished\":true}"))
            await stop.value
            consumer.cancel()

            let events = await diagnostics.snapshot()
            let completed = try XCTUnwrap(events.last { $0.name == "run_completed" })
            XCTAssertEqual(completed.fields["encoder_hold_count"], "100", "\(encoding)")
            means[encoding] = Double(try XCTUnwrap(completed.fields["encoder_hold_mean_ms"]))
        }

        XCTAssertEqual(try XCTUnwrap(means[.pcm]), 0, accuracy: 0.5)
        // 10 ms buffers: Opus holds 6.5 + 0 or 10 ms, FLAC 20 or 30 ms after each.
        XCTAssertEqual(try XCTUnwrap(means[.opus]), 11.5, accuracy: 1.5)
        XCTAssertEqual(try XCTUnwrap(means[.flac]), 25, accuracy: 1.5)
    }

    private func waitForEvent(
        named name: String,
        in diagnostics: DiagnosticRecorder
    ) async throws -> DiagnosticEvent {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if let event = await diagnostics.snapshot().first(where: { $0.name == name }) {
                return event
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("no \(name) event within 2 s")
        throw CancellationError()
    }

    private func makeTenMillisecondBuffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<480 { samples[index] = sin(Float(index) * 0.1) * 0.2 }
        }
        return buffer
    }
}
