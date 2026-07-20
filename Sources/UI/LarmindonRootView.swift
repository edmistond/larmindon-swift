import SwiftUI

public struct LarmindonRootView: View {
    @Bindable private var session: CaptionSession

    #if os(iOS)
    @State private var showDebugPanel = false
    @State private var showSettings = false
    #else
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    #endif

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

    #if os(iOS)
    @AppStorage("showDebugPanel") private var persistedShowDebugPanel = false
    #endif

    public init(session: CaptionSession) {
        self.session = session
    }

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
                        presentSettings()
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }

                    Button {
                        presentDebugPanel()
                    } label: {
                        Label("Debug", systemImage: "sidebar.trailing")
                    }
                }
            }
            #if os(iOS)
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
            #endif
            .preferredColorScheme(appearancePreference.colorScheme)
            .tint(appearancePreference.tintColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func presentSettings() {
        #if os(iOS)
        showSettings = true
        #else
        openSettings()
        #endif
    }

    private func presentDebugPanel() {
        #if os(iOS)
        showDebugPanel.toggle()
        #else
        openWindow(id: LarmindonWindowID.debug)
        #endif
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
        VStack(alignment: .leading, spacing: 10) {
            levelAndStatus

            routeControls(placement: placement)

            actionControls(placement: placement)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(
            maxWidth: .infinity,
            maxHeight: placement == .trailing ? .infinity : nil,
            alignment: .topLeading
        )
        .background(captureControlsBackground)
    }

    private var levelAndStatus: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.store.isRunning ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 8, height: 8)

                Text(session.store.isRunning ? "Listening" : "Ready")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(session.store.isRunning ? "Captioning is active" : "Captioning is ready")

            AudioLevelBar(
                level: session.audioLevels.rawInputLevel,
                isActive: session.audioLevels.speechDetected
            )
        }
        .animation(.easeInOut(duration: 0.2), value: session.store.isRunning)
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
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, minHeight: comfortableControlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .tint(session.store.isRunning ? .red : appearancePreference.tintColor)
    }

    private var clearButton: some View {
        Button {
            session.clear()
        } label: {
            Label("Clear", systemImage: "trash")
                .frame(minHeight: comfortableControlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .disabled(session.store.visibleCaptionLines().isEmpty)
    }

    @ViewBuilder
    private var inputPicker: some View {
        #if os(iOS)
        SystemInputPickerButton(routeManager: session.routeManager)
            .fixedSize()
        #else
        InputSelectionMenu(routeManager: session.routeManager)
        #endif
    }

    #if os(iOS)
    private var debugPanelSheet: some View {
        DebugPanelView(session: session)
            .presentationDetents([.medium, .large])
    }

    private var settingsSheet: some View {
        PreferencesView()
            .presentationDetents([.medium, .large])
    }
    #endif

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
                .overlay(alignment: .top) { Divider() }
        } else {
            Rectangle()
                .fill(.thinMaterial)
                .overlay(alignment: .top) { Divider() }
        }
    }
}

public enum LarmindonWindowID {
    public static let debug = "debug"
}

private let comfortableControlHeight: CGFloat = {
    #if os(iOS)
    return 46
    #else
    return 32
    #endif
}()

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
    LarmindonRootView(session: CaptionSession())
        .frame(minWidth: 480, minHeight: 600)
}
