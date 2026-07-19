import Foundation
import Observation

@MainActor
@Observable
public final class CaptionStore {
    public private(set) var finalizedChunks: [TranscriptChunk]
    public private(set) var volatileTail: VolatileCaption?
    public var isRunning: Bool

    public init(
        finalizedChunks: [TranscriptChunk] = [],
        volatileTail: VolatileCaption? = nil,
        isRunning: Bool = false
    ) {
        self.finalizedChunks = finalizedChunks
        self.volatileTail = volatileTail
        self.isRunning = isRunning
    }

    public func clear() {
        finalizedChunks.removeAll()
        volatileTail = nil
    }

    public func replaceVolatile(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        volatileTail = cleaned.isEmpty ? nil : VolatileCaption(text: cleaned)
    }

    public func appendFinalized(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            volatileTail = nil
            return
        }

        finalizedChunks.append(TranscriptChunk(text: cleaned))
        volatileTail = nil
    }

    public var fullFinalizedTranscript: String {
        finalizedChunks.map(\.text).joined(separator: "\n")
    }

    public func visibleCaptionLines(recentLimit: Int? = nil) -> [CaptionLine] {
        let visibleFinalizedChunks: ArraySlice<TranscriptChunk>
        if let recentLimit {
            visibleFinalizedChunks = finalizedChunks.suffix(max(0, recentLimit))
        } else {
            visibleFinalizedChunks = finalizedChunks[...]
        }

        let finalized = visibleFinalizedChunks.map(CaptionLine.finalized)
        if let volatileTail {
            return finalized + [.volatile(volatileTail)]
        }
        return Array(finalized)
    }
}
