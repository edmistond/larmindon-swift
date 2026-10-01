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
                rootContent(geometry: geometry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(rootBackground)
            }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
            #if os(iOS)
            .sheet(isPresented: $showSettings) {
                settingsSheet
            }
            .sheet(isPresented: $showMicrophonePanel) {
                microphonePanelSheet
            }
            #endif
            .preferredColorScheme(preferredColorScheme)
            .tint(accent)
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
            modePicker
        }
        #else
        ToolbarItem(placement: .navigation) {
            modePicker
        }

        ToolbarItem(placement: .principal) {
            HStack(spacing: 14) {
                inputPicker

                CaptureStatusLabel(
                    session: session,
                    isSelectedModeConfigured: isSelectedModeConfigured,
                    accent: accent
                )
                .fixedSize()
            }
        }

        // Session controls: Clear always sits next to Start/Stop, never in a menu.
        ToolbarItemGroup(placement: .primaryAction) {
            ToolbarStartStopButton(
                session: session,
                accent: accent,
                isEnabled: canToggleCaptions,
                action: toggleCaptions
            )

            ToolbarClearButton(session: session)
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)
        #endif

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

    /// On-device or server, as icons: the status label names the provider in words, and
    /// the space saved in the toolbar is held for a future AI control.
    private var modePicker: some View {
        Picker("Transcription mode", selection: $transcriptionModeRaw) {
            ForEach(TranscriptionMode.allCases) { mode in
                Image(systemName: mode.symbolName)
                    .accessibilityLabel(mode.title)
                    .tag(mode.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .accessibilityLabel("Transcription mode")
        #if os(macOS)
        .help("Transcribe on this Mac or with Soniox")
        #endif
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
    private func rootContent(geometry: GeometryProxy) -> some View {
        #if os(iOS)
        let bottomInset = geometry.safeAreaInsets.bottom
        let layout = CaptureBandLayout.resolved(for: geometry.size, bottomSafeAreaInset: bottomInset)
        // The band runs to the physical screen edge so the corner controls sit in the real
        // corners; it pads its own content back above the home indicator.
        VStack(spacing: 0) {
            captions

            captureBand(layout: layout, bottomInset: bottomInset)
                .ignoresSafeArea(edges: .horizontal)
        }
        .ignoresSafeArea(edges: .bottom)
        #else
        // macOS keeps every control in the window toolbar; captions get the whole window.
        captions
        #endif
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
            .overlay(alignment: .bottom) {
                ClearUndoToast(session: session, accent: accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    #if os(iOS)
    /// Start/Stop and Clear in the bottom corners, with the status label and the named
    /// input between them.
    private func captureBand(layout: CaptureBandLayout, bottomInset: CGFloat) -> some View {
        let metrics = layout.corner
        let statusLabel = CaptureStatusLabel(
            session: session,
            isSelectedModeConfigured: isSelectedModeConfigured,
            accent: accent
        )

        return Group {
            switch layout.arrangement {
            case .stacked:
                VStack(spacing: 8) {
                    statusLabel
                        .padding(.horizontal, layout.labelInset)

                    inputPicker
                        .padding(.horizontal, layout.chipInset)
                }
                .padding(.top, 12)
                .padding(.bottom, CaptureBandLayout.chipBottomPadding)
            case .row:
                HStack(spacing: 18) {
                    statusLabel

                    inputPicker
                }
                .padding(.horizontal, layout.rowInset)
                .padding(.vertical, CaptureBandLayout.chipBottomPadding)
            }
        }
        .frame(maxWidth: .infinity, minHeight: layout.minimumBandHeight)
        .padding(.bottom, bottomInset)
        .background { captureControlsBackground }
        .overlay {
            ZStack {
                CornerStartStopButton(
                    session: session,
                    metrics: metrics,
                    accent: accent,
                    isEnabled: canToggleCaptions,
                    action: toggleCaptions
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                CornerClearButton(session: session, metrics: metrics)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            // The display's rounded corner clips the tip of each disc.
        }
    }
    #endif

    private var canToggleCaptions: Bool {
        session.store.isRunning || isSelectedModeConfigured
    }

    private func toggleCaptions() {
        if session.store.isRunning {
            Task { await session.stop() }
        } else {
            startCaptionsIfIdle()
        }
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

    @ViewBuilder
    private var inputPicker: some View {
        #if os(iOS)
        SystemInputPickerButton(
            routeManager: session.routeManager,
            releaseAudioSessionWhenDismissed: !session.store.isRunning,
            showsCurrentInputName: true,
            onInputSelectionChanged: {
                session.inputSelectionDidChange()
            }
        )
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Input: \(session.routeManager.currentInputName)")
        #else
        InputSelectionMenu(
            routeManager: session.routeManager,
            showsCurrentInputName: true,
            onInputSelectionChanged: {
                session.inputSelectionDidChange()
            }
        )
        .fixedSize()
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

    private var accent: Color {
        activeTheme.palette.tint ?? .accentColor
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

extension TranscriptionMode {
    /// SF Symbol for the mode switch: this device for on-device, a cloud for server.
    var symbolName: String {
        switch self {
        case .onDevice:
            #if os(macOS)
            return "macbook.gen2"
            #else
            return "iphone.gen3"
            #endif
        case .server:
            return "cloud"
        }
    }
}

/// Where the iOS capture band puts things, from the space available.
struct CaptureBandLayout: Equatable {
    enum Arrangement: Equatable {
        /// Status label above the input chip, for portrait phones.
        case stacked
        /// Label and chip side by side, for landscape and wide screens.
        case row
    }

    /// Space below the chip, above the bottom safe-area inset.
    static let chipBottomPadding: CGFloat = 10
    /// Approximate input chip height, for keeping it clear of the corner controls.
    static let chipHeight: CGFloat = 36
    /// Approximate status label height plus the gap above the chip.
    static let labelBlockHeight: CGFloat = 28
    /// Breathing room between the corner rings and the band's center content.
    static let contentGap: CGFloat = 6

    let arrangement: Arrangement
    let corner: CornerControlMetrics
    let bottomSafeAreaInset: CGFloat
    /// Keeps the band at least as tall as the corner controls, so they never reach up
    /// over the newest caption.
    let minimumBandHeight: CGFloat

    private var chipCenterHeight: CGFloat {
        bottomSafeAreaInset + Self.chipBottomPadding + Self.chipHeight / 2
    }

    /// Stacked: horizontal inset for the chip, clear of the rings at its height.
    var chipInset: CGFloat { (corner.reach(atHeight: chipCenterHeight) + Self.contentGap).rounded() }
    /// Stacked: the label sits higher, where the rings curve away, so it gets more room.
    var labelInset: CGFloat {
        let height = chipCenterHeight + Self.chipHeight / 2 + Self.labelBlockHeight / 2
        return (corner.reach(atHeight: height) + Self.contentGap).rounded()
    }
    /// Row: one inset for the label-and-chip row.
    var rowInset: CGFloat { chipInset }

    static func resolved(for size: CGSize, bottomSafeAreaInset: CGFloat) -> Self {
        let isCompactHeight = size.height < 500 && size.width > size.height
        // The circles' centers sit inside the screen and their radius reaches past both
        // edges, so each reads as a round button tucked into the corner.
        let corner =
            isCompactHeight
            ? CornerControlMetrics(radius: 48, center: CGPoint(x: 38, y: 34))
            : CornerControlMetrics(radius: 60, center: CGPoint(x: 42, y: 44))
        return CaptureBandLayout(
            arrangement: size.width >= 600 ? .row : .stacked,
            corner: corner,
            bottomSafeAreaInset: bottomSafeAreaInset,
            minimumBandHeight: max(0, corner.frameSize.height - bottomSafeAreaInset)
        )
    }
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
