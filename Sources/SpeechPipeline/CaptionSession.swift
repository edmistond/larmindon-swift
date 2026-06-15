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
    public private(set) var activeAudioBufferFrameCount: Int?

    private var activeSource: TranscriptionSource?
    private var resultTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var vadSensitivity: VADSensitivity
    private var audioBufferFrameCount: Int

    public init(
        store: CaptionStore = CaptionStore(),
        routeManager: AudioRouteManager = AudioRouteManager(),
        selectedSourceKind: TranscriptionSourceKind = .live,
        vadSensitivity: VADSensitivity = .medium,
        audioBufferFrameCount: Int = AudioCaptureBufferFrames.defaultValue
    ) {
        self.store = store
        self.routeManager = routeManager
        self.selectedSourceKind = selectedSourceKind
        self.vadSensitivity = vadSensitivity
        self.audioBufferFrameCount = AudioCaptureBufferFrames.clamped(audioBufferFrameCount)
    }

    public func start(
        kind: TranscriptionSourceKind? = nil,
        vadSensitivity: VADSensitivity? = nil,
        audioBufferFrameCount: Int? = nil
    ) {
        let sourceKind = kind ?? selectedSourceKind
        selectedSourceKind = sourceKind
        if let vadSensitivity {
            self.vadSensitivity = vadSensitivity
        }
        if let audioBufferFrameCount {
            self.audioBufferFrameCount = AudioCaptureBufferFrames.clamped(audioBufferFrameCount)
        }

        Task {
            await stop()

            let source: TranscriptionSource = makeSource(kind: sourceKind)
            activeSource = source
            activeAudioBufferFrameCount = sourceKind == .live ? self.audioBufferFrameCount : nil
            store.isRunning = true
            lastError = nil
            speechAnalyzerState = "Starting \(source.name)"

            resultTask = Task { @MainActor [weak self, source] in
                for await result in source.results {
                    self?.handle(result)
                }
            }

            levelTask = Task { @MainActor [weak self, source] in
                for await snapshot in source.levelUpdates {
                    self?.audioLevels = snapshot
                }
            }

            do {
                try await routeManager.configureForCapture()
                try await source.start()
                speechAnalyzerState = "Running \(source.name)"
            } catch {
                lastError = error.localizedDescription
                speechAnalyzerState = "Error"
                store.isRunning = false
                await source.stop()
                activeSource = nil
                activeAudioBufferFrameCount = nil
                resultTask?.cancel()
                resultTask = nil
                levelTask?.cancel()
                levelTask = nil
            }
        }
    }

    public func stop() async {
        resultTask?.cancel()
        resultTask = nil
        levelTask?.cancel()
        levelTask = nil

        if let activeSource {
            await activeSource.stop()
        }
        activeSource = nil
        activeAudioBufferFrameCount = nil
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
            return LiveSpeechAnalyzerTranscriptionSource(
                sensitivity: vadSensitivity,
                inputDeviceID: routeManager.preferredInputDeviceID,
                bufferFrameCount: audioBufferFrameCount
            )
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

}
