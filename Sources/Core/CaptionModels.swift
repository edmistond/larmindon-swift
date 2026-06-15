import Foundation

public struct TranscriptChunk: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let text: String

    public init(id: UUID = UUID(), createdAt: Date = Date(), text: String) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
    }
}

public struct VolatileCaption: Equatable, Sendable {
    public let text: String
    public let updatedAt: Date

    public init(text: String, updatedAt: Date = Date()) {
        self.text = text
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
        case .volatile:
            return "volatile-tail"
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
}
