import Foundation
import XCTest
@testable import LarmindonKit

final class SonioxRealtimeClientTests: XCTestCase {
    func testStartConnectsAndSendsTypedConfigurationFirst() async throws {
        let transport = FakeWebSocketTransport()
        let configuration = SonioxRealtimeConfiguration(
            apiKey: "test-api-key",
            languageHints: ["en"],
            languageIdentificationEnabled: true,
            clientReferenceID: "unit-test"
        )
        let client = SonioxRealtimeClient(
            configuration: configuration,
            transport: transport
        )

        // Same reason as above: an unheld event stream cancels the client out from under
        // the test. Harmless here today, but it's the identical landmine.
        let events = try await client.start()
        defer { withExtendedLifetime(events) {} }

        let connectCount = await transport.connectCount
        let messages = await transport.sentTextMessages
        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(messages.count, 1)

        let data = try XCTUnwrap(messages.first?.data(using: .utf8))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["api_key"] as? String, "test-api-key")
        XCTAssertEqual(json["model"] as? String, "stt-rt-v5")
        XCTAssertEqual(json["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(json["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(json["num_channels"] as? Int, 1)
        XCTAssertEqual(json["enable_speaker_diarization"] as? Bool, true)
        XCTAssertEqual(json["enable_endpoint_detection"] as? Bool, false)
        XCTAssertEqual(json["enable_language_identification"] as? Bool, true)

        await client.cancel()
    }

    func testTokenEvolutionSeparatesStableAppendFromVolatileReplacement()
        async throws
    {
        let transport = FakeWebSocketTransport()
        let client = makeClient(transport: transport)
        let stream = try await client.start()
        var iterator = stream.makeAsyncIterator()

        // One second of signed 16-bit, 16 kHz, mono PCM.
        try await client.sendAudio(Data(repeating: 0, count: 32_000))
        for line in try fixtureLines(named: "soniox_token_evolution") {
            await transport.enqueue(.text(line))
        }

        let first = try transcriptUpdate(from: await iterator.next())
        XCTAssertEqual(first.newlyFinalizedText, "")
        XCTAssertEqual(first.nonFinalText, "How")
        XCTAssertEqual(first.nonFinalTokens.first?.speaker, "2")

        let second = try transcriptUpdate(from: await iterator.next())
        XCTAssertEqual(second.newlyFinalizedText, "How")
        XCTAssertEqual(second.newlyFinalizedTokens.first?.speaker, "1")
        XCTAssertEqual(second.nonFinalText, " are")
        XCTAssertEqual(second.metrics.sentAudioMilliseconds, 1_000)
        XCTAssertEqual(second.metrics.totalProcessedAudioMilliseconds, 620)
        XCTAssertEqual(second.metrics.processingLagMilliseconds, 380)

        let third = try transcriptUpdate(from: await iterator.next())
        XCTAssertEqual(third.newlyFinalizedText, " are")
        XCTAssertEqual(third.nonFinalText, " you")
        XCTAssertEqual(third.nonFinalTokens.first?.language, "en")
        XCTAssertEqual(third.nonFinalTokens.first?.startMilliseconds, 620)
        XCTAssertEqual(third.nonFinalTokens.first?.endMilliseconds, 790)

        await client.cancel()
    }

    func testFinishSendsEmptyBinaryFrameAndWaitsForFinishedResponse()
        async throws
    {
        let transport = FakeWebSocketTransport()
        let client = makeClient(transport: transport)
        let stream = try await client.start()
        var iterator = stream.makeAsyncIterator()

        let finishTask = Task {
            try await client.finish()
        }
        await transport.waitForBinaryMessageCount(1)

        let sentFrames = await transport.sentBinaryMessages
        XCTAssertEqual(sentFrames, [Data()])

        let finished = try fixture(named: "soniox_finished")
        await transport.enqueue(.text(finished))
        try await finishTask.value

        let event = try await iterator.next()
        guard case .finished(let completion) = event else {
            return XCTFail("Expected a finished event.")
        }
        XCTAssertEqual(completion.metrics.finalizedAudioMilliseconds, 1_560)
        XCTAssertEqual(completion.metrics.totalProcessedAudioMilliseconds, 1_680)

        let closeCodes = await transport.closeCodes
        XCTAssertEqual(closeCodes, [.normalClosure])
        let state = await client.state
        XCTAssertEqual(state, .finished)
    }

    func testProviderErrorUsesStableTypeAndEndsEventStream() async throws {
        let transport = FakeWebSocketTransport()
        let client = makeClient(transport: transport)
        let stream = try await client.start()
        var iterator = stream.makeAsyncIterator()

        let response = try fixture(named: "soniox_service_unavailable")
        await transport.enqueue(.text(response))

        do {
            _ = try await iterator.next()
            XCTFail("Expected the provider error to terminate the stream.")
        } catch let SonioxRealtimeClientError.provider(error) {
            XCTAssertEqual(error.code, 503)
            XCTAssertEqual(error.type, "service_unavailable")
            XCTAssertEqual(
                error.requestID,
                "3d37a3bd-5078-47ee-a369-b204e3bbedda"
            )
            XCTAssertEqual(error.retryDisposition, .newRequestMaySucceed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmptyAudioIsReservedForGracefulCompletion() async throws {
        let transport = FakeWebSocketTransport()
        let client = makeClient(transport: transport)
        // Held for the duration of the test. Dropping the event stream terminates it as
        // `.cancelled`, and `start()`'s `onTermination` cancels the client — which raced
        // the assertion below and made this test intermittently fail with
        // `invalidState(expected: "streaming", actual: "cancelled")`.
        let events = try await client.start()
        defer { withExtendedLifetime(events) {} }

        do {
            try await client.sendAudio(Data())
            XCTFail("Expected an empty-frame error.")
        } catch let error as SonioxRealtimeClientError {
            XCTAssertEqual(error, .emptyAudioFrame)
        }

        let frames = await transport.sentBinaryMessages
        XCTAssertTrue(frames.isEmpty)
        await client.cancel()
    }

    func testMissingAPIKeyFailsBeforeOpeningTransport() async {
        let transport = FakeWebSocketTransport()
        let client = SonioxRealtimeClient(
            configuration: SonioxRealtimeConfiguration(apiKey: "  "),
            transport: transport
        )

        do {
            _ = try await client.start()
            XCTFail("Expected a missing-key configuration error.")
        } catch let error as SonioxRealtimeClientError {
            XCTAssertEqual(
                error,
                .invalidConfiguration("An API key is required.")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let connectCount = await transport.connectCount
        XCTAssertEqual(connectCount, 0)
    }

    func testUnexpectedBinaryServerMessageFailsWithoutFallback() async throws {
        let transport = FakeWebSocketTransport()
        let client = makeClient(transport: transport)
        let stream = try await client.start()
        var iterator = stream.makeAsyncIterator()

        await transport.enqueue(.binary(Data([0x01])))

        do {
            _ = try await iterator.next()
            XCTFail("Expected an unexpected-message error.")
        } catch let error as SonioxRealtimeClientError {
            XCTAssertEqual(error, .unexpectedBinaryMessage)
        }

        let state = await client.state
        XCTAssertEqual(state, .failed)
    }

    func testCancelDuringConnectCannotResurrectStreaming() async throws {
        let transport = FakeWebSocketTransport()
        let gate = AsyncGate()
        await transport.pauseConnect(on: gate)
        let client = makeClient(transport: transport)
        let start = Task { try await client.start() }
        await gate.waitUntilEntered()
        await client.cancel()
        await gate.release()
        do { _ = try await start.value; XCTFail("Cancelled connect must fail") } catch {
            XCTAssertEqual(error as? SonioxRealtimeClientError, .cancelled)
        }
        let state = await client.state
        let messages = await transport.sentTextMessages
        XCTAssertEqual(state, .cancelled)
        XCTAssertTrue(messages.isEmpty)
    }

    func testTaskCancellationWhileSendingConfigurationCannotStartReceiver() async throws {
        let transport = FakeWebSocketTransport()
        let gate = AsyncGate()
        await transport.pauseText(on: gate)
        let client = makeClient(transport: transport)
        let start = Task { try await client.start() }
        await gate.waitUntilEntered()
        start.cancel()
        await gate.release()
        do { _ = try await start.value; XCTFail("Cancelled configuration must fail") } catch {
            XCTAssertEqual(error as? SonioxRealtimeClientError, .cancelled)
        }
        let state = await client.state
        XCTAssertEqual(state, .cancelled)
    }

    func testAudioSendFailureTerminatesTheEventStream() async throws {
        let transport = FakeWebSocketTransport()
        let client = makeClient(transport: transport)
        let stream = try await client.start()
        await transport.failBinary(with: .operationFailed("send failed"))
        do { try await client.sendAudio(Data([1, 2])); XCTFail("Send must fail") } catch {
            XCTAssertTrue(error.localizedDescription.contains("send failed"))
        }
        var iterator = stream.makeAsyncIterator()
        do { _ = try await iterator.next(); XCTFail("Failure must reach the event consumer") } catch {
            XCTAssertTrue(error.localizedDescription.contains("send failed"))
        }
        let state = await client.state
        XCTAssertEqual(state, .failed)
    }

    func testClosureWhileFinishFrameIsSuspendedDoesNotLeaveFinishWaitingForever() async throws {
        let transport = FakeWebSocketTransport()
        let client = makeClient(transport: transport)
        let stream = try await client.start()
        let gate = AsyncGate()
        await transport.pauseBinary(on: gate)
        let finish = Task { try await client.finish() }
        await gate.waitUntilEntered()
        await transport.close(code: .goingAway)
        var iterator = stream.makeAsyncIterator()
        do { _ = try await iterator.next(); XCTFail("Close must terminate the stream") } catch {}
        await gate.release()
        do { try await finish.value; XCTFail("Finish must fail after closure") } catch {}
        let state = await client.state
        XCTAssertEqual(state, .failed)
    }

    func testLateFinishedResponseCannotOverwriteCancelledState() async throws {
        let transport = FakeWebSocketTransport()
        let client = makeClient(transport: transport)
        let stream = try await client.start()
        let receiver = await client.receiveTask
        let gate = AsyncGate()
        await transport.pauseReceive(on: gate)
        await transport.enqueue(.text("{\"tokens\":[],\"finished\":true}"))
        await gate.waitUntilEntered()
        await client.cancel()
        await gate.release()
        await receiver?.value
        let state = await client.state
        XCTAssertEqual(state, .cancelled)
        var iterator = stream.makeAsyncIterator()
        do { _ = try await iterator.next(); XCTFail("Cancelled stream must throw") } catch {
            XCTAssertEqual(error as? SonioxRealtimeClientError, .cancelled)
        }
    }

    private func makeClient(
        transport: FakeWebSocketTransport
    ) -> SonioxRealtimeClient {
        SonioxRealtimeClient(
            configuration: SonioxRealtimeConfiguration(apiKey: "test-api-key"),
            transport: transport
        )
    }

    private func transcriptUpdate(
        from event: SonioxRealtimeEvent?
    ) throws -> SonioxTranscriptUpdate {
        guard case .transcript(let update) = event else {
            throw TestFailure.expectedTranscript
        }
        return update
    }

    private func fixture(named name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("\(name).json")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func fixtureLines(named name: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("\(name).jsonl")
        return try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private enum TestFailure: Error {
        case expectedTranscript
    }
}
