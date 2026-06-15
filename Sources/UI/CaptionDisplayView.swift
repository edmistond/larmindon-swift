import SwiftUI

public struct CaptionDisplayView: View {
    public let lines: [CaptionLine]
    public let fontSize: Double

    @State private var isPinnedToBottom = true

    private let bottomSentinelID = "caption-bottom-sentinel"
    private let coordinateSpaceName = "caption-scroll-space"

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
                            .background(
                                GeometryReader { bottomGeometry in
                                    Color.clear.preference(
                                        key: CaptionBottomPreferenceKey.self,
                                        value: bottomGeometry.frame(in: .named(coordinateSpaceName)).maxY
                                    )
                                }
                            )
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: scrollContainer.size.height, alignment: .topLeading)
                }
                .coordinateSpace(name: coordinateSpaceName)
                .onPreferenceChange(CaptionBottomPreferenceKey.self) { bottomMaxY in
                    let distanceFromBottom = bottomMaxY - scrollContainer.size.height
                    isPinnedToBottom = distanceFromBottom <= 28
                }
                .onAppear {
                    scrollToBottom(proxy)
                }
                .onChange(of: scrollSignature) { _, _ in
                    guard isPinnedToBottom else { return }
                    scrollToBottom(proxy)
                }
                .onChange(of: fontSize) { _, _ in
                    guard isPinnedToBottom else { return }
                    scrollToBottom(proxy)
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

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(bottomSentinelID, anchor: .bottom)
            }
        }
    }
}

private struct CaptionBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
