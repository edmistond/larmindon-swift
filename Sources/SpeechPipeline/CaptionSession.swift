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
    /// True between an interruption starting and recovery resolving either way. The session
    /// is still nominally running, but no audio is arriving — without this the status line
    /// keeps claiming "Listening", and an empty caption view reads as a quiet room rather
    /// than a dead session. Always false on macOS.
    public private(set) var isInterrupted = false {
        didSet {
            if isInterrupted != oldValue { syncCaptureConnectionState() }
        }
    }
    /// True while a server provider has lost its connection and is reconnecting on its
    /// own. Capture is still running — which is what keeps a backgrounded iOS app alive
    /// long enough to reconnect — but no captions are arriving.
    public private(set) var isReconnecting = false {
        didSet {
            if isReconnecting != oldValue { syncCaptureConnectionState() }
        }
    }
    /// A low-update summary of capture health for the Start/Stop control. Written only when
    /// the state actually changes — a few times a minute at most — so, unlike `audioLevels`,
    /// it is cheap to observe from the main screen. See `CaptureStatusTracker`.
    public private(set) var captureStatus: CaptureStatus = .stopped

    /// Optional factory for exercising lifecycle transitions without live microphone access.
    @ObservationIgnored
    var sourceFactory: ((TranscriptionSourceKind, TranscriptionMode) throws -> any TranscriptionSource)?
    private var localStopTask: Task<Void, Never>?
    private var activeSource: TranscriptionSource?
    private var activeCapture: AudioCaptureSession?
    private var resultTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var captureLevelTask: Task<Void, Never>?
    private var vadSensitivity: VADSensitivity
    private var audioBufferFrameCount: Int
    private var profanityFilterEnabled: Bool
    private var sonioxAudioEncoding: SonioxAudioEncoding
    private var sonioxOpusBitRate: SonioxOpusBitRate
    private var sonioxFLACSampleRate: SonioxFLACSampleRate
    private var audioRouteRecoveryTask: Task<Void, Never>?
    /// Device the running capture was started against, so device-list churn can be told
    /// apart from the selected input actually changing.
    private var activeInputDeviceID: UInt32?
    @ObservationIgnored
    var delay = AsyncDelay.continuous
    @ObservationIgnored
    private(set) var silentCaptureTask: Task<Void, Never>?
    private var didReceiveAudioSinceStart = false
    @ObservationIgnored
    private var captureStatusTracker = CaptureStatusTracker()
    /// Re-evaluates `captureStatus` while running, since several transitions are a
    /// threshold passing with no input event to trigger them.
    @ObservationIgnored
    private(set) var captureStatusTask: Task<Void, Never>?
    /// Time source for capture status thresholds; tests substitute a manual clock.
    @ObservationIgnored
    var captureStatusClock: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    private var silentCaptureWarning: String?
    private var reconnectingWarning: String?
    /// When `audioLevels` was last written for a level-only change. See `publishAudioLevels`.
    private var lastLevelOnlyPublish: ContinuousClock.Instant?
    /// Minimum spacing between level-only writes. Capture delivers a snapshot per buffer
    /// (about 60/s at the default 768 frames); the meter reads fine at 20/s.
    private static let levelOnlyPublishInterval: Duration = .milliseconds(50)
    /// How long a Clear can be undone.
    public static let clearUndoWindow: Duration = .seconds(5)

    /// True from a Clear that removed finalized text until it is undone, the window
    /// expires, or another Clear replaces it.
    public private(set) var canUndoClear = false
    private var clearedChunks: [TranscriptChunk] = []
    @ObservationIgnored
    private(set) var clearUndoExpiryTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var transitionGeneration = 0
    private let credentialStore: any ProviderCredentialStore
    private let networkPathMonitor: NetworkPathDiagnosticMonitor
    private let environmentMonitor: AppEnvironmentDiagnosticMonitor
    private let failureNotifier: any CaptionFailureNotifying

    #if os(iOS)
    /// Captured when an interruption begins, because by the time it ends the session has
    /// already been torn down and `store.isRunning` can no longer answer "were we supposed
    /// to be captioning?". Without it, a call ending after the user had stopped captions
    /// would start recording on its own.
    private var wasRunningBeforeInterruption = false
    private var interruptionAttempt = 0
    @ObservationIgnored
    private(set) var interruptionRecoveryTask: Task<Void, Never>?
    private var didPrepareFailureNotifier = false
    #endif

    public init(
        store: CaptionStore = CaptionStore(),
        routeManager: AudioRouteManager = AudioRouteManager(),
        selectedSourceKind: TranscriptionSourceKind = .live,
        requestedMode: TranscriptionMode = .onDevice,
        vadSensitivity: VADSensitivity = .medium,
        audioBufferFrameCount: Int = AudioCaptureBufferFrames.defaultValue,
        voiceProcessingEnabled: Bool = VoiceProcessingPreference.defaultValue,
        profanityFilterEnabled: Bool = false,
        sonioxAudioEncoding: SonioxAudioEncoding = SonioxAudioEncoding.defaultValue,
        sonioxOpusBitRate: SonioxOpusBitRate = SonioxOpusBitRate.defaultValue,
        sonioxFLACSampleRate: SonioxFLACSampleRate = SonioxFLACSampleRate.defaultValue,
        diagnostics: DiagnosticRecorder = .shared,
        credentialStore: any ProviderCredentialStore =
            KeychainProviderCredentialStore(),
        failureNotifier: any CaptionFailureNotifying =
            UserNotificationCaptionFailureNotifier()
    ) {
        self.store = store
        self.routeManager = routeManager
        self.diagnostics = diagnostics
        self.credentialStore = credentialStore
        self.failureNotifier = failureNotifier
        self.networkPathMonitor = NetworkPathDiagnosticMonitor(
            recorder: diagnostics
        )
        self.environmentMonitor = AppEnvironmentDiagnosticMonitor(
            recorder: diagnostics
        )
        self.microphoneCapabilities = MicrophoneCapabilityMonitor(routeManager: routeManager)
        self.selectedSourceKind = selectedSourceKind
        self.requestedMode = requestedMode
        self.vadSensitivity = vadSensitivity
        self.audioBufferFrameCount = AudioCaptureBufferFrames.clamped(audioBufferFrameCount)
        self.requestedVoiceProcessingEnabled = voiceProcessingEnabled
        self.profanityFilterEnabled = profanityFilterEnabled
        self.sonioxAudioEncoding = sonioxAudioEncoding
        self.sonioxOpusBitRate = sonioxOpusBitRate
        self.sonioxFLACSampleRate = sonioxFLACSampleRate

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

        #if os(iOS)
        routeManager.onAudioInterruption = { [weak self] event in
            self?.handleAudioInterruption(event)
        }
        #endif
    }

    /// Includes transitions before `isRunning` becomes true and interrupted sessions.
    public var canStartIfIdle: Bool {
        !store.isRunning && transitionTask == nil && localStopTask == nil && !isInterrupted
    }

    /// A launcher must never turn an existing session into a restart or a Stop.
    @discardableResult
    public func startIfIdle(
        kind: TranscriptionSourceKind? = nil,
        mode: TranscriptionMode? = nil,
        vadSensitivity: VADSensitivity? = nil,
        audioBufferFrameCount: Int? = nil,
        voiceProcessingEnabled: Bool? = nil,
        profanityFilterEnabled: Bool? = nil,
        sonioxAudioEncoding: SonioxAudioEncoding? = nil,
        sonioxOpusBitRate: SonioxOpusBitRate? = nil,
        sonioxFLACSampleRate: SonioxFLACSampleRate? = nil
    ) -> Bool {
        guard canStartIfIdle else { return false }
        start(
            kind: kind, mode: mode, vadSensitivity: vadSensitivity,
            audioBufferFrameCount: audioBufferFrameCount,
            voiceProcessingEnabled: voiceProcessingEnabled,
            profanityFilterEnabled: profanityFilterEnabled,
            sonioxAudioEncoding: sonioxAudioEncoding,
            sonioxOpusBitRate: sonioxOpusBitRate,
            sonioxFLACSampleRate: sonioxFLACSampleRate)
        return true
    }

    public func start(
        kind: TranscriptionSourceKind? = nil,
        mode: TranscriptionMode? = nil,
        vadSensitivity: VADSensitivity? = nil,
        audioBufferFrameCount: Int? = nil,
        voiceProcessingEnabled: Bool? = nil,
        profanityFilterEnabled: Bool? = nil,
        sonioxAudioEncoding: SonioxAudioEncoding? = nil,
        sonioxOpusBitRate: SonioxOpusBitRate? = nil,
        sonioxFLACSampleRate: SonioxFLACSampleRate? = nil
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
        if let sonioxAudioEncoding {
            self.sonioxAudioEncoding = sonioxAudioEncoding
        }
        if let sonioxOpusBitRate {
            self.sonioxOpusBitRate = sonioxOpusBitRate
        }
        if let sonioxFLACSampleRate {
            self.sonioxFLACSampleRate = sonioxFLACSampleRate
        }

        #if os(iOS)
        // A deliberate Start supersedes whatever recovery was in flight.
        cancelInterruptionRecovery()
        #endif

        transitionGeneration += 1
        let generation = transitionGeneration
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == transitionGeneration { transitionTask = nil }
            }
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
        generation: Int,
        preserveRunningState: Bool = false
    ) async {
        // Recorded before the teardown rather than after it. `stopActive` can take seconds,
        // and if a provider teardown stalls this is the only evidence that Start was pressed
        // at all — otherwise a stuck stop looks like an empty log with nothing after it.
        await diagnostics.record(
            category: "state",
            name: "transcription_start_requested",
            fields: [
                "requested_mode": mode.rawValue,
                "generation": String(generation),
            ]
        )

        guard generation == transitionGeneration, !Task.isCancelled else { return }
        await stopActive(
            cancelAudioRouteRecovery: true,
            preserveRunningState: preserveRunningState
        )
        guard generation == transitionGeneration, !Task.isCancelled else {
            return
        }

        do {
            let source = try makeSource(kind: sourceKind, mode: mode)
            activeSource = source
            activeAudioBufferFrameCount = sourceKind == .live ? self.audioBufferFrameCount : nil
            store.isRunning = true
            lastError = nil
            silentCaptureWarning = nil
            reconnectingWarning = nil
            isReconnecting = false
            speechAnalyzerState = "Starting \(source.name)"
            activeMode = nil
            activeServerProvider = nil
            captureStatusTracker.start(mode: mode, at: captureStatusClock())
            publishCaptureStatus()
            startCaptureStatusTicker(generation: generation)

            await diagnostics.record(
                category: "state",
                name: "transcription_starting",
                fields: [
                    "requested_mode": mode.rawValue,
                    "source": source.name,
                    "generation": String(generation),
                ]
            )

            guard generation == transitionGeneration, !Task.isCancelled else { return }
            resultTask = Task { @MainActor [weak self, source] in
                for await result in source.results {
                    guard let self, !Task.isCancelled,
                        generation == self.transitionGeneration
                    else { return }
                    self.handle(result)
                }
            }

            didReceiveAudioSinceStart = false
            levelTask = Task { @MainActor [weak self, source] in
                for await snapshot in source.levelUpdates {
                    guard let self, !Task.isCancelled,
                        generation == self.transitionGeneration
                    else { return }
                    self.receiveAudioLevels(snapshot)
                }
            }

            if sourceKind == .live {
                adoptMicrophoneConfigurationForCurrentInput()
                try await routeManager.configureForCapture(
                    configuration: microphoneConfiguration,
                    voiceProcessingEnabled: requestedVoiceProcessingEnabled
                )
                guard generation == transitionGeneration, !Task.isCancelled else { return }
                activeInputDeviceID = routeManager.preferredInputDeviceID
                await recordCurrentAudioRoute(reason: "capture_start")
            }

            guard generation == transitionGeneration, !Task.isCancelled else { return }
            if sourceKind == .live, mode == .server,
                let sonioxSource = source as? SonioxTranscriptionSource
            {
                let capture = AudioCaptureSession(
                    inputDeviceID: routeManager.preferredInputDeviceID,
                    bufferFrameCount: audioBufferFrameCount,
                    voiceProcessingEnabled: requestedVoiceProcessingEnabled,
                    diagnostics: diagnostics
                )
                activeCapture = capture
                captureLevelTask = Task {
                    for await snapshot in capture.levelUpdates {
                        guard !Task.isCancelled,
                            generation == self.transitionGeneration
                        else { return }
                        self.receiveAudioLevels(snapshot)
                    }
                }
                try await sonioxSource.start(
                    audioFrames: capture.frames
                )
                guard generation == transitionGeneration,
                    !Task.isCancelled
                else {
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
                !Task.isCancelled
            else {
                await source.stop()
                return
            }
            activeMode = mode
            speechAnalyzerState = "Running \(source.name)"
            startSilentCaptureWatchdog(generation: generation)
            captureStatusTracker.captureDidStart(at: captureStatusClock())
            refreshCaptureStatus()
            // Memory and thermal sampling runs only while captioning — that's the window
            // where a background kill would actually cost something.
            environmentMonitor.startSampling()
            #if os(iOS)
            prepareFailureNotifierIfNeeded(sourceKind: sourceKind)
            #endif
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
            guard generation == transitionGeneration, !Task.isCancelled else { return }
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
            guard generation == transitionGeneration, !Task.isCancelled else { return }
            await stopActive(cancelAudioRouteRecovery: true)
            guard generation == transitionGeneration, !Task.isCancelled else { return }
            requestedMode = mode
            speechAnalyzerState = "Error"
            lastError = error.localizedDescription
        }
    }

    public func stop() async {
        transitionGeneration += 1
        transitionTask?.cancel()
        transitionTask = nil
        #if os(iOS)
        // Disarm any pending resume. Stopping captions *during* a phone call and having
        // them come back when the call ends would be the app deciding to record on its own.
        cancelInterruptionRecovery()
        #endif
        await stopActive(cancelAudioRouteRecovery: true)
    }

    #if os(iOS)
    /// Asks for notification permission the first time a live session actually runs.
    ///
    /// Not at launch — there's no reason to prompt for a permission that only matters once
    /// captions are running. Not on first backgrounding either, tempting as that is: the
    /// system prompt can't be presented while the app is in the background, so the request
    /// would be silently denied at exactly the moment it became relevant.
    private func prepareFailureNotifierIfNeeded(sourceKind: TranscriptionSourceKind) {
        guard sourceKind == .live, !didPrepareFailureNotifier else { return }
        didPrepareFailureNotifier = true
        Task { @MainActor [failureNotifier] in
            await failureNotifier.prepare()
        }
    }

    private func cancelInterruptionRecovery() {
        interruptionRecoveryTask?.cancel()
        interruptionRecoveryTask = nil
        wasRunningBeforeInterruption = false
        interruptionAttempt = 0
        isInterrupted = false
    }
    #endif

    private func stopActive(
        cancelAudioRouteRecovery: Bool,
        preserveRunningState: Bool = false
    ) async {
        if cancelAudioRouteRecovery {
            audioRouteRecoveryTask?.cancel()
            audioRouteRecoveryTask = nil
        }
        if !preserveRunningState {
            store.isRunning = false
            markCaptureStopped()
        }
        // Join only microphone/local teardown. This task owns all session-state writes,
        // so an older Stop cannot release the audio session belonging to a new Start.
        if let localStopTask {
            await localStopTask.value
            return
        }
        let task = Task { @MainActor in
            await self.performLocalStop(preserveRunningState: preserveRunningState)
            self.localStopTask = nil
        }
        localStopTask = task
        await task.value
    }

    private func performLocalStop(preserveRunningState: Bool) async {
        // Tearing a provider down can take seconds — Soniox waits on the server closing
        // the socket. The Start/Stop button reads `store.isRunning`, so clear the visible
        // state up front rather than after the teardown, or Stop looks like it did
        // nothing and gets pressed again.
        //
        // Interruption recovery is the exception: it stops and starts as one motion, and
        // flipping this would flash the button to Start mid-recovery for a session the
        // user never asked to stop.
        if !preserveRunningState {
            store.isRunning = false
        }
        // Same exception for the status: mid-recovery it reads Stalled (from
        // `isInterrupted`), never a Stopped the user didn't ask for.
        if !preserveRunningState || !store.isRunning {
            markCaptureStopped()
        }
        captureStatusTask?.cancel()
        captureStatusTask = nil
        audioLevels = AudioLevelSnapshot()
        lastLevelOnlyPublish = nil
        isReconnecting = false
        reconnectingWarning = nil
        activeMode = nil
        activeServerProvider = nil
        activeInputDeviceID = nil
        activeAudioBufferFrameCount = nil
        activeVoiceProcessingEnabled = nil

        captureLevelTask?.cancel()
        captureLevelTask = nil
        silentCaptureTask?.cancel()
        silentCaptureTask = nil
        environmentMonitor.stopSampling()
        // Stop consuming results before the source shuts down, so anything it emits on
        // the way out cannot be mistaken for a live failure and restart the teardown.
        resultTask?.cancel()
        resultTask = nil
        levelTask?.cancel()
        levelTask = nil

        let capture = activeCapture
        let source = activeSource
        activeCapture = nil
        activeSource = nil
        await CaptionSessionTeardown.stopLocalResources(capture: capture, source: source) {
            routeManager.releaseAudioSession()
        }
        if let source = source as? any BackgroundFinishingTranscriptionSource {
            // Captures only the retired provider: completion cannot touch this session,
            // its audio route, or the replacement provider. Soniox retains its watchdog.
            Task { await source.stop() }
        }
        if !preserveRunningState || !store.isRunning {
            speechAnalyzerState = "Stopped"
        }
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

    /// Clears immediately. Finalized chunks are held for `clearUndoWindow` so `undoClear()`
    /// can bring them back. The volatile tail is not held: the provider keeps revising it
    /// and will resend that text.
    public func clear() {
        let cleared = store.finalizedChunks
        store.clear()
        lastVolatileResult = ""

        guard !cleared.isEmpty else {
            // Nothing to bring back, and a clear of an empty store must not leave an
            // earlier stash offered as if it belonged to this one.
            discardClearedChunks()
            return
        }

        clearedChunks = cleared
        setCanUndoClear(true)
        let chunkCount = cleared.count
        Task { @MainActor [weak self] in
            await self?.diagnostics.record(
                category: "state",
                name: "captions_cleared",
                fields: ["chunk_count": String(chunkCount)]
            )
        }

        clearUndoExpiryTask?.cancel()
        clearUndoExpiryTask = Task { @MainActor [weak self, delay] in
            try? await delay.sleep(Self.clearUndoWindow)
            guard let self, !Task.isCancelled else { return }
            discardClearedChunks()
        }
    }

    /// Restores what the last `clear()` removed, ahead of anything finalized since.
    public func undoClear() {
        guard canUndoClear else { return }
        let restored = clearedChunks
        discardClearedChunks()
        store.restoreCleared(restored)

        let chunkCount = restored.count
        Task { @MainActor [weak self] in
            await self?.diagnostics.record(
                category: "state",
                name: "captions_clear_undone",
                fields: ["chunk_count": String(chunkCount)]
            )
        }
    }

    private func discardClearedChunks() {
        clearUndoExpiryTask?.cancel()
        clearUndoExpiryTask = nil
        clearedChunks = []
        setCanUndoClear(false)
    }

    private func setCanUndoClear(_ value: Bool) {
        if canUndoClear != value { canUndoClear = value }
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
        // A widget may dismiss the panel while its new session is still starting.
        guard canStartIfIdle else { return }
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
        if let sourceFactory { return try sourceFactory(kind, mode) }
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
                guard
                    let key = try credentialStore.credential(
                        for: .soniox
                    ), !key.isEmpty
                else {
                    throw TranscriptionSourceError.unavailable(
                        "Soniox API key not configured. Add it in Settings."
                    )
                }
                return SonioxTranscriptionSource(
                    apiKey: key,
                    diagnostics: diagnostics,
                    audioEncoding: sonioxAudioEncoding,
                    opusBitRate: sonioxOpusBitRate,
                    flacSampleRate: sonioxFLACSampleRate
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
        guard
            let inputPortID = routeManager.preferredInputID
                ?? routeManager.currentRouteInputs.first?.id
        else {
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
            storedConfiguration.inputPortID == inputPortID
        else {
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
        // Server mode's meter is hot when the backend is returning words, not when the room
        // is loud. On-device has no `activeCapture`, so this is a no-op there and the
        // SpeechAnalyzer VAD keeps driving the colour.
        if result.carriesTranscription {
            activeCapture?.noteProviderActivity()
        }
        captureStatusTracker.received(result, at: captureStatusClock())
        refreshCaptureStatus()

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
            isReconnecting = false
            reconnectingWarning = nil
            lastError = message
            speechAnalyzerState = "Error"
            scheduleFailureStop()
            // When this happens with the app in the background, `lastError` goes unread
            // and the session is gone. The notifier stays quiet in the foreground.
            Task { @MainActor [failureNotifier] in
                await failureNotifier.notifyCaptionsStopped(message: message)
            }
        case .connectionInterrupted(let message):
            isReconnecting = true
            reconnectingWarning = message
            lastError = message
            speechAnalyzerState = "Reconnecting"
        case .connectionRestored:
            isReconnecting = false
            if let warning = reconnectingWarning, lastError == warning { lastError = nil }
            reconnectingWarning = nil
            if let activeSource { speechAnalyzerState = "Running \(activeSource.name)" }
        }
    }

    /// Both provider-owned and session-owned capture report through this boundary.
    /// Receiving even an unchanged, zero-level buffer proves capture is delivering audio;
    /// meter deduplication and display throttling must not hide that from the watchdog.
    func receiveAudioLevels(_ snapshot: AudioLevelSnapshot) {
        didReceiveAudioSinceStart = true
        if let warning = silentCaptureWarning {
            if lastError == warning { lastError = nil }
            silentCaptureWarning = nil
        }
        captureStatusTracker.audioArrived(
            silent: CaptureStatusTracker.isEffectivelySilent(snapshot),
            at: captureStatusClock()
        )
        refreshCaptureStatus()
        publishAudioLevels(snapshot)
    }

    private func refreshCaptureStatus() {
        _ = captureStatusTracker.evaluate(at: captureStatusClock())
        publishCaptureStatus()
    }

    private func markCaptureStopped() {
        captureStatusTracker.stop(at: captureStatusClock())
        publishCaptureStatus()
    }

    private func syncCaptureConnectionState() {
        captureStatusTracker.setConnectionState(
            reconnecting: isReconnecting,
            interrupted: isInterrupted,
            at: captureStatusClock()
        )
        publishCaptureStatus()
    }

    /// Copies the tracker's status out, writing only on a change: every write to an
    /// `@Observable` property invalidates its readers, and this one is on the main screen.
    private func publishCaptureStatus() {
        let next = captureStatusTracker.status
        guard next != captureStatus else { return }
        let previous = captureStatus
        captureStatus = next
        let requestedMode = requestedMode.rawValue
        Task { @MainActor [diagnostics] in
            await diagnostics.record(
                category: "state",
                name: "capture_status_changed",
                fields: [
                    "from": previous.rawValue,
                    "to": next.rawValue,
                    "requested_mode": requestedMode,
                ]
            )
        }
    }

    /// Thresholds pass without an input event — no audio at all is exactly that case — so
    /// the status is re-evaluated about once a second while a session runs.
    private func startCaptureStatusTicker(generation: Int) {
        captureStatusTask?.cancel()
        captureStatusTask = Task { @MainActor [weak self, delay] in
            while !Task.isCancelled {
                do {
                    try await delay.sleep(.seconds(1))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled, generation == transitionGeneration else {
                    return
                }
                refreshCaptureStatus()
            }
        }
    }

    /// Writes a level snapshot to `audioLevels`, thinning out pure level changes.
    ///
    /// Every write to an `@Observable` property invalidates the views that read it, and
    /// capture yields one snapshot per audio buffer. The meter is a first-class signal for
    /// a user who cannot hear the input, so anything that changes its *meaning* — speech
    /// detected or not, the VAD label, the observed buffer size — is published immediately.
    /// Only a snapshot that differs by level alone is rate-limited.
    private func publishAudioLevels(_ snapshot: AudioLevelSnapshot) {
        guard snapshot != audioLevels else { return }

        let now = ContinuousClock.now
        let isLevelOnlyChange =
            snapshot.speechDetected == audioLevels.speechDetected
            && snapshot.vadState == audioLevels.vadState
            && snapshot.observedCallbackFrameLength == audioLevels.observedCallbackFrameLength

        if isLevelOnlyChange,
            let lastLevelOnlyPublish,
            now - lastLevelOnlyPublish < Self.levelOnlyPublishInterval
        {
            return
        }

        audioLevels = snapshot
        lastLevelOnlyPublish = now
    }

    /// Capture can start cleanly and still deliver no audio at all, which otherwise shows
    /// up only as a level meter that never moves. Say so rather than looking hung.
    private func startSilentCaptureWatchdog(generation: Int) {
        silentCaptureTask?.cancel()
        silentCaptureTask = Task { @MainActor [weak self, delay] in
            try? await delay.sleep(.seconds(3))
            guard let self,
                !Task.isCancelled,
                generation == transitionGeneration,
                store.isRunning,
                !didReceiveAudioSinceStart
            else {
                return
            }

            let inputName = routeManager.currentInputName
            #if os(iOS)
            let warning =
                requestedVoiceProcessingEnabled
                ? """
                No audio is arriving from “\(inputName)”. Try turning off voice \
                processing in Settings, then Stop and Start.
                """
                : "No audio is arriving from “\(inputName)”."
            #else
            let warning = "No audio is arriving from “\(inputName)”."
            #endif
            silentCaptureWarning = warning
            lastError = warning
        }
    }

    private func scheduleFailureStop() {
        transitionGeneration += 1
        let generation = transitionGeneration
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == transitionGeneration { transitionTask = nil }
            }
            await stopActive(cancelAudioRouteRecovery: true)
            guard generation == transitionGeneration, !Task.isCancelled else { return }
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
            // Device identifiers are hashed, which makes a bundle unreadable on its own —
            // there is no way to tell the built-in mic from loopback from a USB interface.
            // The display names are the same strings already shown in the input picker.
            "active_input_name":
                routeManager.currentRouteInputs.first?.name ?? "none",
            "preferred_input_name":
                routeManager.availableInputs
                .first { $0.id == routeManager.preferredInputID }?
                .name ?? "none",
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

    #if os(iOS)
    /// Responds to a phone call, Siri, an alarm, another app taking the microphone, or the
    /// media server restarting.
    ///
    /// Mirrors the macOS `handleAudioInputAvailabilityChange` below: the route manager
    /// reports, `AudioInterruptionPolicy` decides, and this executes. Nothing here inspects
    /// `AVAudioSession` — that is what keeps the decision testable.
    private func handleAudioInterruption(_ event: AudioInterruptionEvent) {
        switch event {
        case .began:
            // Latch it now. `store.isRunning` is still true at this instant; after the
            // teardown it isn't, and the resume decision would read the wrong answer.
            wasRunningBeforeInterruption = store.isRunning
            if store.isRunning {
                speechAnalyzerState = "Interrupted"
                isInterrupted = true
            }

        case .mediaServicesReset:
            // A reset arrives on its own — there is no `.began` to pair with it. Reading
            // only the latched flag here would leave a media-server restart permanently
            // unrecovered, since the flag is still false. It can also land *during* an
            // existing interruption, so neither source of truth alone is enough.
            wasRunningBeforeInterruption = store.isRunning || wasRunningBeforeInterruption
            if wasRunningBeforeInterruption {
                isInterrupted = true
            }

        case .ended:
            break
        }

        let decision = AudioInterruptionPolicy.decision(
            for: event,
            wasRunning: wasRunningBeforeInterruption,
            attempt: interruptionAttempt
        )

        Task { @MainActor [weak self] in
            await self?.diagnostics.record(
                category: "audio_route",
                name: "audio_interruption",
                fields: [
                    "event": Self.diagnosticID(for: event),
                    "was_running": String(self?.wasRunningBeforeInterruption ?? false),
                    "attempt": String(self?.interruptionAttempt ?? 0),
                    "decision": Self.diagnosticID(for: decision),
                ]
            )
        }

        apply(decision)
    }

    private func apply(_ decision: AudioInterruptionPolicy.Decision) {
        switch decision {
        case .hold:
            return

        case .restart:
            scheduleInterruptionRecovery(after: nil)

        case .retry(let delay):
            scheduleInterruptionRecovery(after: delay)

        case .giveUp(let reason):
            interruptionRecoveryTask?.cancel()
            interruptionRecoveryTask = nil
            wasRunningBeforeInterruption = false
            interruptionAttempt = 0
            // Stop the status first, so clearing the interruption lands on Stopped rather
            // than briefly on whatever the dead capture last implied.
            markCaptureStopped()
            isInterrupted = false
            lastError = reason.message
            speechAnalyzerState = "Error"

            Task { @MainActor [weak self] in
                guard let self else { return }
                await stopActive(cancelAudioRouteRecovery: true)
                await diagnostics.record(
                    category: "error",
                    name: "audio_interruption_unrecoverable",
                    fields: ["reason": reason.diagnosticID]
                )
                // The whole point of the feature is that the user is in another app when
                // this happens, so `lastError` alone would go unread. Only give-up posts —
                // one banner per transient blip during a phone call would train them to be
                // swiped away unread, which is worse than sending none.
                await failureNotifier.notifyCaptionsStopped(message: reason.message)
            }
        }
    }

    private func scheduleInterruptionRecovery(after delay: Duration?) {
        interruptionRecoveryTask?.cancel()
        interruptionRecoveryTask = Task { @MainActor [weak self, scheduler = self.delay] in
            if let delay {
                try? await scheduler.sleep(delay)
            }
            guard let self, !Task.isCancelled else { return }

            interruptionAttempt += 1
            let succeeded = await restartAfterInterruption()
            guard !Task.isCancelled else { return }

            if succeeded {
                let recoveredOnAttempt = interruptionAttempt
                wasRunningBeforeInterruption = false
                interruptionAttempt = 0
                isInterrupted = false
                await diagnostics.record(
                    category: "state",
                    name: "audio_interruption_recovered",
                    fields: ["attempt": String(recoveredOnAttempt)]
                )
                return
            }

            // Reactivating commonly fails for a moment while the interrupting app finishes
            // letting go of the session, so a single attempt gives up far too early.
            apply(
                AudioInterruptionPolicy.decisionAfterFailedRestart(
                    attempt: interruptionAttempt
                )
            )
        }
    }

    /// Restarts through the same generation-guarded path a user-initiated Start uses, rather
    /// than a bespoke partial rebuild. That path is already correct about cancellation and
    /// re-entrancy, and that correctness was expensive to arrive at.
    private func restartAfterInterruption() async -> Bool {
        transitionGeneration += 1
        let generation = transitionGeneration
        transitionTask?.cancel()
        transitionTask = nil

        await performStart(
            sourceKind: selectedSourceKind,
            mode: requestedMode,
            generation: generation,
            preserveRunningState: true
        )

        return store.isRunning && activeMode != nil
    }

    private static func diagnosticID(for event: AudioInterruptionEvent) -> String {
        switch event {
        case .began:
            return "began"
        case .ended(let shouldResume):
            return shouldResume ? "ended_should_resume" : "ended_no_resume"
        case .mediaServicesReset:
            return "media_services_reset"
        }
    }

    private static func diagnosticID(
        for decision: AudioInterruptionPolicy.Decision
    ) -> String {
        switch decision {
        case .hold:
            return "hold"
        case .restart:
            return "restart"
        case .retry(let delay):
            return "retry_\(delay)"
        case .giveUp(let reason):
            return "give_up_\(reason.diagnosticID)"
        }
    }
    #endif

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
            )
        else {
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
            )
        {
            configurations = stored
        }
        configurations[inputPortID] = configuration

        if let data = try? JSONEncoder().encode(configurations) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
#endif
