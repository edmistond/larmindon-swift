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
    private var audioRouteRecoveryTask: Task<Void, Never>?

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

        #if os(macOS)
        routeManager.onInputAvailabilityChange = { [weak self] change in
            self?.handleAudioInputAvailabilityChange(change)
        }
        #endif
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
                if sourceKind == .live {
                    adoptMicrophoneConfigurationForCurrentInput()
                    try await routeManager.configureForCapture(configuration: microphoneConfiguration)
                }
                try await source.start()
                speechAnalyzerState = "Running \(source.name)"
                microphoneCapabilities.refresh()
            } catch {
                lastError = error.localizedDescription
                speechAnalyzerState = "Error"
                store.isRunning = false
                await source.stop()
                routeManager.releaseAudioSession()
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
        await stop(cancelAudioRouteRecovery: true)
    }

    private func stop(cancelAudioRouteRecovery: Bool) async {
        if cancelAudioRouteRecovery {
            audioRouteRecoveryTask?.cancel()
            audioRouteRecoveryTask = nil
        }
        resultTask?.cancel()
        resultTask = nil
        levelTask?.cancel()
        levelTask = nil

        if let activeSource {
            await activeSource.stop()
        }
        routeManager.releaseAudioSession()
        activeSource = nil
        activeAudioBufferFrameCount = nil
        store.isRunning = false
        speechAnalyzerState = "Stopped"
        audioLevels = AudioLevelSnapshot()
        microphoneCapabilities.refresh()
    }

    public func inputSelectionDidChange() {
        adoptMicrophoneConfigurationForCurrentInput()
        microphoneConfigurationError = nil
        microphoneCapabilities.refresh()

        if store.isRunning, selectedSourceKind == .live {
            start(kind: selectedSourceKind)
        }
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
            try await restoreMicrophoneConfigurationForCurrentInput()
            microphoneConfigurationError = nil
        } catch {
            microphoneConfigurationError = error.localizedDescription
        }
        microphoneCapabilities.refresh()
    }

    public func releaseMicrophoneControls() {
        guard !store.isRunning else { return }
        routeManager.releaseAudioSession()
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
            saveMicrophoneConfiguration(resolvedConfiguration)
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

    private func restoreMicrophoneConfigurationForCurrentInput() async throws {
        #if os(iOS)
        let previousConfiguration = microphoneConfiguration
        adoptMicrophoneConfigurationForCurrentInput()
        guard microphoneConfiguration != previousConfiguration else { return }

        try await routeManager.configureForInputSelection(configuration: microphoneConfiguration)
        #endif
    }

    private func adoptMicrophoneConfigurationForCurrentInput() {
        #if os(iOS)
        routeManager.refresh()
        guard let inputPortID = routeManager.preferredInputID
            ?? routeManager.currentRouteInputs.first?.id else {
            return
        }

        microphoneConfiguration = Self.resolvedMicrophoneConfiguration(
            inputPortID: inputPortID,
            storedConfiguration: MicrophoneConfigurationStore.load(inputPortID: inputPortID)
        )
        #endif
    }

    static func resolvedMicrophoneConfiguration(
        inputPortID: String,
        storedConfiguration: MicrophoneCaptureConfiguration?
    ) -> MicrophoneCaptureConfiguration {
        guard let storedConfiguration,
              storedConfiguration.inputPortID == inputPortID else {
            return MicrophoneCaptureConfiguration(inputPortID: inputPortID)
        }
        return storedConfiguration
    }

    private func saveMicrophoneConfiguration(_ configuration: MicrophoneCaptureConfiguration) {
        #if os(iOS)
        guard let inputPortID = configuration.inputPortID else { return }
        MicrophoneConfigurationStore.save(configuration, inputPortID: inputPortID)
        #endif
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

    #if os(macOS)
    private func handleAudioInputAvailabilityChange(_ change: AudioInputAvailabilityChange) {
        guard store.isRunning, selectedSourceKind == .live else { return }

        audioRouteRecoveryTask?.cancel()
        audioRouteRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            switch change {
            case .selectedInputRemainsAvailable:
                let sourceKind = selectedSourceKind
                await stop(cancelAudioRouteRecovery: false)
                guard !Task.isCancelled else { return }
                start(kind: sourceKind)
            case .selectedInputUnavailable(let name):
                await stop(cancelAudioRouteRecovery: false)
                lastError = "The selected audio input “\(name)” disconnected. Captions stopped."
                speechAnalyzerState = "Input disconnected"
            }
        }
    }
    #endif

}

#if os(iOS)
private enum MicrophoneConfigurationStore {
    private static let storageKey = "microphoneCaptureConfigurations"

    static func load(inputPortID: String) -> MicrophoneCaptureConfiguration? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let configurations = try? JSONDecoder().decode(
                [String: MicrophoneCaptureConfiguration].self,
                from: data
              ) else {
            return nil
        }
        return configurations[inputPortID]
    }

    static func save(_ configuration: MicrophoneCaptureConfiguration, inputPortID: String) {
        var configurations: [String: MicrophoneCaptureConfiguration] = [:]
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode(
            [String: MicrophoneCaptureConfiguration].self,
            from: data
           ) {
            configurations = stored
        }
        configurations[inputPortID] = configuration

        if let data = try? JSONEncoder().encode(configurations) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
#endif
