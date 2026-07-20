import SwiftUI

public struct MicrophonePanelView: View {
    @Bindable private var monitor: MicrophoneCapabilityMonitor
    @Bindable private var routeManager: AudioRouteManager

    public init(
        monitor: MicrophoneCapabilityMonitor,
        routeManager: AudioRouteManager
    ) {
        self.monitor = monitor
        self.routeManager = routeManager
    }

    public var body: some View {
        NavigationStack {
            List {
                if let snapshot = monitor.snapshot {
                    summary(snapshot)

                    ForEach(snapshot.sections) { section in
                        Section(section.title) {
                            ForEach(section.items) { item in
                                capabilityRow(item)
                            }
                        }
                    }

                    Section("What This Means") {
                        Label(snapshot.guidance, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                } else if let lastError = monitor.lastError {
                    ContentUnavailableView(
                        "Microphone Unavailable",
                        systemImage: "microphone.slash",
                        description: Text(lastError)
                    )
                } else {
                    ProgressView("Reading microphone capabilities…")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Microphone")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        monitor.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .task {
            monitor.refresh()
        }
        .onChange(of: routeManager.currentInputName) {
            monitor.refresh()
        }
    }

    private func summary(_ snapshot: MicrophoneCapabilitySnapshot) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "microphone.and.signal.meter")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 42, height: 42)
                        .background(.tint.opacity(0.12), in: .rect(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.inputName)
                            .font(.headline)
                        Text(snapshot.inputKind)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let pattern = snapshot.selectedPattern {
                    MicrophonePatternDiagram(
                        pattern: pattern,
                        patternName: snapshot.selectedPatternName ?? pattern.title,
                        orientation: snapshot.orientation
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    Label(
                        "The active route does not report a selected polar pattern.",
                        systemImage: "waveform.badge.magnifyingglass"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func capabilityRow(_ item: MicrophoneCapabilityItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(item.label)
            Spacer(minLength: 16)
            Text(item.value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

private struct MicrophonePatternDiagram: View {
    let pattern: MicrophonePolarPattern
    let patternName: String
    let orientation: String?

    var body: some View {
        VStack(spacing: 8) {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.42

                var guides = Path()
                for scale in [0.33, 0.66, 1.0] {
                    guides.addEllipse(
                        in: CGRect(
                            x: center.x - radius * scale,
                            y: center.y - radius * scale,
                            width: radius * scale * 2,
                            height: radius * scale * 2
                        )
                    )
                }
                guides.move(to: CGPoint(x: center.x - radius, y: center.y))
                guides.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                guides.move(to: CGPoint(x: center.x, y: center.y - radius))
                guides.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                context.stroke(guides, with: .color(.secondary.opacity(0.22)), lineWidth: 1)

                for (index, rotation) in lobeRotations.enumerated() {
                    let path = responsePath(
                        center: center,
                        radius: radius,
                        rotation: rotation
                    )
                    let color = index == 0 ? Color.accentColor : Color.cyan
                    context.fill(path, with: .color(color.opacity(0.18)))
                    context.stroke(path, with: .color(color), lineWidth: 2.5)
                }
            }
            .frame(height: 180)
            .accessibilityHidden(true)

            VStack(spacing: 2) {
                Text(displayName)
                    .font(.subheadline.weight(.semibold))
                Text("Idealized response, not a measured sensitivity plot")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .padding(12)
        .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(displayName). Idealized microphone response.")
    }

    private var displayName: String {
        if let orientation, !orientation.isEmpty {
            return "\(patternName) · \(orientation)"
        }
        return patternName
    }

    private var lobeRotations: [Double] {
        pattern == .stereo ? [-Double.pi / 4, Double.pi / 4] : [0]
    }

    private func responsePath(center: CGPoint, radius: CGFloat, rotation: Double) -> Path {
        var path = Path()
        let samples = 180

        for index in 0...samples {
            let angle = (Double(index) / Double(samples)) * 2 * Double.pi
            let response = radialResponse(angle: angle)
            let plottedAngle = angle + rotation - Double.pi / 2
            let point = CGPoint(
                x: center.x + radius * response * cos(plottedAngle),
                y: center.y + radius * response * sin(plottedAngle)
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    private func radialResponse(angle: Double) -> CGFloat {
        switch pattern {
        case .omnidirectional:
            return 1
        case .cardioid, .stereo:
            return CGFloat(max(0, 0.5 + 0.5 * cos(angle)))
        case .subcardioid:
            return CGFloat(max(0, 0.7 + 0.3 * cos(angle)))
        case .unknown:
            return 0.8
        }
    }
}

#Preview {
    let routeManager = AudioRouteManager()
    MicrophonePanelView(
        monitor: MicrophoneCapabilityMonitor(routeManager: routeManager),
        routeManager: routeManager
    )
    .frame(width: 640, height: 760)
}
