import SwiftUI

public struct LarmindonRootView: View {
    @State private var session = CaptionSession()
    @State private var showDebugPanel = false
    @State private var showSettings = false

    @AppStorage("captionFontSize") private var captionFontSize: Double = {
        #if os(macOS)
        return 30
        #else
        return 34
        #endif
    }()
    @AppStorage("appearancePreference") private var appearancePreferenceRaw = AppearancePreference.system.rawValue
    @AppStorage("transcriptionSourceKind") private var sourceKindRaw = TranscriptionSourceKind.live.rawValue
    @AppStorage("vadSensitivity") private var vadSensitivityRaw = VADSensitivity.medium.rawValue
    @AppStorage(AudioCaptureBufferFrames.storageKey) private var audioBufferFrameCount = AudioCaptureBufferFrames.defaultValue
    @AppStorage("profanityFilterEnabled") private var profanityFilterEnabled = false
    @AppStorage("showDebugPanel") private var persistedShowDebugPanel = false

    public init() {}

    public var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let layout = CaptionRootLayout.resolved(for: geometry.size)

                rootContent(layout: layout, containerSize: geometry.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(rootBackground)
            }
            .navigationTitle("Larmindon")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }

                    Button {
                        showDebugPanel.toggle()
                    } label: {
                        Label("Debug", systemImage: "sidebar.trailing")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                settingsSheet
            }
            .sheet(isPresented: $showDebugPanel) {
                debugPanelSheet
            }
            .onAppear {
                showDebugPanel = persistedShowDebugPanel
            }
            .onChange(of: showDebugPanel) { _, newValue in
                persistedShowDebugPanel = newValue
            }
            .preferredColorScheme(appearancePreference.colorScheme)
            .tint(appearancePreference.tintColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rootContent(layout: CaptionRootLayout, containerSize: CGSize) -> some View {
        switch layout {
        case .standard:
            VStack(spacing: 0) {
                captions

                captureControls(placement: .bottom)
            }
        case .compactLandscape:
            HStack(spacing: 0) {
                captions

                Divider()

                captureControls(placement: .trailing)
                    .frame(width: CaptionRootLayout.trailingControlsWidth(for: containerSize))
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var captions: some View {
        CaptionDisplayView(
            lines: session.store.visibleCaptionLines(),
            fontSize: captionFontSize
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func captureControls(placement: CaptionControlsPlacement) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AudioLevelBar(
                level: session.audioLevels.rawInputLevel,
                isActive: session.audioLevels.speechDetected
            )

            routeControls(placement: placement)

            actionControls(placement: placement)
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom)
        .frame(
            maxWidth: .infinity,
            maxHeight: placement == .trailing ? .infinity : nil,
            alignment: .topLeading
        )
        .background(captureControlsBackground)
    }

    @ViewBuilder
    private func routeControls(placement: CaptionControlsPlacement) -> some View {
        switch placement {
        case .bottom:
            HStack(spacing: 12) {
                inputNameLabel(lineLimit: 1)

                Spacer(minLength: 12)

                inputPicker
            }
        case .trailing:
            VStack(alignment: .leading, spacing: 10) {
                inputNameLabel(lineLimit: 2)

                inputPicker
            }
        }
    }

    @ViewBuilder
    private func actionControls(placement: CaptionControlsPlacement) -> some View {
        switch placement {
        case .bottom:
            HStack(spacing: 12) {
                startStopButton

                clearButton
            }
        case .trailing:
            VStack(spacing: 10) {
                startStopButton

                clearButton
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func inputNameLabel(lineLimit: Int) -> some View {
        Label("Input: \(session.routeManager.currentInputName)", systemImage: "mic")
            .font(.subheadline)
            .lineLimit(lineLimit)
            .minimumScaleFactor(0.75)
    }

    private var startStopButton: some View {
        Button {
            if session.store.isRunning {
                Task { await session.stop() }
            } else {
                session.start(
                    kind: sourceKind,
                    vadSensitivity: vadSensitivity,
                    audioBufferFrameCount: audioBufferFrameCount,
                    profanityFilterEnabled: profanityFilterEnabled
                )
            }
        } label: {
            Label(session.store.isRunning ? "Stop Captions" : "Start Captions", systemImage: session.store.isRunning ? "stop.fill" : "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    private var clearButton: some View {
        Button {
            session.clear()
        } label: {
            Label("Clear", systemImage: "trash")
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var inputPicker: some View {
        #if os(iOS)
        HStack(spacing: 6) {
            SystemInputPickerButton(routeManager: session.routeManager)
                .fixedSize()

            InputSelectionMenu(
                routeManager: session.routeManager,
                labelTitle: "Input options",
                systemImage: "ellipsis.circle"
            )
            .labelStyle(.iconOnly)
        }
        #else
        InputSelectionMenu(routeManager: session.routeManager)
        #endif
    }

    @ViewBuilder
    private var debugPanelSheet: some View {
        #if os(iOS)
        DebugPanelView(session: session)
            .presentationDetents([.medium, .large])
        #else
        DebugPanelView(session: session)
            .frame(minWidth: 560, idealWidth: 640, minHeight: 620, idealHeight: 720)
        #endif
    }

    @ViewBuilder
    private var settingsSheet: some View {
        #if os(iOS)
        PreferencesView()
            .presentationDetents([.medium, .large])
        #else
        PreferencesView()
            .frame(minWidth: 520, idealWidth: 600, minHeight: 520, idealHeight: 620)
        #endif
    }

    private var appearancePreference: AppearancePreference {
        AppearancePreference(rawValue: appearancePreferenceRaw) ?? .system
    }

    private var sourceKind: TranscriptionSourceKind {
        TranscriptionSourceKind(rawValue: sourceKindRaw) ?? .fake
    }

    private var vadSensitivity: VADSensitivity {
        VADSensitivity(rawValue: vadSensitivityRaw) ?? .medium
    }

    private var rootBackground: Color {
        appearancePreference.customBackgroundColor ?? Color(platformBackgroundColor)
    }

    @ViewBuilder
    private var captureControlsBackground: some View {
        if let customControlBackgroundColor = appearancePreference.customControlBackgroundColor {
            customControlBackgroundColor
        } else {
            Rectangle().fill(.thinMaterial)
        }
    }
}

#if os(macOS)
private typealias PlatformColor = NSColor
#else
private typealias PlatformColor = UIColor
#endif

private var platformBackgroundColor: PlatformColor {
    #if os(macOS)
    return .windowBackgroundColor
    #else
    return .systemBackground
    #endif
}

enum CaptionRootLayout: Equatable {
    case standard
    case compactLandscape

    static func resolved(
        for size: CGSize,
        supportsCompactLandscape: Bool = platformSupportsCompactLandscape
    ) -> Self {
        if supportsCompactLandscape, size.width > size.height, size.height < 500 {
            return .compactLandscape
        }

        return .standard
    }

    static func trailingControlsWidth(for size: CGSize) -> CGFloat {
        min(300, max(240, size.width * 0.34))
    }

    private static var platformSupportsCompactLandscape: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }
}

private enum CaptionControlsPlacement {
    case bottom
    case trailing
}

#Preview {
    LarmindonRootView()
        .frame(minWidth: 480, minHeight: 600)
}
