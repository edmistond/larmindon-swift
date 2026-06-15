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
    @AppStorage("showDebugPanel") private var persistedShowDebugPanel = false

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CaptionDisplayView(
                    lines: session.store.visibleCaptionLines(),
                    fontSize: captionFontSize
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                captureControls
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(platformBackgroundColor))
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
                PreferencesView()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showDebugPanel) {
                DebugPanelView(session: session)
                    .presentationDetents([.medium, .large])
            }
            .onAppear {
                showDebugPanel = persistedShowDebugPanel
            }
            .onChange(of: showDebugPanel) { _, newValue in
                persistedShowDebugPanel = newValue
            }
            .preferredColorScheme(appearancePreference.colorScheme)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            AudioLevelBar(
                level: session.audioLevels.rawInputLevel,
                isActive: session.audioLevels.speechDetected
            )

            HStack(spacing: 12) {
                Label("Input: \(session.routeManager.currentInputName)", systemImage: "mic")
                    .font(.subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 12)

                inputPicker
            }

            HStack(spacing: 12) {
                Button {
                    if session.store.isRunning {
                        Task { await session.stop() }
                    } else {
                        session.start(kind: sourceKind, vadSensitivity: vadSensitivity)
                    }
                } label: {
                    Label(session.store.isRunning ? "Stop Captions" : "Start Captions", systemImage: session.store.isRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    session.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom)
        .background(.thinMaterial)
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

    private var appearancePreference: AppearancePreference {
        AppearancePreference(rawValue: appearancePreferenceRaw) ?? .system
    }

    private var sourceKind: TranscriptionSourceKind {
        TranscriptionSourceKind(rawValue: sourceKindRaw) ?? .fake
    }

    private var vadSensitivity: VADSensitivity {
        VADSensitivity(rawValue: vadSensitivityRaw) ?? .medium
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
