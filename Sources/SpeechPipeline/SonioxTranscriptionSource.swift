import AVFAudio
import Foundation

/// How hard a live session tries to get back to Soniox after the connection drops.
///
/// Soniox streams can't be resumed, so recovery means a new stream. Capture keeps running
/// throughout: on iOS a backgrounded app can't start recording again, and it is suspended
/// as soon as it stops, so tearing capture down to "restart" would end captions for good
/// the moment the phone left Wi-Fi in a pocket.
struct SonioxReconnectPolicy: Sendable {
    /// Continuous outage after which captions stop and the user is told. A drive through a
    /// dead zone is usually shorter; beyond this the mic is burning battery for nothing.
    var maxOutage: Duration = .seconds(600)
    /// URLSession's default of 60 seconds is far too long for a connect that's hanging
    /// on a network with bars but no data.
    var connectTimeout: Duration = .seconds(10)
    /// Soniox answers roughly once a second while it receives audio, speech or not. A
    /// socket that has gone this long without a message is dead even if it hasn't said so,
    /// which is what an interface change can leave behind.
    var stallTimeout: Duration = .seconds(20)

    /// The first attempt happens as soon as the path is usable. After that, exponential
    /// backoff capped at 30 s — well under Soniox's 100-requests-per-minute limit.
    func backoff(beforeAttempt attempt: Int) -> Duration {
        guard attempt > 1 else { return .zero }
        return .seconds(min(30, 1 << min(attempt - 2, 5)))
    }
}

@MainActor
public final class SonioxTranscriptionSource: BackgroundFinishingTranscriptionSource {
    public let name = "Soniox"
    public let results: AsyncStream<CaptionResult>
    public let levelUpdates: AsyncStream<AudioLevelSnapshot>

    static let connectionLostMessage =
        "Lost the connection to Soniox. Reconnecting when the network is available…"
    static let reconnectGaveUpMessage =
        "Couldn’t reconnect to Soniox after 10 minutes. Captions stopped."

    private let delivery = BoundedCaptionResults()
    private var didEndDelivery = false
    private let diagnostics: DiagnosticRecorder
    private let configuration: SonioxRealtimeConfiguration
    private let makeTransport: @Sendable () -> any WebSocketTransport
    private let makePathObserver: @MainActor () -> any NetworkPathObserving
    /// The client for the current connection. Nil while reconnecting: audio arriving then
    /// is dropped, since Soniox requires near-real-time cadence and a replayed backlog
    /// would be a burst it may disconnect for.
    private var client: SonioxRealtimeClient?
    /// Identifies the current connection, so failures reported late by a connection that
    /// has already been replaced are ignored.
    private var connectionID = 0
    private var messagesOnConnection = 0
    private let converter = SonioxPCMConverter()
    private var audioTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var bytesSent = 0
    /// Measured from the captured frames rather than the bytes they encode to, so it stays
    /// true for any wire encoding.
    private var audioDroppedWhileDisconnected: Duration = .zero
    private var sentenceAccumulator = SonioxSentenceAccumulator()
    /// Set while tearing down, so the cancellation we asked for is not reported as a
    /// provider failure. A cancellation arriving outside a stop is a real fault.
    private var isStopping = false
    private var stopTask: Task<Void, Never>?
    /// Set when the shutdown watchdog gave up on the graceful path, so the cancellation it
    /// causes is not reported to the user as a provider failure.
    private var didForceShutdown = false
    /// When the stop began, so `soniox_finished` can report how long the server took to
    /// flush. That is the evidence for whether `gracefulShutdownTimeout` has headroom.
    private var stopStartedAt: ContinuousClock.Instant?
    var delay = AsyncDelay.continuous
    var reconnectPolicy = SonioxReconnectPolicy()
    private let gracefulShutdownTimeout: Duration

    /// Each connection gets a fresh transport from `makeTransport`. Reusing one across
    /// connections would let a retired client's late `close()` shut down its successor.
    init(
        apiKey: String,
        diagnostics: DiagnosticRecorder = .shared,
        makeTransport: @escaping @Sendable () -> any WebSocketTransport,
        makePathObserver: @escaping @MainActor () -> any NetworkPathObserving = { NetworkPathMonitor() },
        gracefulShutdownTimeout: Duration = .seconds(5)
    ) {
        self.diagnostics = diagnostics
        self.gracefulShutdownTimeout = gracefulShutdownTimeout
        self.configuration = SonioxRealtimeConfiguration(
            apiKey: apiKey,
            languageHints: ["en"],
            speakerDiarizationEnabled: true,
            endpointDetectionEnabled: false
        )
        self.makeTransport = makeTransport
        self.makePathObserver = makePathObserver

        results = delivery.stream
        levelUpdates = AsyncStream { $0.finish() }
    }

    /// A single injected transport serves only the first connection; tests that exercise
    /// reconnection use the transport-factory initializer.
    public convenience init(
        apiKey: String,
        diagnostics: DiagnosticRecorder = .shared,
        transport: (any WebSocketTransport)? = nil,
        gracefulShutdownTimeout: Duration = .seconds(5)
    ) {
        let makeTransport: @Sendable () -> any WebSocketTransport
        if let transport {
            makeTransport = { transport }
        } else {
            makeTransport = {
                URLSessionWebSocketTransport(endpoint: SonioxRealtimeClient.endpoint)
            }
        }
        self.init(
            apiKey: apiKey,
            diagnostics: diagnostics,
            makeTransport: makeTransport,
            gracefulShutdownTimeout: gracefulShutdownTimeout
        )
    }

    public func start() async throws {
        throw TranscriptionSourceError.unavailable(
            "Soniox requires an AudioCaptureSession input stream."
        )
    }

    public func start(
        audioFrames: AsyncStream<CapturedAudioFrame>
    ) async throws {
        try await requireActiveStartup()
        sentenceAccumulator = SonioxSentenceAccumulator()
        let client = makeClient()
        self.client = client
        let events = try await client.start()
        await recordConnected(reconnectAttempt: nil)

        try await requireActiveStartup()
        beginConnection(client: client, events: events)
        audioTask = Task { await sendAudio(audioFrames) }
    }

    private func makeClient() -> SonioxRealtimeClient {
        SonioxRealtimeClient(configuration: configuration, transport: makeTransport())
    }

    private func recordConnected(reconnectAttempt: Int?) async {
        var fields = [
            "model": SonioxRealtimeConfiguration.defaultModel,
            "audio_format": "pcm_s16le",
            "sample_rate": "16000",
            "channels": "1",
            "speaker_diarization": "true",
            "endpoint_detection": "false",
        ]
        if let reconnectAttempt {
            fields["reconnect_attempt"] = String(reconnectAttempt)
        }
        await diagnostics.record(category: "provider", name: "soniox_connected", fields: fields)
    }

    private func beginConnection(
        client: SonioxRealtimeClient,
        events: AsyncThrowingStream<SonioxRealtimeEvent, any Error>
    ) {
        connectionID += 1
        let id = connectionID
        messagesOnConnection = 0
        eventTask = Task { await consumeEvents(events, connectionID: id) }
        pingTask = Task { await sendPings(client: client) }
        stallTask = Task { await watchForStall(connectionID: id) }
    }

    private func consumeEvents(
        _ events: AsyncThrowingStream<SonioxRealtimeEvent, any Error>,
        connectionID id: Int
    ) async {
        do {
            for try await event in events {
                // A retired connection can still deliver what it had buffered. Its
                // preview was already flushed, and the new stream starts fresh.
                guard id == connectionID else { continue }
                messagesOnConnection += 1
                switch event {
                case .transcript(let update):
                    let finalizedSegments =
                        sentenceAccumulator.consume(
                            finalizedTokens:
                                update.newlyFinalizedTokens
                        )
                    if !finalizedSegments.isEmpty {
                        publish(
                            .finalizedSegments(finalizedSegments)
                        )
                    }
                    publish(
                        .volatileSegments(
                            sentenceAccumulator.preview(
                                nonFinalTokens:
                                    update.nonFinalTokens
                            )
                        )
                    )
                    await diagnostics.record(
                        category: "transcript",
                        name: "soniox_update",
                        fields: [
                            "final_tokens":
                                String(update.newlyFinalizedTokens.count),
                            "volatile_tokens":
                                String(update.nonFinalTokens.count),
                            "final_audio_ms":
                                String(
                                    update.metrics
                                        .finalizedAudioMilliseconds
                                ),
                            "processing_lag_ms":
                                String(
                                    update.metrics
                                        .processingLagMilliseconds
                                ),
                            "speaker_ids":
                                Set(
                                    update.newlyFinalizedTokens
                                        .compactMap(\.speaker)
                                )
                                .sorted()
                                .joined(separator: ","),
                        ]
                    )
                case .finished(let completion):
                    let trailingSegments =
                        sentenceAccumulator.finish()
                    if !trailingSegments.isEmpty {
                        publish(
                            .finalizedSegments(trailingSegments)
                        )
                    }
                    await diagnostics.record(
                        category: "provider",
                        name: "soniox_finished",
                        fields: [
                            "final_audio_ms":
                                String(
                                    completion.metrics
                                        .finalizedAudioMilliseconds
                                ),
                            "bytes_sent": String(bytesSent),
                            "stop_to_finished_ms":
                                stopStartedAt.map {
                                    String($0.duration(to: .now).milliseconds)
                                } ?? "",
                        ]
                    )
                }
            }
            // Outside a stop, a stream that ends at all is a connection that ended.
            if !isStopping {
                await connectionLost(
                    SonioxRealtimeClientError.transport("The Soniox stream ended unexpectedly."),
                    connectionID: id
                )
            }
        } catch {
            guard !isStopping else {
                await diagnostics.record(
                    category: "provider",
                    name: "soniox_cancelled",
                    fields: ["message": error.localizedDescription]
                )
                return
            }
            await connectionLost(error, connectionID: id)
        }
    }

    /// Runs for the life of the source, across reconnects. The client's event stream is
    /// the authoritative failure channel — a failed send also fails that stream — so a
    /// send error here only means the frame is dropped.
    private func sendAudio(_ audioFrames: AsyncStream<CapturedAudioFrame>) async {
        for await frame in audioFrames {
            guard !Task.isCancelled else { break }
            guard let data = converter.convert(frame.buffer) else {
                await diagnostics.record(
                    category: "audio",
                    name: "soniox_conversion_failed",
                    fields: [
                        "input_rate":
                            String(frame.buffer.format.sampleRate),
                        "input_channels":
                            String(frame.buffer.format.channelCount),
                    ]
                )
                continue
            }
            guard let client, reconnectTask == nil else {
                audioDroppedWhileDisconnected += frame.duration
                continue
            }
            do {
                try await client.sendAudio(data)
                bytesSent += data.count
                if bytesSent.isMultiple(of: 320_000) {
                    await diagnostics.record(
                        category: "network",
                        name: "soniox_audio_sent",
                        fields: ["bytes": String(bytesSent)]
                    )
                }
            } catch {
                guard !isStopping else { return }
                audioDroppedWhileDisconnected += frame.duration
            }
        }
    }

    private func sendPings(client: SonioxRealtimeClient) async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            do {
                try await delay.sleep(.seconds(15))
                guard !Task.isCancelled else { return }
                let started = clock.now
                try await client.sendPing()
                await diagnostics.record(
                    category: "network",
                    name: "websocket_ping",
                    fields: [
                        "latency_ms": String(started.duration(to: clock.now).milliseconds)
                    ]
                )
            } catch is CancellationError {
                return
            } catch {
                await diagnostics.record(
                    category: "network",
                    name: "websocket_ping_failed",
                    fields: [
                        "message": error.localizedDescription
                    ]
                )
                return
            }
        }
    }

    /// Catches the half-dead socket: after an interface change the old connection can go
    /// silent without URLSession reporting anything, leaving captions frozen while the
    /// session still claims to be listening.
    private func watchForStall(connectionID id: Int) async {
        var lastSeen = messagesOnConnection
        while !Task.isCancelled {
            do {
                try await delay.sleep(reconnectPolicy.stallTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled, !isStopping, id == connectionID else { return }
            if messagesOnConnection == lastSeen {
                let seconds = reconnectPolicy.stallTimeout.components.seconds
                await connectionLost(
                    SonioxRealtimeClientError.transport(
                        "Soniox sent nothing for \(seconds) seconds."
                    ),
                    connectionID: id
                )
                return
            }
            lastSeen = messagesOnConnection
        }
    }

    private func requireActiveStartup() async throws {
        guard !Task.isCancelled, !isStopping else {
            await client?.cancel()
            throw CancellationError()
        }
    }

    private func publish(_ result: CaptionResult) {
        guard !didEndDelivery else { return }
        guard delivery.yield(result) else {
            didEndDelivery = true
            // CaptionSession cancels its consumer before retiring the provider.
            // That must still allow the existing graceful finish to drain.
            guard delivery.didFail else { return }
            audioTask?.cancel()
            pingTask?.cancel()
            stallTask?.cancel()
            reconnectTask?.cancel()
            let client = client
            Task { await client?.cancel() }
            return
        }
    }

    private func reportFailure(_ error: any Error) async {
        publish(.failure(error.localizedDescription))
        await diagnostics.record(
            category: "provider",
            name: "soniox_error",
            fields: [
                "type": String(describing: type(of: error)),
                "message": error.localizedDescription,
            ]
        )
    }

    /// Whether a new stream might succeed where this one failed. Network loss and the
    /// provider's own "try again" errors (overload, the 300-minute stream cap) qualify;
    /// a rejected key or configuration will fail identically on every attempt.
    static func isRecoverable(_ error: any Error) -> Bool {
        switch error as? SonioxRealtimeClientError {
        case .transport:
            return true
        case .provider(let providerError):
            return providerError.retryDisposition == .newRequestMaySucceed
        default:
            return false
        }
    }

    // MARK: - Reconnection

    private func connectionLost(_ error: any Error, connectionID id: Int) async {
        // Checked and claimed before the first suspension: the event stream, the stall
        // watchdog, and a stream that ends can all report the same loss.
        guard !isStopping, !didEndDelivery, id == connectionID, reconnectTask == nil else {
            return
        }
        guard Self.isRecoverable(error) else {
            await reportFailure(error)
            return
        }

        let lostClient = client
        client = nil
        // Retire the connection now, so anything it still reports — buffered events, a
        // late error, its stall watchdog — is recognizably stale.
        connectionID += 1
        pingTask?.cancel()
        pingTask = nil
        stallTask?.cancel()
        stallTask = nil
        audioDroppedWhileDisconnected = .zero
        reconnectTask = Task { await reconnect() }

        // A new stream starts with no context, so words already final on this one would
        // otherwise sit in the preview forever. What was still volatile is lost.
        let flushed = sentenceAccumulator.finish()
        if !flushed.isEmpty {
            publish(.finalizedSegments(flushed))
        }
        publish(.volatileSegments([]))
        publish(.connectionInterrupted(Self.connectionLostMessage))

        await diagnostics.record(
            category: "provider",
            name: "soniox_connection_lost",
            fields: [
                "type": String(describing: type(of: error)),
                "message": error.localizedDescription,
                "bytes_sent": String(bytesSent),
            ]
        )
        await lostClient?.cancel()
    }

    private func reconnect() async {
        let path = makePathObserver()
        defer { path.cancel() }
        let deadline = Task { [weak self, delay, reconnectPolicy] in
            try? await delay.sleep(reconnectPolicy.maxOutage)
            guard !Task.isCancelled else { return }
            await self?.giveUpReconnecting()
        }
        defer { deadline.cancel() }

        var attempt = 0
        while !Task.isCancelled, !isStopping {
            do {
                try await path.waitForSatisfiedPath()
                attempt += 1
                try await waitForBackoff(reconnectPolicy.backoff(beforeAttempt: attempt), path: path)
                await diagnostics.record(
                    category: "provider",
                    name: "soniox_reconnect_attempt",
                    fields: ["attempt": String(attempt)]
                )
                try await connectReplacement(attempt: attempt)
                reconnectTask = nil
                publish(.connectionRestored)
                return
            } catch {
                guard !Task.isCancelled, !isStopping else { return }
                guard Self.isRecoverable(error) else {
                    await reportFailure(error)
                    return
                }
                await diagnostics.record(
                    category: "provider",
                    name: "soniox_reconnect_failed",
                    fields: [
                        "attempt": String(attempt),
                        "message": error.localizedDescription,
                    ]
                )
            }
        }
    }

    /// Backoff ends early when the network changes — joining Wi-Fi in the garage should
    /// reconnect now, not after the rest of a 30-second wait.
    private func waitForBackoff(_ duration: Duration, path: any NetworkPathObserving) async throws {
        guard duration > .zero else { return }
        try await withThrowingTaskGroup(of: Void.self) { [delay] group in
            group.addTask { try await delay.sleep(duration) }
            group.addTask { try await path.waitForPathChange() }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func connectReplacement(attempt: Int) async throws {
        let client = makeClient()
        self.client = client
        let timeout = Task { [delay, reconnectPolicy] in
            try? await delay.sleep(reconnectPolicy.connectTimeout)
            guard !Task.isCancelled else { return false }
            await client.cancel()
            return true
        }
        let events: AsyncThrowingStream<SonioxRealtimeEvent, any Error>
        do {
            events = try await client.start()
            timeout.cancel()
        } catch {
            timeout.cancel()
            if self.client === client { self.client = nil }
            if await timeout.value {
                throw SonioxRealtimeClientError.transport("Timed out connecting to Soniox.")
            }
            throw error
        }
        guard !Task.isCancelled, !isStopping else {
            await client.cancel()
            if self.client === client { self.client = nil }
            throw CancellationError()
        }

        sentenceAccumulator = SonioxSentenceAccumulator()
        beginConnection(client: client, events: events)
        await recordConnected(reconnectAttempt: attempt)
        await diagnostics.record(
            category: "provider",
            name: "soniox_reconnected",
            fields: [
                "attempt": String(attempt),
                "dropped_audio_ms": String(audioDroppedWhileDisconnected.milliseconds),
            ]
        )
    }

    private func giveUpReconnecting() async {
        guard let reconnectTask, !isStopping else { return }
        reconnectTask.cancel()
        await client?.cancel()
        client = nil
        await diagnostics.record(
            category: "provider",
            name: "soniox_reconnect_gave_up",
            fields: [
                "max_outage_seconds": String(reconnectPolicy.maxOutage.components.seconds)
            ]
        )
        publish(.failure(Self.reconnectGaveUpMessage))
    }

    // MARK: - Shutdown

    /// Shutting down cleanly means sending the empty text frame Soniox uses as end-of-stream
    /// and waiting for the server to flush its remaining tokens and close. That takes a
    /// couple of seconds, and a second stop arriving during it would find the client
    /// mid-finish and cancel the socket instead, throwing away those final tokens. So
    /// concurrent callers join the teardown already running rather than starting another.
    public func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }

        let task = Task { await performStop() }
        stopTask = task
        await task.value
    }

    private func performStop() async {
        isStopping = true
        stopStartedAt = .now
        pingTask?.cancel()
        pingTask = nil
        stallTask?.cancel()
        stallTask = nil
        // Mid-reconnect there is no stream worth finishing; abandon the attempt.
        reconnectTask?.cancel()

        let watchdog = startShutdownWatchdog()
        defer { watchdog.cancel() }

        if let audioTask {
            await audioTask.value
        }
        audioTask = nil
        if let reconnectTask {
            await reconnectTask.value
        }
        reconnectTask = nil

        if let client {
            let state = await client.state
            if state == .streaming {
                do {
                    try await client.finish()
                } catch {
                    // A watchdog cancellation is our own doing, not a provider fault, and
                    // surfacing it would put an error caption on screen every time a stop
                    // timed out.
                    if !didForceShutdown {
                        publish(.failure(error.localizedDescription))
                    }
                    await client.cancel()
                }
            } else if state != .finished {
                await client.cancel()
            }
        }

        if let eventTask {
            await eventTask.value
        }
        eventTask = nil
        delivery.finish()
    }

    /// Bounds the graceful shutdown.
    ///
    /// Nothing on the clean path is bounded on its own: `client.finish()` waits on the
    /// server's `finished` message, and `eventTask` ends only when the server closes the
    /// socket. A server that goes quiet would otherwise retain this retired provider
    /// indefinitely. CaptionSession lets this drain finish independently of a new capture.
    ///
    /// One watchdog covers every wait: cancelling the client closes the transport, which
    /// fails the pending finish and terminates the event stream. `audioTask` is cancelled
    /// directly because it waits on the capture frame stream, which the client knows nothing
    /// about.
    private func startShutdownWatchdog() -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            try? await delay.sleep(gracefulShutdownTimeout)
            guard !Task.isCancelled else { return }

            didForceShutdown = true
            await diagnostics.record(
                category: "provider",
                name: "soniox_finish_timeout",
                fields: [
                    "timeout_seconds":
                        String(gracefulShutdownTimeout.components.seconds),
                    "bytes_sent": String(bytesSent),
                ]
            )
            audioTask?.cancel()
            await client?.cancel()
        }
    }
}

extension CapturedAudioFrame {
    fileprivate var duration: Duration {
        let sampleRate = buffer.format.sampleRate
        guard sampleRate > 0 else { return .zero }
        return .seconds(Double(buffer.frameLength) / sampleRate)
    }
}

extension Duration {
    fileprivate var milliseconds: Int64 {
        components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
}

struct SonioxSentenceAccumulator {
    private var pendingText = ""
    private var pendingSpeakerID: String?

    mutating func consume(
        finalizedTokens: [SonioxToken]
    ) -> [CaptionSegment] {
        var completed: [CaptionSegment] = []

        for token in finalizedTokens {
            let speakerID =
                SonioxSpeakerSegmentFormatter.normalizedSpeaker(
                    token.speaker
                )
            if let speakerID, speakerID != pendingSpeakerID {
                appendPending(to: &completed)
                pendingSpeakerID = speakerID
            }

            for piece in Self.sentencePieces(in: token.text) {
                pendingText.append(piece.text)
                if piece.completesSentence {
                    appendPending(to: &completed)
                }
            }
        }

        return completed
    }

    func preview(
        nonFinalTokens: [SonioxToken]
    ) -> [CaptionSegment] {
        var segments: [CaptionSegment] = []
        let pending = pendingText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !pending.isEmpty {
            segments.append(
                CaptionSegment(
                    text: pending,
                    speakerID: pendingSpeakerID
                )
            )
        }

        for segment in SonioxSpeakerSegmentFormatter.segments(
            tokens: nonFinalTokens
        ) {
            Self.appendCoalescing(segment, to: &segments)
        }
        return segments
    }

    mutating func finish() -> [CaptionSegment] {
        var completed: [CaptionSegment] = []
        appendPending(to: &completed)
        return completed
    }

    private mutating func appendPending(
        to segments: inout [CaptionSegment]
    ) {
        let cleaned = pendingText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !cleaned.isEmpty {
            segments.append(
                CaptionSegment(
                    text: cleaned,
                    speakerID: pendingSpeakerID
                )
            )
        }
        pendingText = ""
        pendingSpeakerID = nil
    }

    private static func appendCoalescing(
        _ segment: CaptionSegment,
        to segments: inout [CaptionSegment]
    ) {
        guard let previous = segments.last,
            previous.speakerID == segment.speakerID
        else {
            segments.append(segment)
            return
        }

        segments[segments.count - 1] = CaptionSegment(
            text: joined(previous.text, segment.text),
            speakerID: segment.speakerID
        )
    }

    private static func joined(_ first: String, _ second: String) -> String {
        guard let firstCharacter = second.first else { return first }
        if first.last?.isWhitespace == true
            || firstCharacter.isWhitespace
            || ".,!?;:)]}”’".contains(firstCharacter)
        {
            return first + second
        }
        return first + " " + second
    }

    private static func sentencePieces(
        in text: String
    ) -> [(text: String, completesSentence: Bool)] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }

        let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]
        let closingCharacters: Set<Character> = [
            "\"", "'", "”", "’", ")", "]", "}",
        ]
        var pieces: [(text: String, completesSentence: Bool)] = []
        var pieceStart = 0
        var index = 0

        while index < characters.count {
            guard terminators.contains(characters[index]) else {
                index += 1
                continue
            }

            var boundaryEnd = index + 1
            while boundaryEnd < characters.count,
                closingCharacters.contains(characters[boundaryEnd])
            {
                boundaryEnd += 1
            }

            let hasSentenceBoundary =
                boundaryEnd == characters.count
                || characters[boundaryEnd].isWhitespace
            if hasSentenceBoundary {
                pieces.append(
                    (
                        text: String(characters[pieceStart..<boundaryEnd]),
                        completesSentence: true
                    )
                )
                pieceStart = boundaryEnd
                index = boundaryEnd
            } else {
                index += 1
            }
        }

        if pieceStart < characters.count {
            pieces.append(
                (
                    text: String(characters[pieceStart...]),
                    completesSentence: false
                )
            )
        }
        return pieces
    }
}

struct SonioxSpeakerSegmentFormatter {
    static func segments(tokens: [SonioxToken]) -> [CaptionSegment] {
        var segments: [CaptionSegment] = []
        var text = ""
        var currentSpeaker: String?

        for token in tokens {
            let speaker = normalizedSpeaker(token.speaker)
            if let speaker, speaker != currentSpeaker {
                appendSegment(
                    text: &text,
                    speakerID: currentSpeaker,
                    to: &segments
                )
                currentSpeaker = speaker
            }
            text.append(token.text)
        }

        appendSegment(
            text: &text,
            speakerID: currentSpeaker,
            to: &segments
        )
        return segments
    }

    private static func appendSegment(
        text: inout String,
        speakerID: String?,
        to segments: inout [CaptionSegment]
    ) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            segments.append(
                CaptionSegment(text: cleaned, speakerID: speakerID)
            )
        }
        text = ""
    }

    static func normalizedSpeaker(_ speaker: String?) -> String? {
        guard let speaker else { return nil }
        let normalized = speaker.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalized.isEmpty ? nil : normalized
    }
}

final class SonioxPCMConverter: @unchecked Sendable {
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        if inputFormat?.isEqual(buffer.format) != true {
            converter = AVAudioConverter(
                from: buffer.format,
                to: outputFormat
            )
            converter?.primeMethod = .none
            inputFormat = buffer.format
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            max(1, ceil(Double(buffer.frameLength) * ratio) + 16)
        )
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: capacity
            )
        else {
            return nil
        }

        let inputProvider = SonioxAudioConverterInputProvider(
            buffer: buffer
        )
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            inputProvider.nextBuffer(inputStatus: inputStatus)
        }
        guard status != .error,
            output.frameLength > 0,
            let samples = output.int16ChannelData?[0]
        else {
            return nil
        }
        return Data(
            bytes: samples,
            count: Int(output.frameLength) * MemoryLayout<Int16>.size
        )
    }
}

private final class SonioxAudioConverterInputProvider:
    @unchecked Sendable
{
    private let buffer: AVAudioPCMBuffer
    private var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(
        inputStatus:
            UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        guard !didProvideInput else {
            inputStatus.pointee = .noDataNow
            return nil
        }
        didProvideInput = true
        inputStatus.pointee = .haveData
        return buffer
    }
}
