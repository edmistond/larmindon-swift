import SwiftUI

public struct CaptionDisplayView: View {
    /// Finalized lines and the volatile tail are kept apart so a volatile update, which
    /// arrives many times a second while someone is speaking, re-diffs only the tail.
    /// Full scrollback is a feature — sessions run for hours and the transcript is copied
    /// out afterward — so the finalized list is never trimmed, only left undisturbed.
    public let finalizedChunks: [TranscriptChunk]
    public let volatileCaptions: [VolatileCaption]
    public let fontSize: Double
    public let textColor: Color?
    public let speakerColors: [Color]?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPinnedToBottom = true

    private let bottomSentinelID = "caption-bottom-sentinel"
    private let bottomTolerance: CGFloat = 28

    // Volatile text stays nearly as bright as finalized text. It is the newest and most
    // urgent content on screen, so dimming it the way `.secondary` does made it the least
    // legible thing in the view — worst in bright sunlight, where reflections wash the dark
    // background toward gray and crush contrast further.
    private static let volatileTextOpacity: Double = 0.9

    private static let speakerBarWidth: CGFloat = 3
    private static let speakerBarInset: CGFloat = 6

    // Spacing is expressed as a multiple of the caption font size, which the user can set
    // anywhere from 20 to 72. Three tiers: tightest inside a wrapped utterance, wider
    // between utterances, widest at a speaker change — so turn-taking is visible as shape
    // before any text is read. On-device transcription reports no speaker, which collapses
    // every line into one block and leaves the first two tiers doing the work.
    private var textLineSpacing: CGFloat { CGFloat(fontSize * 0.16) }
    private var utteranceSpacing: CGFloat { CGFloat(fontSize * 0.5) }
    private var speakerBlockSpacing: CGFloat { CGFloat(fontSize * 0.6) }

    public init(
        finalizedChunks: [TranscriptChunk],
        volatileCaptions: [VolatileCaption],
        fontSize: Double,
        textColor: Color? = nil,
        speakerColors: [Color]? = nil
    ) {
        self.finalizedChunks = finalizedChunks
        self.volatileCaptions = volatileCaptions
        self.fontSize = fontSize
        self.textColor = textColor
        self.speakerColors = speakerColors
    }

    /// Convenience for previews and callers that already hold combined lines.
    public init(lines: [CaptionLine], fontSize: Double) {
        var finalized: [TranscriptChunk] = []
        var volatile: [VolatileCaption] = []
        for line in lines {
            switch line {
            case .finalized(let chunk): finalized.append(chunk)
            case .volatile(let caption): volatile.append(caption)
            }
        }
        self.init(
            finalizedChunks: finalized,
            volatileCaptions: volatile,
            fontSize: fontSize
        )
    }

    private var isEmpty: Bool {
        finalizedChunks.isEmpty && volatileCaptions.isEmpty
    }

    public var body: some View {
        GeometryReader { scrollContainer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if isEmpty {
                            Text("Ready for captions")
                                .foregroundStyle(secondaryTextColor)
                                .font(.system(size: fontSize, weight: .regular, design: .default))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            ForEach(Array(finalizedChunks.enumerated()), id: \.element.id) { index, chunk in
                                captionRow(
                                    text: chunk.text,
                                    speakerID: chunk.speakerID,
                                    isVolatile: false,
                                    position: finalizedBlockPosition(at: index)
                                )
                                .id(CaptionLine.finalized(chunk).id)
                            }

                            ForEach(Array(volatileCaptions.enumerated()), id: \.element.id) { index, caption in
                                captionRow(
                                    text: caption.text,
                                    speakerID: caption.speakerID,
                                    isVolatile: true,
                                    position: volatileBlockPosition(at: index)
                                )
                                .id(caption.id)
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomSentinelID)
                    }
                    .padding(.vertical, 24)
                    .padding(.horizontal, 8)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: scrollContainer.size.height,
                        alignment: isEmpty ? .center : .topLeading
                    )
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onScrollGeometryChange(for: CaptionScrollGeometry.self) { geometry in
                    CaptionScrollGeometry(
                        contentOffsetY: geometry.contentOffset.y,
                        visibleMaxY: geometry.visibleRect.maxY,
                        contentHeight: geometry.contentSize.height
                    )
                } action: { oldGeometry, newGeometry in
                    updateBottomStickiness(oldGeometry: oldGeometry, newGeometry: newGeometry)
                }
                .onAppear {
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(of: scrollSignature) { _, newSignature in
                    if newSignature.isEmpty {
                        isPinnedToBottom = true
                    }

                    if isPinnedToBottom {
                        scrollToBottom(proxy, animated: false)
                    }
                }
                .onChange(of: scrollContainer.size.height) {
                    if isPinnedToBottom {
                        scrollToBottom(proxy, animated: false)
                    }
                }
                .onChange(of: fontSize) {
                    if isPinnedToBottom {
                        scrollToBottom(proxy, animated: false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scrollSignature: CaptionScrollSignature {
        if let tail = volatileCaptions.last {
            return CaptionScrollSignature(
                lineCount: finalizedChunks.count + volatileCaptions.count,
                lastLineID: tail.id,
                lastLineText: tail.text
            )
        }
        return CaptionScrollSignature(
            lineCount: finalizedChunks.count,
            lastLineID: finalizedChunks.last.map { CaptionLine.finalized($0).id },
            lastLineText: finalizedChunks.last?.text
        )
    }

    private var secondaryTextColor: Color {
        textColor?.opacity(0.65) ?? Color.secondary
    }

    private func updateBottomStickiness(oldGeometry: CaptionScrollGeometry, newGeometry: CaptionScrollGeometry) {
        if newGeometry.distanceFromBottom <= bottomTolerance {
            if !isPinnedToBottom {
                isPinnedToBottom = true
            }
            return
        }

        let didScrollUp = newGeometry.contentOffsetY < oldGeometry.contentOffsetY - 1
        if didScrollUp, isPinnedToBottom {
            isPinnedToBottom = false
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        Task { @MainActor in
            await Task.yield()

            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomSentinelID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomSentinelID, anchor: .bottom)
            }
        }
    }

    /// Where a line sits within a run of consecutive lines from the same speaker.
    private struct BlockPosition {
        let isBlockStart: Bool
        let isBlockEnd: Bool
    }

    /// Block positions span the finalized/volatile seam: the volatile tail continues the
    /// last finalized speaker's block when the speaker matches, exactly as it did when the
    /// two were one list.
    private func finalizedBlockPosition(at index: Int) -> BlockPosition {
        let speakerID = finalizedChunks[index].speakerID

        let isBlockStart = index == 0 || finalizedChunks[index - 1].speakerID != speakerID

        let isBlockEnd: Bool
        if index + 1 < finalizedChunks.count {
            isBlockEnd = finalizedChunks[index + 1].speakerID != speakerID
        } else if let firstVolatile = volatileCaptions.first {
            isBlockEnd = firstVolatile.speakerID != speakerID
        } else {
            isBlockEnd = true
        }

        return BlockPosition(isBlockStart: isBlockStart, isBlockEnd: isBlockEnd)
    }

    private func volatileBlockPosition(at index: Int) -> BlockPosition {
        let speakerID = volatileCaptions[index].speakerID

        let isBlockStart: Bool
        if index > 0 {
            isBlockStart = volatileCaptions[index - 1].speakerID != speakerID
        } else if let lastFinalized = finalizedChunks.last {
            isBlockStart = lastFinalized.speakerID != speakerID
        } else {
            isBlockStart = true
        }

        let isBlockEnd = index == volatileCaptions.count - 1
            || volatileCaptions[index + 1].speakerID != speakerID

        return BlockPosition(isBlockStart: isBlockStart, isBlockEnd: isBlockEnd)
    }

    private func captionRow(
        text: String,
        speakerID: String?,
        isVolatile: Bool,
        position: BlockPosition
    ) -> some View {
        Text(AttributedString(text))
            .foregroundStyle(
                (textColor ?? Color.primary)
                    .opacity(isVolatile ? Self.volatileTextOpacity : 1)
            )
            .font(.system(size: fontSize, weight: .regular, design: .default))
            .lineSpacing(textLineSpacing)
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Inside the bar: consecutive utterances from one speaker keep their breathing
            // room while the bar runs unbroken through the gap, so a speaker's turn reads
            // as one block.
            .padding(.bottom, position.isBlockEnd ? 0 : utteranceSpacing)
            .overlay(alignment: .leading) {
                if let speakerID {
                    speakerBar(for: speakerID, position: position)
                }
            }
            // Outside the bar, so the bar actually breaks here.
            .padding(.bottom, position.isBlockEnd ? speakerBlockSpacing : 0)
    }

    private func speakerBar(for speakerID: String, position: BlockPosition) -> some View {
        // Square through the middle of a block so adjacent segments meet flush and read as
        // one unbroken rule; only the block's outer ends are rounded. A capsule on every
        // line would pinch at each junction and undo the merge.
        UnevenRoundedRectangle(
            topLeadingRadius: position.isBlockStart ? Self.speakerBarWidth / 2 : 0,
            bottomLeadingRadius: position.isBlockEnd ? Self.speakerBarWidth / 2 : 0,
            bottomTrailingRadius: position.isBlockEnd ? Self.speakerBarWidth / 2 : 0,
            topTrailingRadius: position.isBlockStart ? Self.speakerBarWidth / 2 : 0
        )
        .fill(
            SpeakerColor.color(
                for: speakerID,
                scheme: colorScheme,
                customPalette: speakerColors
            )
        )
        .frame(width: Self.speakerBarWidth)
        // Keeps the bar clear of the iPhone's display curvature, which was clipping it.
        .padding(.leading, Self.speakerBarInset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private enum SpeakerColor {
    static func color(
        for speakerID: String,
        scheme: ColorScheme,
        customPalette: [Color]? = nil
    ) -> Color {
        // Callers without a theme (previews, the convenience initializer) fall back to the
        // built-in theme for the current scheme, so every palette lives in `AppTheme`.
        let defaultPalette = (scheme == .dark ? AppTheme.dark : AppTheme.light)
            .palette.speakerAccents
        let palette = customPalette.flatMap { $0.isEmpty ? nil : $0 } ?? defaultPalette

        return palette[paletteIndex(for: speakerID, count: palette.count)]
    }

    private static func paletteIndex(
        for speakerID: String,
        count: Int
    ) -> Int {
        if let numericID = Int(speakerID), numericID > 0 {
            return (numericID - 1) % count
        }

        let stableHash = speakerID.unicodeScalars.reduce(0) {
            (($0 * 31) + Int($1.value)) % count
        }
        return stableHash
    }
}

private struct CaptionScrollSignature: Equatable {
    let lineCount: Int
    let lastLineID: String?
    let lastLineText: String?

    var isEmpty: Bool {
        lineCount == 0
    }
}

private struct CaptionScrollGeometry: Equatable {
    let contentOffsetY: CGFloat
    let visibleMaxY: CGFloat
    let contentHeight: CGFloat

    var distanceFromBottom: CGFloat {
        max(0, contentHeight - visibleMaxY)
    }
}

#Preview("Captions") {
    CaptionDisplayView(
        lines: [
            .finalized(
                TranscriptChunk(
                    text: "Welcome to the meeting, everyone.",
                    speakerID: "1"
                )
            ),
            // Same speaker as the line above: the bar should run unbroken across both.
            .finalized(
                TranscriptChunk(
                    text: "Today we're covering the quarterly results and the roadmap.",
                    speakerID: "1"
                )
            ),
            .finalized(
                TranscriptChunk(
                    text: "Before that, can we revisit last quarter's numbers?",
                    speakerID: "2"
                )
            ),
            .volatile(
                VolatileCaption(
                    text: "Sure — and then we'll move on to the open questions…",
                    speakerID: "1"
                )
            ),
        ],
        fontSize: 30
    )
    .frame(width: 520, height: 420)
}

#Preview("No speaker information") {
    CaptionDisplayView(
        lines: [
            .finalized(TranscriptChunk(text: "On-device transcription reports no speaker.")),
            .finalized(TranscriptChunk(text: "Every line collapses into a single block.")),
            .volatile(VolatileCaption(text: "So the utterance gap carries the rhythm…")),
        ],
        fontSize: 30
    )
    .frame(width: 520, height: 360)
}

#Preview("Empty") {
    CaptionDisplayView(lines: [], fontSize: 30)
        .frame(width: 520, height: 360)
}
