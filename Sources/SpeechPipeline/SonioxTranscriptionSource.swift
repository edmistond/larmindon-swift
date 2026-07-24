import AVFAudio
import Foundation

@MainActor
public final class SonioxTranscriptionSource: TranscriptionSource {
    public let name = "Soniox"
    public let results: AsyncStream<CaptionResult>
    public let levelUpdates: AsyncStream<AudioLevelSnapshot>

    private let continuation: AsyncStream<CaptionResult>.Continuation
    private let diagnostics: DiagnosticRecorder
    private let client: SonioxRealtimeClient
    private let converter = SonioxPCMConverter()
    private var audioTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var bytesSent = 0

    public init(
        apiKey: String,
        diagnostics: DiagnosticRecorder = .shared,
        transport: (any WebSocketTransport)? = nil
    ) {
        self.diagnostics = diagnostics
        let configuration = SonioxRealtimeConfiguration(
            apiKey: apiKey,
            speakerDiarizationEnabled: true,
            endpointDetectionEnabled: false
        )
        self.client = SonioxRealtimeClient(
            configuration: configuration,
            transport: transport
                ?? URLSessionWebSocketTransport(
                    endpoint: SonioxRealtimeClient.endpoint
                )
        )

        var capturedContinuation:
            AsyncStream<CaptionResult>.Continuation!
        results = AsyncStream(bufferingPolicy: .bufferingNewest(64)) {
            capturedContinuation = $0
        }
        continuation = capturedContinuation
        levelUpdates = AsyncStream { $0.finish() }
    }

    public func start() async throws {
        throw TranscriptionSourceError.unavailable(
            "Soniox requires an AudioCaptureSession input stream."
        )
    }

    public func start(
        audioFrames: AsyncStream<CapturedAudioFrame>
    ) async throws {
        let events = try await client.start()
        await diagnostics.record(
            category: "provider",
            name: "soniox_connected",
            fields: [
                "model": SonioxRealtimeConfiguration.defaultModel,
                "audio_format": "pcm_s16le",
                "sample_rate": "16000",
                "channels": "1",
                "speaker_diarization": "true",
                "endpoint_detection": "false",
            ]
        )

        eventTask = Task {
            do {
                for try await event in events {
                    switch event {
                    case .transcript(let update):
                        let finalizedSegments =
                            SonioxSpeakerSegmentFormatter.segments(
                                tokens: update.newlyFinalizedTokens
                            )
                        if !finalizedSegments.isEmpty {
                            continuation.yield(
                                .finalizedSegments(finalizedSegments)
                            )
                        }
                        continuation.yield(
                            .volatileSegments(
                                SonioxSpeakerSegmentFormatter.segments(
                                    tokens: update.nonFinalTokens
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
                            ]
                        )
                    }
                }
            } catch {
                continuation.yield(.failure(error.localizedDescription))
                await diagnostics.record(
                    category: "provider",
                    name: "soniox_error",
                    fields: [
                        "type": String(describing: type(of: error)),
                        "message": error.localizedDescription,
                    ]
                )
            }
        }

        audioTask = Task {
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
                    continuation.yield(
                        .failure(error.localizedDescription)
                    )
                    return
                }
            }
        }

        pingTask = Task {
            let clock = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    let started = clock.now
                    try await client.sendPing()
                    let duration = started.duration(to: clock.now)
                    let components = duration.components
                    let milliseconds =
                        components.seconds * 1_000
                        + components.attoseconds / 1_000_000_000_000_000
                    await diagnostics.record(
                        category: "network",
                        name: "websocket_ping",
                        fields: [
                            "latency_ms": String(milliseconds)
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
    }

    public func stop() async {
        pingTask?.cancel()
        pingTask = nil
        if let audioTask {
            await audioTask.value
        }
        audioTask = nil

        let state = await client.state
        if state == .streaming {
            do {
                try await client.finish()
            } catch {
                continuation.yield(.failure(error.localizedDescription))
                await client.cancel()
            }
        } else if state != .finished {
            await client.cancel()
        }

        if let eventTask {
            await eventTask.value
        }
        eventTask = nil
        continuation.finish()
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

    private static func normalizedSpeaker(_ speaker: String?) -> String? {
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
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
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
              let samples = output.int16ChannelData?[0] else {
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
