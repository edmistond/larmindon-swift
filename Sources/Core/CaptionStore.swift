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
        Self.transcript(for: finalizedChunks.map(CaptionLine.finalized))
    }

    public var fullTranscript: String {
        Self.transcript(for: visibleCaptionLines())
    }

    /// Renders lines as plain text for copying into an editor, marking each run of
    /// consecutive lines from one speaker with a `[Speaker N]` prefix and separating runs
    /// with a blank line. The marker is searchable, which is the point: the transcript gets
    /// pasted somewhere with better search than this app has.
    ///
    /// On-device transcription reports no speaker at all, so every line falls into a single
    /// unlabelled run and the output stays a plain newline-joined transcript.
    private static func transcript(for lines: [CaptionLine]) -> String {
        var blocks: [String] = []
        var blockLines: [String] = []
        var blockSpeakerID: String?
        var hasOpenBlock = false

        func closeBlock() {
            guard !blockLines.isEmpty else { return }
            let body = blockLines.joined(separator: "\n")
            if let blockSpeakerID {
                blocks.append("[Speaker \(blockSpeakerID)] \(body)")
            } else {
                blocks.append(body)
            }
            blockLines.removeAll()
        }

        for line in lines {
            if hasOpenBlock, line.speakerID != blockSpeakerID {
                closeBlock()
            }
            blockSpeakerID = line.speakerID
            hasOpenBlock = true
            blockLines.append(line.text)
        }
        closeBlock()

        return blocks.joined(separator: "\n\n")
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
