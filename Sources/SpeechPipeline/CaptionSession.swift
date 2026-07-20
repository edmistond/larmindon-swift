import Foundation
import Observation

@MainActor
@Observable
public final class CaptionSession {
    public let store: CaptionStore
    public let routeManager: AudioRouteManager
    public let microphoneCapabilities: MicrophoneCapabilityMonitor

    public private(set) var selectedSourceKind: TranscriptionSourceKind
    public private(set) var speechAnalyzerState = "Idle"
    public private(set) var lastError: String?
    public private(set) var lastVolatileResult: String = ""
    public private(set) var audioLevels = AudioLevelSnapshot()
    public private(set) var activeAudioBufferFrameCount: Int?
    public private(set) var microphoneConfiguration = MicrophoneCaptureConfiguration()
    public private(set) var isApplyingMicrophoneConfiguration = false
    public private(set) var microphoneConfigurationError: String?

    private var activeSource: TranscriptionSource?
    private var resultTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var vadSensitivity: VADSensitivity
    private var audioBufferFrameCount: Int
    private var profanityFilterEnabled: Bool

    public init(
        store: CaptionStore = CaptionStore(),
        routeManager: AudioRouteManager = AudioRouteManager(),
        selectedSourceKind: TranscriptionSourceKind = .live,
        vadSensitivity: VADSensitivity = .medium,
        audioBufferFrameCount: Int = AudioCaptureBufferFrames.defaultValue,
        profanityFilterEnabled: Bool = false
    ) {
        self.store = store
        self.routeManager = routeManager
        self.microphoneCapabilities = MicrophoneCapabilityMonitor(routeManager: routeManager)
        self.selectedSourceKind = selectedSourceKind
        self.vadSensitivity = vadSensitivity
        self.audioBufferFrameCount = AudioCaptureBufferFrames.clamped(audioBufferFrameCount)
        self.profanityFilterEnabled = profanityFilterEnabled
    }

    public func start(
        kind: TranscriptionSourceKind? = nil,
        vadSensitivity: VADSensitivity? = nil,
        audioBufferFrameCount: Int? = nil,
        profanityFilterEnabled: Bool? = nil
    ) {
        let sourceKind = kind ?? selectedSourceKind
        selectedSourceKind = sourceKind
        if let vadSensitivity {
            self.vadSensitivity = vadSensitivity
        }
        if let audioBufferFrameCount {
            self.audioBufferFrameCount = AudioCaptureBufferFrames.clamped(audioBufferFrameCount)
        }
        if let profanityFilterEnabled {
            self.profanityFilterEnabled = profanityFilterEnabled
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
                try await routeManager.configureForCapture(configuration: microphoneConfiguration)
                try await source.start()
                speechAnalyzerState = "Running \(source.name)"
                microphoneCapabilities.refresh()
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
                microphoneCapabilities.refresh()
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
        microphoneCapabilities.refresh()
    }

    public func clear() {
        store.clear()
        lastVolatileResult = ""
    }

    public func dumpRouteInfoToConsole() {
        routeManager.dumpRouteInfoToConsole()
    }

    public func prepareMicrophoneControls() async {
        guard !store.isRunning else {
            microphoneCapabilities.refresh()
            return
        }

        do {
            try await routeManager.configureForInputSelection(configuration: microphoneConfiguration)
            microphoneConfigurationError = nil
        } catch {
            microphoneConfigurationError = error.localizedDescription
        }
        microphoneCapabilities.refresh()
    }

    @discardableResult
    public func applyMicrophoneConfiguration(
        _ configuration: MicrophoneCaptureConfiguration
    ) async -> Bool {
        guard !isApplyingMicrophoneConfiguration else { return false }

        var resolvedConfiguration = configuration
        if resolvedConfiguration.inputPortID == nil {
            resolvedConfiguration.inputPortID = routeManager.currentRouteInputs.first?.id
        }

        let shouldRestart = store.isRunning
        let previousConfiguration = microphoneConfiguration
        isApplyingMicrophoneConfiguration = true
        microphoneConfigurationError = nil
        defer { isApplyingMicrophoneConfiguration = false }

        if shouldRestart {
            await stop()
        }

        do {
            try await routeManager.configureForInputSelection(configuration: resolvedConfiguration)
            microphoneConfiguration = resolvedConfiguration
            microphoneCapabilities.refresh()

            if shouldRestart {
                start(kind: selectedSourceKind)
            }
            return true
        } catch {
            microphoneConfigurationError = error.localizedDescription
            try? await routeManager.configureForInputSelection(configuration: previousConfiguration)
            microphoneCapabilities.refresh()

            if shouldRestart {
                start(kind: selectedSourceKind)
            }
            return false
        }
    }

    private func makeSource(kind: TranscriptionSourceKind) -> TranscriptionSource {
        switch kind {
        case .fake:
            return FakeTranscriptionSource()
        case .live:
            return LiveSpeechAnalyzerTranscriptionSource(
                sensitivity: vadSensitivity,
                inputDeviceID: routeManager.preferredInputDeviceID,
                bufferFrameCount: audioBufferFrameCount,
                profanityFilterEnabled: profanityFilterEnabled
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
