import SwiftUI

public struct AudioLevelBar: View {
    public let level: Double

    public init(level: Double) {
        self.level = min(1, max(0, level))
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))

                Capsule()
                    .fill(levelGradient)
                    .frame(width: max(6, geometry.size.width * level))
            }
        }
        .frame(height: 10)
        .accessibilityLabel("Processed input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private var levelGradient: LinearGradient {
        LinearGradient(
            colors: [.green, .yellow, .orange],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
