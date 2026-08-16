import SwiftUI

#if os(macOS)
import AppKit
#endif

public struct DebugPanelView: View {
    @Bindable private var session: CaptionSession
    @AppStorage(AudioCaptureBufferFrames.storageKey) private var audioBufferFrameCount = AudioCaptureBufferFrames.defaultValue
    @AppStorage(VoiceProcessingPreference.storageKey)
    private var voiceProcessingEnabled = VoiceProcessingPreference.defaultValue
    @State private var includeTranscriptInExport = false
    @State private var diagnosticExportURL: URL?
    @State private var diagnosticExportError: String?
    @State private var isPreparingDiagnosticExport = false

    public init(session: CaptionSession) {
        self.session = session
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("State") {
                    row("Running", session.store.isRunning ? "Yes" : "No")
                    row("Source", session.selectedSourceKind.title)
                    row("Requested mode", session.requestedMode.title)
                    row("Active mode", session.activeMode?.title ?? "None")
                    row(
                        "Active provider",
                        session.activeMode == .onDevice
                            ? "Apple"
                            : session.activeServerProvider?.title ?? "None"
                    )
                    row("Speech", session.speechAnalyzerState)
                    row("VAD", session.audioLevels.vadState)
                    row(
                        "Voice processing requested",
                        session.requestedVoiceProcessingEnabled ? "Enabled" : "Disabled"
                    )
                    row(
                        "Voice processing active",
                        session.activeVoiceProcessingEnabled.map { $0 ? "Enabled" : "Disabled" }
                            ?? "Not capturing"
                    )
                    row("Last error", session.lastError ?? "None")
                }

                Section("Route") {
                    row("Current input", session.routeManager.currentInputName)
                    row("Preferred input", session.routeManager.preferredInputName ?? "None")
                    routeRows("Available inputs", session.routeManager.availableInputs)
                    routeRows("Route inputs", session.routeManager.currentRouteInputs)
                    routeRows("Route outputs", session.routeManager.currentRouteOutputs)
                }

                Section("Levels") {
                    row("Raw input", session.audioLevels.rawInputLevel.formatted(.number.precision(.fractionLength(2))))
                    row("VAD-gated display", session.audioLevels.processedInputLevel.formatted(.number.precision(.fractionLength(2))))
                    row("VAD active", session.audioLevels.speechDetected ? "Yes" : "No")
                    row("Configured buffer", "\(audioBufferFrameCount) frames")
                    row("Active buffer", session.activeAudioBufferFrameCount.map { "\($0) frames" } ?? "None")
                    row(
                        "Observed callback",
                        session.audioLevels.observedCallbackFrameLength.map { "\($0) frames" } ?? "None"
                    )
                    AudioLevelBar(
                        level: session.audioLevels.rawInputLevel,
                        isActive: session.audioLevels.speechDetected
                    )
                }

                Section("Transcript") {
                    row("Finalized chunks", "\(session.store.finalizedChunks.count)")
                    Text(session.lastVolatileResult.isEmpty ? "No volatile result" : session.lastVolatileResult)
                        .textSelection(.enabled)
                }

                Section("Actions") {
                    Button("Start fake transcription source") {
                        session.start(kind: .fake)
                    }

                    Button("Start live transcription source") {
                        session.start(
                            kind: .live,
                            mode: session.requestedMode,
                            audioBufferFrameCount: audioBufferFrameCount,
                            voiceProcessingEnabled: voiceProcessingEnabled
                        )
                    }

                    Button("Dump route info to console") {
                        session.dumpRouteInfoToConsole()
                    }

                    Button("Clear transcript", role: .destructive) {
                        session.clear()
                    }
                }

                Section("Diagnostics Export") {
                    Toggle(
                        "Include transcript text",
                        isOn: $includeTranscriptInExport
                    )
                    Text(
                        "API keys, authorization data, and raw audio are never included."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button(
                        isPreparingDiagnosticExport
                            ? "Preparing…"
                            : "Prepare Diagnostic Bundle"
                    ) {
                        prepareDiagnosticExport()
                    }
                    .disabled(isPreparingDiagnosticExport)

                    if let diagnosticExportURL {
                        #if os(iOS)
                        ShareLink(item: diagnosticExportURL) {
                            Label(
                                "Share Diagnostic Bundle",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                        #else
                        Button {
                            saveDiagnosticBundle(diagnosticExportURL)
                        } label: {
                            Label(
                                "Save Diagnostic Bundle…",
                                systemImage: "square.and.arrow.down"
                            )
                        }
                        #endif
                    }

                    if let diagnosticExportError {
                        Text(diagnosticExportError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Debug")
        }
        .onAppear {
            session.setVoiceProcessingPreference(voiceProcessingEnabled)
        }
        .onChange(of: voiceProcessingEnabled) { _, newValue in
            session.setVoiceProcessingPreference(newValue)
        }
    }

    private func prepareDiagnosticExport() {
        isPreparingDiagnosticExport = true
        diagnosticExportError = nil
        Task {
            do {
                let transcript = includeTranscriptInExport
                    ? session.store.fullTranscript
                    : nil
                diagnosticExportURL = try await session.diagnostics
                    .makeExportBundle(transcript: transcript)
                // Returns a zip now, not a folder — a directory doesn't survive AirDrop
                // through the share sheet the way a single file does.
            } catch {
                diagnosticExportError = error.localizedDescription
            }
            isPreparingDiagnosticExport = false
        }
    }

    #if os(macOS)
    private func saveDiagnosticBundle(_ sourceURL: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }
        do {
            try FileManager.default.copyItem(
                at: sourceURL,
                to: destination
            )
            diagnosticExportError = nil
        } catch {
            diagnosticExportError = error.localizedDescription
        }
    }
    #endif

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 16)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func routeRows(_ title: String, _ ports: [AudioRoutePort]) -> some View {
        if ports.isEmpty {
            row(title, "None")
        } else {
            ForEach(ports) { port in
                row(title, "\(port.name) (\(port.kind))")
            }
        }
    }
}

#Preview {
    DebugPanelView(session: CaptionSession())
        .frame(width: 640, height: 720)
}
