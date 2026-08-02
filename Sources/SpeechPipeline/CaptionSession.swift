import AVFAudio
import Foundation
import Observation

@MainActor
@Observable
public final class CaptionSession {
    public let store: CaptionStore
    public let routeManager: AudioRouteManager
    public let microphoneCapabilities: MicrophoneCapabilityMonitor
    public let diagnostics: DiagnosticRecorder

    public private(set) var selectedSourceKind: TranscriptionSourceKind
    public private(set) var requestedMode: TranscriptionMode
    public private(set) var activeMode: TranscriptionMode?
    public private(set) var activeServerProvider: ServerProviderID?
    public private(set) var speechAnalyzerState = "Idle"
    public private(set) var lastError: String?
    public private(set) var lastVolatileResult: String = ""
    public private(set) var audioLevels = AudioLevelSnapshot()
    public private(set) var activeAudioBufferFrameCount: Int?
    public private(set) var requestedVoiceProcessingEnabled: Bool
    public private(set) var activeVoiceProcessingEnabled: Bool?
    public private(set) var microphoneConfiguration = MicrophoneCaptureConfiguration()
    public private(set) var isApplyingMicrophoneConfiguration = false
    public private(set) var microphoneConfigurationError: String?

    private var activeSource: TranscriptionSource?
    private var activeCapture: AudioCaptureSession?
    private var resultTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var captureLevelTask: Task<Void, Never>?
    private var vadSensitivity: VADSensitivity
    private var audioBufferFrameCount: Int
    private var profanityFilterEnabled: Bool
    private var audioRouteRecoveryTask: Task<Void, Never>?
    /// Device the running capture was started against, so device-list churn can be told
    /// apart from the selected input actually changing.
    private var activeInputDeviceID: UInt32?
    private var silentCaptureTask: Task<Void, Never>?
    private var didReceiveAudioSinceStart = false
    private var transitionTask: Task<Void, Never>?
    private var transitionGeneration = 0
    private let credentialStore: any ProviderCredentialStore
    private let networkPathMonitor: NetworkPathDiagnosticMonitor

    public init(
        store: CaptionStore = CaptionStore(),
        routeManager: AudioRouteManager = AudioRouteManager(),
        selectedSourceKind: TranscriptionSourceKind = .live,
        requestedMode: TranscriptionMode = .onDevice,
        vadSensitivity: VADSensitivity = .medium,
        audioBufferFrameCount: Int = AudioCaptureBufferFrames.defaultValue,
        voiceProcessingEnabled: Bool = VoiceProcessingPreference.defaultValue,
        profanityFilterEnabled: Bool = false,
        diagnostics: DiagnosticRecorder = .shared,
        credentialStore: any ProviderCredentialStore =
            KeychainProviderCredentialStore()
    ) {
        self.store = store
        self.routeManager = routeManager
        self.diagnostics = diagnostics
        self.credentialStore = credentialStore
        self.networkPathMonitor = NetworkPathDiagnosticMonitor(
            recorder: diagnostics
        )
        self.microphoneCapabilities = MicrophoneCapabilityMonitor(routeManager: routeManager)
        self.selectedSourceKind = selectedSourceKind
        self.requestedMode = requestedMode
        self.vadSensitivity = vadSensitivity
        self.audioBufferFrameCount = AudioCaptureBufferFrames.clamped(audioBufferFrameCount)
        self.requestedVoiceProcessingEnabled = voiceProcessingEnabled
        self.profanityFilterEnabled = profanityFilterEnabled

        routeManager.onRouteChange = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.recordCurrentAudioRoute(reason: "route_change")
            }
        }

        #if os(macOS)
        routeManager.onInputAvailabilityChange = { [weak self] change in
            self?.handleAudioInputAvailabilityChange(change)
        }
        #endif
    }

    public func start(
        kind: TranscriptionSourceKind? = nil,
        mode: TranscriptionMode? = nil,
        vadSensitivity: VADSensitivity? = nil,
        audioBufferFrameCount: Int? = nil,
        voiceProcessingEnabled: Bool? = nil,
        profanityFilterEnabled: Bool? = nil
    ) {
        let sourceKind = kind ?? selectedSourceKind
        let requestedMode = mode ?? self.requestedMode
        selectedSourceKind = sourceKind
        self.requestedMode = requestedMode
        if let vadSensitivity {
            self.vadSensitivity = vadSensitivity
        }
        if let audioBufferFrameCount {
            self.audioBufferFrameCount = AudioCaptureBufferFrames.clamped(audioBufferFrameCount)
        }
        if let voiceProcessingEnabled {
            requestedVoiceProcessingEnabled = voiceProcessingEnabled
        }
        if let profanityFilterEnabled {
            self.profanityFilterEnabled = profanityFilterEnabled
        }

        transitionGeneration += 1
        let generation = transitionGeneration
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await performStart(
                sourceKind: sourceKind,
                mode: requestedMode,
                generation: generation
            )
        }
    }

    private func performStart(
        sourceKind: TranscriptionSourceKind,
        mode: TranscriptionMode,
        generation: Int
    ) async {
        await stopActive(cancelAudioRouteRecovery: true)
        guard generation == transitionGeneration, !Task.isCancelled else {
            return
        }

        do {
            let source = try makeSource(kind: sourceKind, mode: mode)
            activeSource = source
            activeAudioBufferFrameCount = sourceKind == .live ? self.audioBufferFrameCount : nil
            store.isRunning = true
            lastError = nil
            speechAnalyzerState = "Starting \(source.name)"
            activeMode = nil
            activeServerProvider = nil

            await diagnostics.record(
                category: "state",
                name: "transcription_starting",
                fields: [
                    "requested_mode": mode.rawValue,
                    "source": source.name,
                    "generation": String(generation),
                ]
            )

            resultTask = Task { @MainActor [weak self, source] in
                for await result in source.results {
                    self?.handle(result)
                }
            }

            didReceiveAudioSinceStart = false
            levelTask = Task { @MainActor [weak self, source] in
                for await snapshot in source.levelUpdates {
                    self?.didReceiveAudioSinceStart = true
                    self?.audioLevels = snapshot
                }
            }

            if sourceKind == .live {
                adoptMicrophoneConfigurationForCurrentInput()
                try await routeManager.configureForCapture(
                    configuration: microphoneConfiguration,
                    voiceProcessingEnabled: requestedVoiceProcessingEnabled
                )
                activeInputDeviceID = routeManager.preferredInputDeviceID
                await recordCurrentAudioRoute(reason: "capture_start")
            }

            if sourceKind == .live, mode == .server,
               let sonioxSource = source as? SonioxTranscriptionSource {
                let capture = AudioCaptureSession(
                    inputDeviceID: routeManager.preferredInputDeviceID,
                    bufferFrameCount: audioBufferFrameCount,
                    voiceProcessingEnabled: requestedVoiceProcessingEnabled,
                    diagnostics: diagnostics
                )
                activeCapture = capture
                captureLevelTask = Task {
                    for await snapshot in capture.levelUpdates {
                        self.audioLevels = snapshot
                    }
                }
                try await sonioxSource.start(
                    audioFrames: capture.frames
                )
                guard generation == transitionGeneration,
                      !Task.isCancelled else {
                    await sonioxSource.stop()
                    return
                }
                try await capture.start()
                activeVoiceProcessingEnabled =
                    capture.activeVoiceProcessingEnabled
                activeServerProvider = .soniox
            } else {
                try await source.start()
                if let source = source as? LiveSpeechAnalyzerTranscriptionSource {
                    activeVoiceProcessingEnabled = source.activeVoiceProcessingEnabled
                }
            }

            guard generation == transitionGeneration,
                  !Task.isCancelled else {
                await stopActive(cancelAudioRouteRecovery: true)
                return
            }
            activeMode = mode
            speechAnalyzerState = "Running \(source.name)"
            startSilentCaptureWatchdog(generation: generation)
            microphoneCapabilities.refresh()
            await diagnostics.record(
                category: "state",
                name: "transcription_running",
                fields: [
                    "active_mode": mode.rawValue,
                    "provider":
                        activeServerProvider?.rawValue ?? "apple",
                ]
            )
        } catch {
            lastError = error.localizedDescription
            speechAnalyzerState = "Error"
            await diagnostics.record(
                category: "error",
                name: "transcription_start_failed",
                fields: [
                    "requested_mode": mode.rawValue,
                    "message": error.localizedDescription,
                ]
            )
            await stopActive(cancelAudioRouteRecovery: true)
            requestedMode = mode
            speechAnalyzerState = "Error"
            lastError = error.localizedDescription
        }
    }

    public func stop() async {
        transitionGeneration += 1
        transitionTask?.cancel()
        transitionTask = nil
        await stopActive(cancelAudioRouteRecovery: true)
    }

    private func stopActive(cancelAudioRouteRecovery: Bool) async {
        if cancelAudioRouteRecovery {
            audioRouteRecoveryTask?.cancel()
            audioRouteRecoveryTask = nil
        }
        captureLevelTask?.cancel()
        captureLevelTask = nil
        silentCaptureTask?.cancel()
        silentCaptureTask = nil

        if let activeCapture {
            await activeCapture.stop()
        }
        activeCapture = nil
        if let activeSource {
            await activeSource.stop()
        }
        resultTask?.cancel()
        resultTask = nil
        levelTask?.cancel()
        levelTask = nil
        routeManager.releaseAudioSession()
        activeSource = nil
        activeInputDeviceID = nil
        activeAudioBufferFrameCount = nil
        activeVoiceProcessingEnabled = nil
        activeMode = nil
        activeServerProvider = nil
        store.isRunning = false
        speechAnalyzerState = "Stopped"
        audioLevels = AudioLevelSnapshot()
        microphoneCapabilities.refresh()
        await diagnostics.record(
            category: "state",
            name: "transcription_stopped",
            fields: ["requested_mode": requestedMode.rawValue]
        )
    }

    public func requestMode(_ mode: TranscriptionMode) {
        let didChange = requestedMode != mode
        requestedMode = mode
        if store.isRunning, didChange || activeMode != mode {
            start(kind: selectedSourceKind, mode: mode)
        }
    }

    public func inputSelectionDidChange() {
        adoptMicrophoneConfigurationForCurrentInput()
        microphoneConfigurationError = nil
        microphoneCapabilities.refresh()

        if store.isRunning, selectedSourceKind == .live {
            start(kind: selectedSourceKind, mode: requestedMode)
        }
    }

    public func setVoiceProcessingPreference(_ enabled: Bool) {
        requestedVoiceProcessingEnabled = enabled
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
                start(kind: selectedSourceKind, mode: requestedMode)
            }
            return true
        } catch {
            microphoneConfigurationError = error.localizedDescription
            try? await routeManager.configureForInputSelection(configuration: previousConfiguration)
            microphoneCapabilities.refresh()

            if shouldRestart {
                start(kind: selectedSourceKind, mode: requestedMode)
            }
            return false
        }
    }

    private func makeSource(
        kind: TranscriptionSourceKind,
        mode: TranscriptionMode
    ) throws -> TranscriptionSource {
        switch kind {
        case .fake:
            return FakeTranscriptionSource()
        case .live:
            switch mode {
            case .onDevice:
                return LiveSpeechAnalyzerTranscriptionSource(
                    sensitivity: vadSensitivity,
                    inputDeviceID: routeManager.preferredInputDeviceID,
                    bufferFrameCount: audioBufferFrameCount,
                    voiceProcessingEnabled: requestedVoiceProcessingEnabled,
                    profanityFilterEnabled: profanityFilterEnabled
                )
            case .server:
                guard let key = try credentialStore.credential(
                    for: .soniox
                ), !key.isEmpty else {
                    throw TranscriptionSourceError.unavailable(
                        "Soniox API key not configured. Add it in Settings."
                    )
                }
                return SonioxTranscriptionSource(
                    apiKey: key,
                    diagnostics: diagnostics
                )
            }
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
        case .volatileSegments(let segments):
            lastVolatileResult = segments.map(\.text).joined(separator: "\n")
            store.replaceVolatile(segments)
        case .finalizedSegments(let segments):
            store.appendFinalized(segments)
        case .failure(let message):
            lastError = message
            speechAnalyzerState = "Error"
            scheduleFailureStop()
        }
    }

    /// Capture can start cleanly and still deliver no audio at all, which otherwise shows
    /// up only as a level meter that never moves. Say so rather than looking hung.
    private func startSilentCaptureWatchdog(generation: Int) {
        silentCaptureTask?.cancel()
        silentCaptureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self,
                  !Task.isCancelled,
                  generation == transitionGeneration,
                  store.isRunning,
                  !didReceiveAudioSinceStart else {
                return
            }

            let inputName = routeManager.currentInputName
            #if os(iOS)
            lastError = requestedVoiceProcessingEnabled
                ? """
                No audio is arriving from “\(inputName)”. Try turning off voice \
                processing in Settings, then Stop and Start.
                """
                : "No audio is arriving from “\(inputName)”."
            #else
            lastError = "No audio is arriving from “\(inputName)”."
            #endif
        }
    }

    private func scheduleFailureStop() {
        transitionGeneration += 1
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await stopActive(cancelAudioRouteRecovery: true)
            speechAnalyzerState = "Error"
        }
    }

    private func recordCurrentAudioRoute(reason: String) async {
        routeManager.refresh()
        var fields = [
            "requested_input":
                DiagnosticRedaction.identifier(
                    microphoneConfiguration.inputPortID
                ),
            "preferred_input":
                DiagnosticRedaction.identifier(
                    routeManager.preferredInputID
                ),
            "active_input":
                DiagnosticRedaction.identifier(
                    routeManager.currentRouteInputs.first?.id
                ),
            "active_input_kind":
                routeManager.currentRouteInputs.first?.kind ?? "none",
            "outputs": routeManager.currentRouteOutputs
                .map {
                    "\(DiagnosticRedaction.identifier($0.id)):\($0.kind)"
                }
                .joined(separator: ","),
            "reason": reason,
            "mismatch": String(
                microphoneConfiguration.inputPortID != nil
                    && microphoneConfiguration.inputPortID
                        != routeManager.currentRouteInputs.first?.id
            ),
        ]
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        fields["category"] = audioSession.category.rawValue
        fields["mode"] = audioSession.mode.rawValue
        fields["category_options"] =
            String(audioSession.categoryOptions.rawValue)
        fields["sample_rate"] = String(audioSession.sampleRate)
        fields["io_buffer_duration"] =
            String(audioSession.ioBufferDuration)
        #endif
        await diagnostics.record(
            category: "audio_route",
            name: "capture_route",
            fields: fields
        )
    }

    #if os(macOS)
    private func handleAudioInputAvailabilityChange(_ change: AudioInputAvailabilityChange) {
        guard store.isRunning, selectedSourceKind == .live else { return }

        audioRouteRecoveryTask?.cancel()
        audioRouteRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            switch change {
            case .selectedInputRemainsAvailable:
                // Any device-list change reaches this point, including the aggregate
                // device that voice processing creates while starting capture. Restarting
                // on those would recreate the aggregate and loop forever, so only restart
                // when the device we are actually capturing from changed identity — which
                // is what happens when an input is unplugged and reconnected.
                guard routeManager.preferredInputDeviceID != activeInputDeviceID else {
                    return
                }
                let sourceKind = selectedSourceKind
                await stopActive(cancelAudioRouteRecovery: false)
                guard !Task.isCancelled else { return }
                start(kind: sourceKind, mode: requestedMode)
            case .selectedInputUnavailable(let name):
                await stopActive(cancelAudioRouteRecovery: false)
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
