import Foundation

public struct CaptionSegment: Equatable, Sendable {
    public let text: String
    public let speakerID: String?

    public init(text: String, speakerID: String? = nil) {
        self.text = text
        self.speakerID = speakerID
    }
}

public struct TranscriptChunk: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let text: String
    public let speakerID: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        text: String,
        speakerID: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.speakerID = speakerID
    }
}

public struct VolatileCaption: Equatable, Sendable {
    public let id: String
    public let text: String
    public let speakerID: String?
    public let updatedAt: Date

    public init(
        id: String = "volatile-tail",
        text: String,
        speakerID: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.speakerID = speakerID
        self.updatedAt = updatedAt
    }
}

public enum CaptionLine: Identifiable, Equatable, Sendable {
    case finalized(TranscriptChunk)
    case volatile(VolatileCaption)

    public var id: String {
        switch self {
        case .finalized(let chunk):
            return "final-\(chunk.id.uuidString)"
        case .volatile(let caption):
            return caption.id
        }
    }

    public var text: String {
        switch self {
        case .finalized(let chunk):
            return chunk.text
        case .volatile(let caption):
            return caption.text
        }
    }

    public var isVolatile: Bool {
        if case .volatile = self {
            return true
        }
        return false
    }

    public var speakerID: String? {
        switch self {
        case .finalized(let chunk):
            return chunk.speakerID
        case .volatile(let caption):
            return caption.speakerID
        }
    }
}
