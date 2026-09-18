import Foundation

public struct SonioxRealtimeConfiguration: Encodable, Equatable, Sendable,
    CustomDebugStringConvertible
{
    public static let defaultModel = "stt-rt-v5"

    public let apiKey: String
    public var model: String
    public var audioFormat: SonioxAudioFormat
    public var sampleRate: Int
    public var channelCount: Int
    public var languageHints: [String]
    public var languageHintsStrict: Bool
    public var speakerDiarizationEnabled: Bool
    public var languageIdentificationEnabled: Bool
    public var endpointDetectionEnabled: Bool
    public var clientReferenceID: String?
    public var context: SonioxContext?

    public init(
        apiKey: String,
        model: String = Self.defaultModel,
        audioFormat: SonioxAudioFormat = .pcmS16LittleEndian,
        sampleRate: Int = 16_000,
        channelCount: Int = 1,
        languageHints: [String] = [],
        languageHintsStrict: Bool = false,
        speakerDiarizationEnabled: Bool = true,
        languageIdentificationEnabled: Bool = false,
        endpointDetectionEnabled: Bool = false,
        clientReferenceID: String? = nil,
        context: SonioxContext? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.audioFormat = audioFormat
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.languageHints = languageHints
        self.languageHintsStrict = languageHintsStrict
        self.speakerDiarizationEnabled = speakerDiarizationEnabled
        self.languageIdentificationEnabled = languageIdentificationEnabled
        self.endpointDetectionEnabled = endpointDetectionEnabled
        self.clientReferenceID = clientReferenceID
        self.context = context
    }

    public var debugDescription: String {
        "SonioxRealtimeConfiguration(apiKey: <redacted>, model: \(model), "
            + "audioFormat: \(audioFormat.rawValue), sampleRate: \(sampleRate), "
            + "channelCount: \(channelCount), speakerDiarizationEnabled: "
            + "\(speakerDiarizationEnabled))"
    }

    func validate() throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SonioxRealtimeClientError.invalidConfiguration(
                "An API key is required."
            )
        }
        guard !model.isEmpty else {
            throw SonioxRealtimeClientError.invalidConfiguration(
                "A realtime model is required."
            )
        }
        guard sampleRate > 0 else {
            throw SonioxRealtimeClientError.invalidConfiguration(
                "The sample rate must be greater than zero."
            )
        }
        guard channelCount > 0 else {
            throw SonioxRealtimeClientError.invalidConfiguration(
                "The channel count must be greater than zero."
            )
        }
        guard clientReferenceID.map({ $0.count <= 256 }) ?? true else {
            throw SonioxRealtimeClientError.invalidConfiguration(
                "The client reference ID cannot exceed 256 characters."
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case model
        case audioFormat = "audio_format"
        case sampleRate = "sample_rate"
        case channelCount = "num_channels"
        case languageHints = "language_hints"
        case languageHintsStrict = "language_hints_strict"
        case speakerDiarizationEnabled = "enable_speaker_diarization"
        case languageIdentificationEnabled = "enable_language_identification"
        case endpointDetectionEnabled = "enable_endpoint_detection"
        case clientReferenceID = "client_reference_id"
        case context
    }
}

public enum SonioxAudioFormat: String, Encodable, Equatable, Sendable {
    case pcmS16LittleEndian = "pcm_s16le"
}

public struct SonioxContext: Codable, Equatable, Sendable {
    public var general: [GeneralItem]
    public var text: String?
    public var terms: [String]

    public init(
        general: [GeneralItem] = [],
        text: String? = nil,
        terms: [String] = []
    ) {
        self.general = general
        self.text = text
        self.terms = terms
    }

    public struct GeneralItem: Codable, Equatable, Sendable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }
}

public struct SonioxToken: Decodable, Equatable, Sendable {
    public let text: String
    public let startMilliseconds: Int?
    public let endMilliseconds: Int?
    public let confidence: Double?
    public let isFinal: Bool
    public let speaker: String?
    public let translationStatus: String?
    public let language: String?
    public let sourceLanguage: String?

    private enum CodingKeys: String, CodingKey {
        case text
        case startMilliseconds = "start_ms"
        case endMilliseconds = "end_ms"
        case confidence
        case isFinal = "is_final"
        case speaker
        case translationStatus = "translation_status"
        case language
        case sourceLanguage = "source_language"
    }
}

public struct SonioxProcessingMetrics: Equatable, Sendable {
    public let sentAudioMilliseconds: Int
    public let finalizedAudioMilliseconds: Int
    public let totalProcessedAudioMilliseconds: Int

    public var finalizationLagMilliseconds: Int {
        max(0, sentAudioMilliseconds - finalizedAudioMilliseconds)
    }

    public var processingLagMilliseconds: Int {
        max(0, sentAudioMilliseconds - totalProcessedAudioMilliseconds)
    }

    public init(
        sentAudioMilliseconds: Int,
        finalizedAudioMilliseconds: Int,
        totalProcessedAudioMilliseconds: Int
    ) {
        self.sentAudioMilliseconds = sentAudioMilliseconds
        self.finalizedAudioMilliseconds = finalizedAudioMilliseconds
        self.totalProcessedAudioMilliseconds = totalProcessedAudioMilliseconds
    }
}

public struct SonioxTranscriptUpdate: Equatable, Sendable {
    /// Final tokens are emitted once by Soniox and should be appended to stable history.
    public let newlyFinalizedTokens: [SonioxToken]

    /// The complete provisional tail from this response replaces the previous tail.
    public let nonFinalTokens: [SonioxToken]

    public let metrics: SonioxProcessingMetrics

    public var newlyFinalizedText: String {
        newlyFinalizedTokens.map(\.text).joined()
    }

    public var nonFinalText: String {
        nonFinalTokens.map(\.text).joined()
    }

    public init(
        newlyFinalizedTokens: [SonioxToken],
        nonFinalTokens: [SonioxToken],
        metrics: SonioxProcessingMetrics
    ) {
        self.newlyFinalizedTokens = newlyFinalizedTokens
        self.nonFinalTokens = nonFinalTokens
        self.metrics = metrics
    }
}

public struct SonioxStreamCompletion: Equatable, Sendable {
    public let metrics: SonioxProcessingMetrics

    public init(metrics: SonioxProcessingMetrics) {
        self.metrics = metrics
    }
}

public enum SonioxRealtimeEvent: Equatable, Sendable {
    case transcript(SonioxTranscriptUpdate)
    case finished(SonioxStreamCompletion)
}

public enum SonioxRetryDisposition: Equatable, Sendable {
    case doNotRetry
    case newRequestMaySucceed
}

public struct SonioxProviderError: LocalizedError, Equatable, Sendable {
    public let code: Int
    public let type: String
    public let message: String
    public let moreInfo: URL?
    public let requestID: String?

    public var retryDisposition: SonioxRetryDisposition {
        switch type {
        case "request_timeout", "max_duration_reached", "limit_exceeded",
            "internal_error", "service_unavailable":
            return .newRequestMaySucceed
        default:
            return .doNotRetry
        }
    }

    public var errorDescription: String? {
        if let requestID {
            return "\(message) (Soniox request \(requestID))"
        }
        return message
    }

    public init(
        code: Int,
        type: String,
        message: String,
        moreInfo: URL?,
        requestID: String?
    ) {
        self.code = code
        self.type = type
        self.message = message
        self.moreInfo = moreInfo
        self.requestID = requestID
    }
}

public enum SonioxRealtimeClientError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidState(expected: String, actual: String)
    case emptyAudioFrame
    case unexpectedBinaryMessage
    case invalidResponse(String)
    case provider(SonioxProviderError)
    case transport(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid Soniox configuration: \(message)"
        case .invalidState(let expected, let actual):
            return "The Soniox client expected \(expected), but was \(actual)."
        case .emptyAudioFrame:
            return "An empty audio frame is reserved for graceful stream completion."
        case .unexpectedBinaryMessage:
            return "Soniox returned an unexpected binary message."
        case .invalidResponse(let message):
            return "Soniox returned an invalid response: \(message)"
        case .provider(let error):
            return error.localizedDescription
        case .transport(let message):
            return "The Soniox transport failed: \(message)"
        case .cancelled:
            return "The Soniox transcription session was cancelled."
        }
    }
}

struct SonioxWireResponse: Decodable {
    var tokens: [SonioxToken] = []
    var finalAudioProcessedMilliseconds: Int = 0
    var totalAudioProcessedMilliseconds: Int = 0
    var finished: Bool = false
    var errorCode: Int?
    var errorType: String?
    var errorMessage: String?
    var moreInfo: URL?
    var requestID: String?

    private enum CodingKeys: String, CodingKey {
        case tokens
        case finalAudioProcessedMilliseconds = "final_audio_proc_ms"
        case totalAudioProcessedMilliseconds = "total_audio_proc_ms"
        case finished
        case errorCode = "error_code"
        case errorType = "error_type"
        case errorMessage = "error_message"
        case moreInfo = "more_info"
        case requestID = "request_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokens =
            try container.decodeIfPresent(
                [SonioxToken].self,
                forKey: .tokens
            ) ?? []
        finalAudioProcessedMilliseconds =
            try container.decodeIfPresent(
                Int.self,
                forKey: .finalAudioProcessedMilliseconds
            ) ?? 0
        totalAudioProcessedMilliseconds =
            try container.decodeIfPresent(
                Int.self,
                forKey: .totalAudioProcessedMilliseconds
            ) ?? 0
        finished =
            try container.decodeIfPresent(
                Bool.self,
                forKey: .finished
            ) ?? false
        errorCode = try container.decodeIfPresent(Int.self, forKey: .errorCode)
        errorType = try container.decodeIfPresent(String.self, forKey: .errorType)
        errorMessage = try container.decodeIfPresent(
            String.self,
            forKey: .errorMessage
        )
        moreInfo = try container.decodeIfPresent(URL.self, forKey: .moreInfo)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
    }
}
