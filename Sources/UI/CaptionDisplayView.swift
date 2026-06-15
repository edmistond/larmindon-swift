import SwiftUI

public struct CaptionDisplayView: View {
    public let lines: [CaptionLine]
    public let fontSize: Double

    public init(lines: [CaptionLine], fontSize: Double) {
        self.lines = lines
        self.fontSize = fontSize
    }

    public var body: some View {
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
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }
}
