import SwiftUI

public struct CaptionDisplayView: View {
    public let lines: [CaptionLine]
    public let fontSize: Double

    @State private var isPinnedToBottom = true

    private let bottomSentinelID = "caption-bottom-sentinel"
    private let bottomTolerance: CGFloat = 28

    public init(lines: [CaptionLine], fontSize: Double) {
        self.lines = lines
        self.fontSize = fontSize
    }

    public var body: some View {
        GeometryReader { scrollContainer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if lines.isEmpty {
                            Text("Ready for captions")
                                .foregroundStyle(.secondary)
                                .font(.system(size: fontSize, weight: .regular, design: .default))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(lines) { line in
                                Text(AttributedString(line.text))
                                    .foregroundStyle(line.isVolatile ? .secondary : .primary)
                                    .font(.system(size: fontSize, weight: .regular, design: .default))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomSentinelID)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: scrollContainer.size.height, alignment: .topLeading)
                }
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
                .task {
                    var lastScrolledSignature = ""

                    while !Task.isCancelled {
                        if isPinnedToBottom {
                            let currentSignature = scrollSignature
                            if currentSignature != lastScrolledSignature {
                                lastScrolledSignature = currentSignature
                                scrollToBottom(proxy, animated: false)
                            }
                        }

                        try? await Task.sleep(for: .milliseconds(80))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scrollSignature: String {
        lines
            .map { "\($0.id):\($0.text)" }
            .joined(separator: "\u{1f}")
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
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomSentinelID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomSentinelID, anchor: .bottom)
            }
        }
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
