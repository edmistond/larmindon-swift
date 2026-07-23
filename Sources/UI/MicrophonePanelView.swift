import SwiftUI

public struct MicrophonePanelView: View {
    @Bindable private var session: CaptionSession
    @State private var draftConfiguration = MicrophoneCaptureConfiguration()
    @State private var hasEditedConfiguration = false

    public init(session: CaptionSession) {
        self.session = session
    }

    public var body: some View {
        NavigationStack {
            List {
                voiceProcessingStatus

                if let snapshot = session.microphoneCapabilities.snapshot {
                    summary(snapshot)

                    #if os(iOS)
                    configurationControls(snapshot)
                    #endif

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
                } else if let lastError = session.microphoneCapabilities.lastError {
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
                        session.microphoneCapabilities.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .task {
            await session.prepareMicrophoneControls()
            synchronizeDraft()
        }
        .onDisappear {
            session.releaseMicrophoneControls()
        }
        .onChange(of: session.routeManager.currentInputName) {
            session.microphoneCapabilities.refresh()
            #if os(iOS)
            draftConfiguration = MicrophoneCaptureConfiguration(
                inputPortID: session.routeManager.currentRouteInputs.first?.id
            )
            hasEditedConfiguration = true
            #endif
        }
        .onChange(of: session.microphoneConfiguration) {
            synchronizeDraft()
        }
    }

    private var voiceProcessingStatus: some View {
        Section("Voice Processing") {
            capabilityRow(
                MicrophoneCapabilityItem(
                    label: "Requested",
                    value: session.requestedVoiceProcessingEnabled ? "Enabled" : "Disabled"
                )
            )
            capabilityRow(
                MicrophoneCapabilityItem(
                    label: "Active",
                    value: session.activeVoiceProcessingEnabled.map { $0 ? "Enabled" : "Disabled" }
                        ?? "Not capturing"
                )
            )
            Text("Apple Voice Processing I/O runs before VAD and transcription. Changes take effect when capture restarts.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

                if let diagram = diagramConfiguration(snapshot) {
                    MicrophonePatternDiagram(
                        pattern: diagram.pattern,
                        patternName: diagram.name,
                        orientation: diagram.orientation
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

    #if os(iOS)
    private func configurationControls(_ snapshot: MicrophoneCapabilitySnapshot) -> some View {
        Section("Controls") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Input device")
                    Text(session.routeManager.currentInputName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SystemInputPickerButton(
                    routeManager: session.routeManager,
                    onInputSelectionChanged: {
                        session.inputSelectionDidChange()
                    }
                )
                    .fixedSize()
            }

            Picker("Microphone position", selection: dataSourceSelection) {
                Text("Automatic").tag(String?.none)
                ForEach(snapshot.dataSources) { source in
                    Text(source.displayName).tag(Optional(source.id))
                }
            }
            .disabled(snapshot.dataSources.isEmpty || session.isApplyingMicrophoneConfiguration)

            Picker("Pickup pattern", selection: patternSelection) {
                Text("Automatic").tag(String?.none)
                ForEach(selectedDataSource?.supportedPatterns ?? []) { pattern in
                    Text(pattern.name).tag(Optional(pattern.id))
                }
            }
            .disabled(selectedDataSource == nil || session.isApplyingMicrophoneConfiguration)

            if selectedPattern?.pattern == .stereo {
                Picker("Stereo orientation", selection: $draftConfiguration.stereoOrientation) {
                    ForEach(MicrophoneStereoOrientation.allCases) { orientation in
                        Text(orientation.title).tag(orientation)
                    }
                }
                .onChange(of: draftConfiguration.stereoOrientation) {
                    hasEditedConfiguration = true
                }
                .disabled(session.isApplyingMicrophoneConfiguration)
            }

            configurationStatus(snapshot)

            if let error = session.microphoneConfigurationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            Button {
                Task {
                    let applied = await session.applyMicrophoneConfiguration(draftConfiguration)
                    if applied {
                        synchronizeDraft()
                    }
                }
            } label: {
                if session.isApplyingMicrophoneConfiguration {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(session.store.isRunning ? "Apply and Restart Captions" : "Apply")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasEditedConfiguration || session.isApplyingMicrophoneConfiguration)
        }
    }

    private func configurationStatus(_ snapshot: MicrophoneCapabilitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            statusLine(
                "Requested",
                dataSourceName(id: snapshot.requestedDataSourceID, in: snapshot) ?? "Automatic",
                snapshot.requestedPatternName
            )
            statusLine(
                "Active",
                dataSourceName(id: snapshot.activeDataSourceID, in: snapshot) ?? "System selected",
                snapshot.selectedPatternName
            )
        }
        .font(.caption)
    }

    private func statusLine(_ label: String, _ source: String, _ pattern: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text([source, pattern].compactMap { $0 }.joined(separator: " · "))
                .multilineTextAlignment(.trailing)
        }
    }

    private var dataSourceSelection: Binding<String?> {
        Binding(
            get: { draftConfiguration.dataSourceID },
            set: { newValue in
                draftConfiguration.dataSourceID = newValue
                let supportedIDs = selectedDataSource?.supportedPatterns.map(\.id) ?? []
                if !supportedIDs.contains(draftConfiguration.polarPatternID ?? "") {
                    draftConfiguration.polarPatternID = nil
                }
                hasEditedConfiguration = true
            }
        )
    }

    private var patternSelection: Binding<String?> {
        Binding(
            get: { draftConfiguration.polarPatternID },
            set: { newValue in
                draftConfiguration.polarPatternID = newValue
                hasEditedConfiguration = true
            }
        )
    }

    private var selectedDataSource: MicrophoneDataSourceOption? {
        session.microphoneCapabilities.snapshot?.dataSources.first {
            $0.id == draftConfiguration.dataSourceID
        }
    }

    private var selectedPattern: MicrophonePolarPatternOption? {
        selectedDataSource?.supportedPatterns.first {
            $0.id == draftConfiguration.polarPatternID
        }
    }

    private func synchronizeDraft() {
        let currentInputID = session.routeManager.currentRouteInputs.first?.id
        if session.microphoneConfiguration.inputPortID == nil
            || session.microphoneConfiguration.inputPortID == currentInputID {
            draftConfiguration = session.microphoneConfiguration
        } else {
            draftConfiguration = MicrophoneCaptureConfiguration(inputPortID: currentInputID)
        }
        hasEditedConfiguration = false
    }

    private func dataSourceName(id: String?, in snapshot: MicrophoneCapabilitySnapshot) -> String? {
        snapshot.dataSources.first { $0.id == id }?.name
    }
    #else
    private func synchronizeDraft() {}
    #endif

    private func diagramConfiguration(
        _ snapshot: MicrophoneCapabilitySnapshot
    ) -> (pattern: MicrophonePolarPattern, name: String, orientation: String?)? {
        #if os(iOS)
        if hasEditedConfiguration, let selectedPattern {
            return (selectedPattern.pattern, selectedPattern.name, selectedDataSource?.orientation)
        }
        #endif
        guard let pattern = snapshot.selectedPattern else { return nil }
        return (pattern, snapshot.selectedPatternName ?? pattern.title, snapshot.orientation)
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
    MicrophonePanelView(session: CaptionSession())
    .frame(width: 640, height: 760)
}
