import SwiftUI

public struct DebugPanelView: View {
    @Bindable private var session: CaptionSession

    public init(session: CaptionSession) {
        self.session = session
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("State") {
                    row("Running", session.store.isRunning ? "Yes" : "No")
                    row("Source", session.selectedSourceKind.title)
                    row("Speech", session.speechAnalyzerState)
                    row("VAD", session.audioLevels.vadState)
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
                    row("Processed", session.audioLevels.processedInputLevel.formatted(.number.precision(.fractionLength(2))))
                    row("VAD active", session.audioLevels.speechDetected ? "Yes" : "No")
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
                        session.start(kind: .live)
                    }

                    Button("Dump route info to console") {
                        session.dumpRouteInfoToConsole()
                    }

                    Button("Clear transcript", role: .destructive) {
                        session.clear()
                    }
                }
            }
            .navigationTitle("Debug")
        }
    }

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
