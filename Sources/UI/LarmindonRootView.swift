import SwiftUI

public struct LarmindonRootView: View {
    @Bindable private var session: CaptionSession
    @Environment(\.colorScheme) private var systemColorScheme

    #if os(iOS)
    @State private var showMicrophonePanel = false
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var isReadyForLaunch = false
    @State private var pendingCaptionLaunch = false
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
    @AppStorage(ThemePreference.modeStorageKey)
    private var themeSelectionModeRaw = ThemePreference.defaultMode.rawValue
    @AppStorage(ThemePreference.fixedThemeStorageKey)
    private var fixedThemeRaw = ThemePreference.defaultFixedTheme.rawValue
    @AppStorage(ThemePreference.lightThemeStorageKey)
    private var lightThemeRaw = ThemePreference.defaultLightTheme.rawValue
    @AppStorage(ThemePreference.darkThemeStorageKey)
    private var darkThemeRaw = ThemePreference.defaultDarkTheme.rawValue
    @AppStorage(TranscriptionPreference.modeStorageKey)
    private var transcriptionModeRaw = TranscriptionMode.onDevice.rawValue
    @AppStorage("vadSensitivity") private var vadSensitivityRaw = VADSensitivity.medium.rawValue
    @AppStorage(AudioCaptureBufferFrames.storageKey) private var audioBufferFrameCount = AudioCaptureBufferFrames
        .defaultValue
    @AppStorage(VoiceProcessingPreference.storageKey)
    private var voiceProcessingEnabled = VoiceProcessingPreference.defaultValue
    @AppStorage("profanityFilterEnabled") private var profanityFilterEnabled = false
    @AppStorage(SonioxAudioEncoding.storageKey)
    private var sonioxAudioEncodingRaw = SonioxAudioEncoding.defaultValue.rawValue

    public init(session: CaptionSession) {
        ThemePreference.migrateLegacySettings()
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
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Transcription mode", selection: $transcriptionModeRaw) {
                        ForEach(TranscriptionMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Transcription mode")
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        presentSettings()
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }

                    Button {
                        presentMicrophonePanel()
                    } label: {
                        Label("Microphone", systemImage: "microphone.and.signal.meter")
                    }

                    TranscriptShareLink(session: session)
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showSettings) {
                settingsSheet
            }
            .sheet(isPresented: $showMicrophonePanel) {
                microphonePanelSheet
            }
            #endif
            .preferredColorScheme(preferredColorScheme)
            .tint(activeTheme.palette.tint ?? .accentColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if session.canStartIfIdle {
                session.setVoiceProcessingPreference(voiceProcessingEnabled)
                session.requestMode(transcriptionMode)
            }
            #if os(iOS)
            isReadyForLaunch = true
            consumeCaptionLaunch()
            #endif
        }
        #if os(iOS)
        .onOpenURL { url in
            guard CaptionLaunchLink.matches(url) else { return }
            pendingCaptionLaunch = true
            consumeCaptionLaunch()
        }
        .onChange(of: scenePhase) { _, _ in
            consumeCaptionLaunch()
        }
        #endif
        .onChange(of: voiceProcessingEnabled) { _, newValue in
            session.setVoiceProcessingPreference(newValue)
        }
        .onChange(of: transcriptionModeRaw) {
            session.requestMode(transcriptionMode)
        }
    }

    private func presentSettings() {
        #if os(iOS)
        showSettings = true
        #else
        openSettings()
        #endif
    }

    private func presentMicrophonePanel() {
        #if os(iOS)
        showMicrophonePanel = true
        #else
        openWindow(id: LarmindonWindowID.microphone)
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
        // An absent error occupies no space and does not alter the scroll view's safe
        // area. Keep the caption view at a stable identity when a banner comes and goes.
        VStack(spacing: 0) {
            if let error = session.lastError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings", action: presentSettings)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.regularMaterial)
            }

            CaptionDisplayView(
                finalizedChunks: session.store.finalizedChunks,
                volatileCaptions: session.store.volatileCaptions,
                fontSize: captionFontSize,
                textColor: activeTheme.palette.text,
                speakerColors: activeTheme.palette.speakerAccents
            )
        }
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

                Text(modeStatusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(modeStatusText)

            SessionAudioLevelBar(session: session)
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

    private func startCaptionsIfIdle() {
        session.startIfIdle(
            kind: .live,
            mode: transcriptionMode,
            vadSensitivity: vadSensitivity,
            audioBufferFrameCount: audioBufferFrameCount,
            voiceProcessingEnabled: voiceProcessingEnabled,
            profanityFilterEnabled: profanityFilterEnabled,
            sonioxAudioEncoding: SonioxAudioEncoding(rawValue: sonioxAudioEncodingRaw)
                ?? SonioxAudioEncoding.defaultValue
        )
    }

    #if os(iOS)
    private func consumeCaptionLaunch() {
        guard pendingCaptionLaunch, isReadyForLaunch, scenePhase == .active else { return }
        // Consume even when busy: stopping later must not replay an old widget tap.
        pendingCaptionLaunch = false
        showSettings = false
        showMicrophonePanel = false
        startCaptionsIfIdle()
    }
    #endif

    private var startStopButton: some View {
        Button {
            if session.store.isRunning {
                Task { await session.stop() }
            } else {
                startCaptionsIfIdle()
            }
        } label: {
            Label(
                session.store.isRunning ? "Stop Captions" : "Start Captions",
                systemImage: session.store.isRunning ? "stop.fill" : "play.fill"
            )
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity, minHeight: comfortableControlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .tint(session.store.isRunning ? .red : (activeTheme.palette.tint ?? .accentColor))
        .disabled(
            !session.store.isRunning && !isSelectedModeConfigured
        )
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
        .disabled(session.store.finalizedChunks.isEmpty && session.store.volatileCaptions.isEmpty)
    }

    @ViewBuilder
    private var inputPicker: some View {
        #if os(iOS)
        SystemInputPickerButton(
            routeManager: session.routeManager,
            releaseAudioSessionWhenDismissed: !session.store.isRunning,
            onInputSelectionChanged: {
                session.inputSelectionDidChange()
            }
        )
        .fixedSize()
        #else
        InputSelectionMenu(
            routeManager: session.routeManager,
            onInputSelectionChanged: {
                session.inputSelectionDidChange()
            }
        )
        #endif
    }

    #if os(iOS)
    private var microphonePanelSheet: some View {
        MicrophonePanelView(session: session)
            .presentationDetents([.medium, .large])
    }

    private var settingsSheet: some View {
        PreferencesView()
            .presentationDetents([.medium, .large])
    }
    #endif

    private var themeSelectionMode: ThemeSelectionMode {
        ThemeSelectionMode(rawValue: themeSelectionModeRaw) ?? ThemePreference.defaultMode
    }

    private var activeTheme: AppTheme {
        themeSelection.theme(for: systemColorScheme)
    }

    private var preferredColorScheme: ColorScheme? {
        themeSelection.preferredColorScheme
    }

    private var themeSelection: ThemeSelection {
        switch themeSelectionMode {
        case .fixed:
            return .fixed(
                AppTheme(rawValue: fixedThemeRaw) ?? ThemePreference.defaultFixedTheme
            )
        case .followSystem:
            return .followSystem(
                light: AppTheme(rawValue: lightThemeRaw) ?? ThemePreference.defaultLightTheme,
                dark: AppTheme(rawValue: darkThemeRaw) ?? ThemePreference.defaultDarkTheme
            )
        }
    }

    private var transcriptionMode: TranscriptionMode {
        TranscriptionMode(rawValue: transcriptionModeRaw) ?? .onDevice
    }

    private var modeStatusText: String {
        if session.store.isRunning {
            // Say so rather than claiming "Listening" through an interruption. No audio is
            // arriving, so a caption view that stops growing would otherwise read as a
            // quiet room rather than a session that needs attention.
            if session.isInterrupted {
                return "Interrupted · \(session.requestedMode.title)"
            }
            if let activeMode = session.activeMode {
                return "Listening · \(activeMode.title)"
            }
            return "Switching to \(session.requestedMode.title)…"
        }
        if session.speechAnalyzerState == "Error" {
            return "Stopped · \(session.requestedMode.title)"
        }
        if !isSelectedModeConfigured {
            return "Soniox key required"
        }
        return "Ready · \(session.requestedMode.title)"
    }

    private var isSelectedModeConfigured: Bool {
        transcriptionMode != .server
            || KeychainProviderCredentialStore()
                .hasCredential(for: .soniox)
    }

    private var vadSensitivity: VADSensitivity {
        VADSensitivity(rawValue: vadSensitivityRaw) ?? .medium
    }

    private var rootBackground: Color {
        activeTheme.palette.background ?? Color(platformBackgroundColor)
    }

    @ViewBuilder
    private var captureControlsBackground: some View {
        if let controlBackground = activeTheme.palette.controlBackground {
            controlBackground
                .overlay(alignment: .top) { Divider() }
        } else {
            Rectangle()
                .fill(.thinMaterial)
                .overlay(alignment: .top) { Divider() }
        }
    }
}

public enum LarmindonWindowID {
    public static let microphone = "microphone"
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

/// The share button as its own leaf so caption updates rebuild only this view. The
/// transcript text is rendered when the sheet asks for it, not here.
private struct TranscriptShareLink: View {
    let session: CaptionSession

    var body: some View {
        let export = TranscriptExport(store: session.store)
        ShareLink(
            item: export,
            preview: SharePreview(
                "Larmindon Transcript",
                // An explicit icon stops the sheet from thumbnailing the exported file for
                // its header, which would load the item before the sheet can appear.
                image: Image(systemName: "text.alignleft")
            )
        ) {
            Label("Share Transcript", systemImage: "square.and.arrow.up")
        }
        .disabled(export.isEmpty)
    }
}

/// The meter in its own view so level updates invalidate only this leaf.
///
/// Reading `session.audioLevels` directly in `LarmindonRootView` made the whole root body
/// — captions included — re-evaluate on every level write, which showed up as sustained
/// SwiftUI layout CPU while capturing.
private struct SessionAudioLevelBar: View {
    let session: CaptionSession

    var body: some View {
        AudioLevelBar(
            level: session.audioLevels.rawInputLevel,
            isActive: session.audioLevels.speechDetected
        )
    }
}
