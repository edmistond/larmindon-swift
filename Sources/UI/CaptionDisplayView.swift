import SwiftUI

public struct CaptionDisplayView: View {
    public let lines: [CaptionLine]
    public let fontSize: Double

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
    private var speakerBlockSpacing: CGFloat { CGFloat(fontSize * 0.8) }

    public init(lines: [CaptionLine], fontSize: Double) {
        self.lines = lines
        self.fontSize = fontSize
    }

    public var body: some View {
        GeometryReader { scrollContainer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if lines.isEmpty {
                            Text("Ready for captions")
                                .foregroundStyle(.secondary)
                                .font(.system(size: fontSize, weight: .regular, design: .default))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                                let position = blockPosition(at: index)

                                Text(AttributedString(line.text))
                                    .foregroundStyle(
                                        Color.primary.opacity(line.isVolatile ? Self.volatileTextOpacity : 1)
                                    )
                                    .font(.system(size: fontSize, weight: .regular, design: .default))
                                    .lineSpacing(textLineSpacing)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    // Inside the bar: consecutive utterances from one speaker
                                    // keep their breathing room while the bar runs unbroken
                                    // through the gap, so a speaker's turn reads as one block.
                                    .padding(.bottom, position.isBlockEnd ? 0 : utteranceSpacing)
                                    .overlay(alignment: .leading) {
                                        if let speakerID = line.speakerID {
                                            speakerBar(for: speakerID, position: position)
                                        }
                                    }
                                    // Outside the bar, so the bar actually breaks here.
                                    .padding(.bottom, position.isBlockEnd ? speakerBlockSpacing : 0)
                                    .id(line.id)
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
                        alignment: lines.isEmpty ? .center : .topLeading
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
        CaptionScrollSignature(
            lineCount: lines.count,
            lastLineID: lines.last?.id,
            lastLineText: lines.last?.text
        )
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

    private func blockPosition(at index: Int) -> BlockPosition {
        let speakerID = lines[index].speakerID
        return BlockPosition(
            isBlockStart: index == 0 || lines[index - 1].speakerID != speakerID,
            isBlockEnd: index == lines.count - 1 || lines[index + 1].speakerID != speakerID
        )
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
        .fill(SpeakerColor.color(for: speakerID, scheme: colorScheme))
        .frame(width: Self.speakerBarWidth)
        // Keeps the bar clear of the iPhone's display curvature, which was clipping it.
        .padding(.leading, Self.speakerBarInset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private enum SpeakerColor {
    static func color(for speakerID: String, scheme: ColorScheme) -> Color {
        let palette =
            scheme == .dark
            ? [
                Color(red: 0.35, green: 0.65, blue: 1.00),
                Color(red: 1.00, green: 0.58, blue: 0.24),
                Color(red: 0.35, green: 0.80, blue: 0.48),
                Color(red: 1.00, green: 0.42, blue: 0.70),
                Color(red: 0.70, green: 0.55, blue: 1.00),
                Color(red: 0.25, green: 0.80, blue: 0.82),
            ]
            : [
                Color(red: 0.08, green: 0.42, blue: 0.82),
                Color(red: 0.85, green: 0.36, blue: 0.04),
                Color(red: 0.08, green: 0.55, blue: 0.25),
                Color(red: 0.72, green: 0.15, blue: 0.48),
                Color(red: 0.42, green: 0.25, blue: 0.78),
                Color(red: 0.00, green: 0.50, blue: 0.52),
            ]

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
