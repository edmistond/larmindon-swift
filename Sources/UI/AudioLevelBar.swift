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
                    .fill(levelGradient)
                    .frame(width: max(6, geometry.size.width * level))
            }
        }
        .frame(height: 10)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent, \(isActive ? "speech detected" : "no speech")")
    }

    private var levelGradient: LinearGradient {
        LinearGradient(
            colors: isActive ? [.green, .yellow, .orange] : [Color.secondary.opacity(0.55)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

#Preview {
    VStack(spacing: 24) {
        AudioLevelBar(level: 0.75, isActive: true)
        AudioLevelBar(level: 0.35, isActive: true)
        AudioLevelBar(level: 0.2, isActive: false)
    }
    .padding()
    .frame(width: 320)
}
