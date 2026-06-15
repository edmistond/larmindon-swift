import Foundation
import Observation

@MainActor
@Observable
public final class CaptionSession {
    public let store: CaptionStore
    public let routeManager: AudioRouteManager

    public private(set) var selectedSourceKind: TranscriptionSourceKind
    public private(set) var speechAnalyzerState = "Idle"
    public private(set) var lastError: String?
    public private(set) var lastVolatileResult: String = ""
    public private(set) var audioLevels = AudioLevelSnapshot()

    private var activeSource: TranscriptionSource?
    private var resultTask: Task<Void, Never>?
    private var fakeMeterTask: Task<Void, Never>?
    private var vadSensitivity: VADSensitivity

    public init(
        store: CaptionStore = CaptionStore(),
        routeManager: AudioRouteManager = AudioRouteManager(),
        selectedSourceKind: TranscriptionSourceKind = .fake,
        vadSensitivity: VADSensitivity = .medium
    ) {
        self.store = store
        self.routeManager = routeManager
        self.selectedSourceKind = selectedSourceKind
        self.vadSensitivity = vadSensitivity
    }

    public func start(kind: TranscriptionSourceKind? = nil, vadSensitivity: VADSensitivity? = nil) {
        let sourceKind = kind ?? selectedSourceKind
        selectedSourceKind = sourceKind
        if let vadSensitivity {
            self.vadSensitivity = vadSensitivity
        }

        Task {
            await stop()

            let source: TranscriptionSource = makeSource(kind: sourceKind)
            activeSource = source
            store.isRunning = true
            lastError = nil
            speechAnalyzerState = "Starting \(source.name)"

            resultTask = Task { @MainActor [weak self, source] in
                for await result in source.results {
                    self?.handle(result)
                }
            }

            do {
                try await routeManager.configureForCapture()
                try await source.start()
                speechAnalyzerState = "Running \(source.name)"
                if sourceKind == .fake {
                    startFakeMeter()
                }
            } catch {
                lastError = error.localizedDescription
                speechAnalyzerState = "Error"
                store.isRunning = false
                await source.stop()
                activeSource = nil
                resultTask?.cancel()
                resultTask = nil
            }
        }
    }

    public func stop() async {
        resultTask?.cancel()
        resultTask = nil
        fakeMeterTask?.cancel()
        fakeMeterTask = nil

        if let activeSource {
            await activeSource.stop()
        }
        activeSource = nil
        store.isRunning = false
        speechAnalyzerState = "Stopped"
        audioLevels = AudioLevelSnapshot()
    }

    public func clear() {
        store.clear()
        lastVolatileResult = ""
    }

    public func dumpRouteInfoToConsole() {
        routeManager.dumpRouteInfoToConsole()
    }

    private func makeSource(kind: TranscriptionSourceKind) -> TranscriptionSource {
        switch kind {
        case .fake:
            return FakeTranscriptionSource()
        case .live:
            return LiveSpeechAnalyzerTranscriptionSource(sensitivity: vadSensitivity)
        }
    }

    private func handle(_ result: CaptionResult) {
        switch result {
        case .volatile(let text):
            lastVolatileResult = text
            store.replaceVolatile(text)
        case .finalized(let text):
            store.appendFinalized(text)
        }
    }

    private func startFakeMeter() {
        fakeMeterTask?.cancel()
        fakeMeterTask = Task { [weak self] in
            var phase = 0.0
            var raw = 0.0
            var processed = 0.0

            while !Task.isCancelled {
                phase += 0.37
                let nextRaw = max(0.04, min(1.0, 0.18 + abs(sin(phase)) * 0.74))
                let speechGateOpen = nextRaw > 0.18
                let nextProcessed = speechGateOpen ? nextRaw : 0

                raw = AudioLevelMeter.smooth(previous: raw, next: nextRaw)
                processed = AudioLevelMeter.smooth(previous: processed, next: nextProcessed)

                await MainActor.run {
                    self?.audioLevels = AudioLevelSnapshot(
                        rawInputLevel: raw,
                        processedInputLevel: processed,
                        vadState: speechGateOpen ? "Speech likely" : "Gated"
                    )
                }

                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }
}
