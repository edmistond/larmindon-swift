import Foundation

public actor SonioxRealtimeClient {
    public static let endpoint = URL(
        string: "wss://stt-rt.soniox.com/transcribe-websocket"
    )!

    public enum State: String, Equatable, Sendable {
        case idle
        case connecting
        case streaming
        case finishing
        case finished
        case cancelled
        case failed
    }

    public private(set) var state: State = .idle

    private let configuration: SonioxRealtimeConfiguration
    private let transport: any WebSocketTransport
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var sentAudioBytes = 0
    private var eventContinuation: AsyncThrowingStream<SonioxRealtimeEvent, any Error>.Continuation?
    private(set) var receiveTask: Task<Void, Never>?
    private var terminalError: SonioxRealtimeClientError?
    private var finishContinuation: CheckedContinuation<Void, any Error>?

    public init(
        configuration: SonioxRealtimeConfiguration,
        transport: any WebSocketTransport
    ) {
        self.configuration = configuration
        self.transport = transport

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func start() async throws
        -> AsyncThrowingStream<SonioxRealtimeEvent, any Error>
    {
        guard state == .idle else {
            throw SonioxRealtimeClientError.invalidState(
                expected: State.idle.rawValue,
                actual: state.rawValue
            )
        }

        try configuration.validate()
        state = .connecting

        do {
            try await transport.connect()
            try requireConnecting()
            let configurationData = try encoder.encode(configuration)
            guard
                let configurationText = String(
                    data: configurationData,
                    encoding: .utf8
                )
            else {
                throw SonioxRealtimeClientError.invalidConfiguration(
                    "The configuration could not be encoded as UTF-8."
                )
            }
            try await transport.sendText(configurationText)
            try requireConnecting()
        } catch {
            if Task.isCancelled || state == .cancelled {
                await cancel()
                // A non-cooperative connect may have completed after cancellation.
                await transport.close(code: .goingAway)
                throw SonioxRealtimeClientError.cancelled
            }
            let failure = mapError(error)
            await fail(with: failure)
            throw failure
        }

        let (stream, continuation) = AsyncThrowingStream<
            SonioxRealtimeEvent,
            any Error
        >.makeStream()
        eventContinuation = continuation
        state = .streaming

        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task {
                await self?.cancel()
            }
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        return stream
    }

    private func requireConnecting() throws {
        try Task.checkCancellation()
        guard state == .connecting else { throw terminalError ?? .cancelled }
    }

    public func sendAudio(_ pcmData: Data) async throws {
        guard state == .streaming else {
            throw SonioxRealtimeClientError.invalidState(
                expected: State.streaming.rawValue,
                actual: state.rawValue
            )
        }
        guard !pcmData.isEmpty else {
            throw SonioxRealtimeClientError.emptyAudioFrame
        }

        do {
            try await transport.sendBinary(pcmData)
            sentAudioBytes += pcmData.count
        } catch {
            let clientError = mapError(error)
            await fail(with: clientError)
            throw clientError
        }
    }

    /// Sends Soniox's empty-frame completion signal and waits for `finished`.
    ///
    /// The event stream remains the only result channel, including any final tokens
    /// received while the server drains the remaining audio.
    public func finish() async throws {
        if state == .finished {
            return
        }
        guard state == .streaming else {
            throw SonioxRealtimeClientError.invalidState(
                expected: State.streaming.rawValue,
                actual: state.rawValue
            )
        }

        state = .finishing
        do {
            try await transport.sendBinary(Data())
        } catch {
            let clientError = mapError(error)
            await fail(with: clientError)
            throw clientError
        }

        if state == .finished {
            return
        }

        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard state == .finishing else { throw terminalError ?? .cancelled }
            try await withCheckedThrowingContinuation { continuation in
                finishContinuation = continuation
            }
        } onCancel: {
            Task {
                await self.cancel()
            }
        }
    }

    public func sendPing() async throws {
        guard state == .streaming || state == .finishing else {
            throw SonioxRealtimeClientError.invalidState(
                expected: "streaming or finishing",
                actual: state.rawValue
            )
        }
        do {
            try await transport.sendPing()
        } catch {
            let clientError = mapError(error)
            await fail(with: clientError)
            throw clientError
        }
    }

    public func cancel() async {
        guard state != .cancelled, state != .finished else { return }
        state = .cancelled
        terminalError = .cancelled
        receiveTask?.cancel()
        receiveTask = nil
        eventContinuation?.finish(
            throwing: SonioxRealtimeClientError.cancelled
        )
        eventContinuation = nil
        finishContinuation?.resume(
            throwing: SonioxRealtimeClientError.cancelled
        )
        finishContinuation = nil
        await transport.close(code: .goingAway)
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                let message = try await transport.receive()
                guard !Task.isCancelled, state == .streaming || state == .finishing else { return }
                guard case .text(let text) = message else {
                    throw SonioxRealtimeClientError.unexpectedBinaryMessage
                }

                let response = try decodeResponse(text)
                if let providerError = providerError(from: response) {
                    throw SonioxRealtimeClientError.provider(providerError)
                }

                let metrics = processingMetrics(for: response)
                if !response.tokens.isEmpty || !response.finished {
                    eventContinuation?.yield(
                        .transcript(
                            SonioxTranscriptUpdate(
                                newlyFinalizedTokens: response.tokens.filter(\.isFinal),
                                nonFinalTokens: response.tokens.filter { !$0.isFinal },
                                metrics: metrics
                            )
                        )
                    )
                }

                if response.finished {
                    eventContinuation?.yield(
                        .finished(SonioxStreamCompletion(metrics: metrics))
                    )
                    eventContinuation?.finish()
                    eventContinuation = nil
                    state = .finished
                    finishContinuation?.resume()
                    finishContinuation = nil
                    await transport.close(code: .normalClosure)
                    receiveTask = nil
                    return
                }
            }
        } catch is CancellationError {
            if state != .cancelled {
                await fail(with: .cancelled)
            }
        } catch {
            await fail(with: mapError(error))
        }
    }

    private func decodeResponse(_ text: String) throws -> SonioxWireResponse {
        guard let data = text.data(using: .utf8) else {
            throw SonioxRealtimeClientError.invalidResponse(
                "The response was not UTF-8 text."
            )
        }
        do {
            return try decoder.decode(SonioxWireResponse.self, from: data)
        } catch {
            throw SonioxRealtimeClientError.invalidResponse(
                error.localizedDescription
            )
        }
    }

    private func providerError(
        from response: SonioxWireResponse
    ) -> SonioxProviderError? {
        guard let type = response.errorType else { return nil }
        return SonioxProviderError(
            code: response.errorCode ?? 0,
            type: type,
            message: response.errorMessage ?? "Soniox reported an error.",
            moreInfo: response.moreInfo,
            requestID: response.requestID
        )
    }

    private func processingMetrics(
        for response: SonioxWireResponse
    ) -> SonioxProcessingMetrics {
        let bytesPerFrame = 2 * configuration.channelCount
        let sentAudioMilliseconds: Int
        if bytesPerFrame > 0 {
            let sentFrames = sentAudioBytes / bytesPerFrame
            sentAudioMilliseconds = sentFrames * 1_000 / configuration.sampleRate
        } else {
            sentAudioMilliseconds = 0
        }

        return SonioxProcessingMetrics(
            sentAudioMilliseconds: sentAudioMilliseconds,
            finalizedAudioMilliseconds: response.finalAudioProcessedMilliseconds,
            totalProcessedAudioMilliseconds: response.totalAudioProcessedMilliseconds
        )
    }

    private func fail(with error: SonioxRealtimeClientError) async {
        guard state != .failed, state != .finished, state != .cancelled else {
            return
        }
        state = .failed
        terminalError = error
        eventContinuation?.finish(throwing: error)
        eventContinuation = nil
        finishContinuation?.resume(throwing: error)
        finishContinuation = nil
        receiveTask?.cancel()
        receiveTask = nil
        await transport.close(code: .goingAway)
    }

    private func mapError(_ error: any Error) -> SonioxRealtimeClientError {
        if let clientError = error as? SonioxRealtimeClientError {
            return clientError
        }
        if error is CancellationError {
            return .cancelled
        }
        return .transport(error.localizedDescription)
    }
}
