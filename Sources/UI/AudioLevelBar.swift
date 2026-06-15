import SwiftUI

public struct AudioLevelBar: View {
    public let level: Double
    public let isActive: Bool

    public init(level: Double, isActive: Bool = true) {
        self.level = min(1, max(0, level))
        self.isActive = isActive
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))

                Capsule()
                    .fill(levelStyle)
                    .frame(width: max(6, geometry.size.width * level))
            }
        }
        .frame(height: 10)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent, \(isActive ? "speech detected" : "no speech")")
    }

    private var levelStyle: AnyShapeStyle {
        if isActive {
            AnyShapeStyle(
                LinearGradient(
                    colors: [.green, .yellow, .orange],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        } else {
            AnyShapeStyle(.secondary.opacity(0.55))
        }
    }
}
