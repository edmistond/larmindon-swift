import Foundation
import Observation

@MainActor
@Observable
public final class CaptionStore {
    public private(set) var finalizedChunks: [TranscriptChunk]
    public private(set) var volatileCaptions: [VolatileCaption]
    public var isRunning: Bool

    public init(
        finalizedChunks: [TranscriptChunk] = [],
        volatileTail: VolatileCaption? = nil,
        isRunning: Bool = false
    ) {
        self.finalizedChunks = finalizedChunks
        self.volatileCaptions = volatileTail.map { [$0] } ?? []
        self.isRunning = isRunning
    }

    public var volatileTail: VolatileCaption? {
        volatileCaptions.last
    }

    public func clear() {
        finalizedChunks.removeAll()
        volatileCaptions.removeAll()
    }

    public func replaceVolatile(_ text: String) {
        replaceVolatile([CaptionSegment(text: text)])
    }

    public func replaceVolatile(_ segments: [CaptionSegment]) {
        volatileCaptions = cleanedSegments(segments).enumerated().map {
            index,
            segment in
            VolatileCaption(
                id: "volatile-\(index)",
                text: segment.text,
                speakerID: segment.speakerID
            )
        }
    }

    public func appendFinalized(_ text: String) {
        appendFinalized([CaptionSegment(text: text)])
    }

    public func appendFinalized(_ segments: [CaptionSegment]) {
        let cleaned = cleanedSegments(segments)
        guard !cleaned.isEmpty else {
            volatileCaptions.removeAll()
            return
        }

        finalizedChunks.append(
            contentsOf: cleaned.map {
                TranscriptChunk(text: $0.text, speakerID: $0.speakerID)
            }
        )
        volatileCaptions.removeAll()
    }

    public var fullFinalizedTranscript: String {
        finalizedChunks.map(\.text).joined(separator: "\n")
    }

    public var fullTranscript: String {
        visibleCaptionLines().map(\.text).joined(separator: "\n")
    }

    public func visibleCaptionLines(recentLimit: Int? = nil) -> [CaptionLine] {
        let visibleFinalizedChunks: ArraySlice<TranscriptChunk>
        if let recentLimit {
            visibleFinalizedChunks = finalizedChunks.suffix(max(0, recentLimit))
        } else {
            visibleFinalizedChunks = finalizedChunks[...]
        }

        let finalized = visibleFinalizedChunks.map(CaptionLine.finalized)
        return finalized + volatileCaptions.map(CaptionLine.volatile)
    }

    private func cleanedSegments(
        _ segments: [CaptionSegment]
    ) -> [CaptionSegment] {
        segments.compactMap { segment in
            let cleaned = segment.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !cleaned.isEmpty else { return nil }
            return CaptionSegment(
                text: cleaned,
                speakerID: segment.speakerID
            )
        }
    }
}
