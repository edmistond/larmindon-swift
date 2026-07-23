import AVFAudio
import Foundation
import Observation

#if os(macOS)
import CoreAudio
#endif

public struct AudioRoutePort: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let systemDeviceID: UInt32?

    public init(id: String, name: String, kind: String, systemDeviceID: UInt32? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.systemDeviceID = systemDeviceID
    }
}

public enum AudioInputAvailabilityChange: Equatable, Sendable {
    case selectedInputRemainsAvailable
    case selectedInputUnavailable(name: String)
}

@MainActor
@Observable
public final class AudioRouteManager {
    public private(set) var currentInputName = "Unknown"
    public private(set) var preferredInputID: String?
    public private(set) var preferredInputName: String?
    public private(set) var preferredInputDeviceID: UInt32?
    public private(set) var availableInputs: [AudioRoutePort] = []
    public private(set) var currentRouteInputs: [AudioRoutePort] = []
    public private(set) var currentRouteOutputs: [AudioRoutePort] = []
    public var onInputAvailabilityChange: (@MainActor @Sendable (AudioInputAvailabilityChange) -> Void)?

    #if os(macOS)
    private var deviceObservation: MacAudioDeviceObservation?
    private var deviceListRefreshTask: Task<Void, Never>?
    #endif

    public init() {
        refresh()
        observeRouteChanges()
    }

    public func configureForCapture(
        configuration: MicrophoneCaptureConfiguration = MicrophoneCaptureConfiguration()
    ) async throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let requestedInputKind = configuration.inputPortID.flatMap { inputPortID in
            availableInputs.first(where: { $0.id == inputPortID })?.kind
        } ?? session.preferredInput?.portType.rawValue
            ?? session.currentRoute.inputs.first?.portType.rawValue
        let policy = IOSAudioSessionCapturePolicy(inputKind: requestedInputKind)

        try session.setCategory(
            policy.category,
            mode: policy.mode,
            options: policy.options
        )
        try session.setActive(true, options: [])
        try apply(configuration, to: session)
        if session.isInputGainSettable {
            try? session.setInputGain(1)
        }
        refresh()
        #else
        try await configureForInputSelection(configuration: configuration)
        #endif
    }

    public func configureForInputSelection(
        configuration: MicrophoneCaptureConfiguration = MicrophoneCaptureConfiguration()
    ) async throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setActive(true, options: [])
        try apply(configuration, to: session)
        if session.isInputGainSettable {
            try? session.setInputGain(1)
        }
        #endif
        refresh()

        #if os(macOS)
        if preferredInputID != nil, preferredInputDeviceID == nil {
            throw MacAudioRouteConfigurationError.selectedInputUnavailable
        }
        #endif
    }

    public func releaseAudioSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            print("Failed to deactivate audio session: \(error.localizedDescription)")
        }
        #endif
        refresh()
    }

    #if os(iOS)
    private func apply(
        _ configuration: MicrophoneCaptureConfiguration,
        to session: AVAudioSession
    ) throws {
        let availableInputs = session.availableInputs ?? []
        let input: AVAudioSessionPortDescription?
        if let configuredPortID = configuration.inputPortID {
            guard let configuredInput = availableInputs.first(where: { $0.uid == configuredPortID }) else {
                throw AudioRouteConfigurationError.inputUnavailable
            }
            try session.setPreferredInput(configuredInput)
            input = configuredInput
        } else {
            input = session.currentRoute.inputs.first ?? session.preferredInput ?? availableInputs.first
        }

        guard let input else {
            if configuration.dataSourceID != nil {
                throw AudioRouteConfigurationError.inputUnavailable
            }
            return
        }

        guard let dataSourceID = configuration.dataSourceID else {
            if input.dataSources != nil {
                try input.setPreferredDataSource(nil)
            }
            return
        }
        guard let source = input.dataSources?.first(where: { $0.dataSourceID.stringValue == dataSourceID }) else {
            throw AudioRouteConfigurationError.dataSourceUnavailable
        }

        if let polarPatternID = configuration.polarPatternID {
            let pattern = AVAudioSession.PolarPattern(rawValue: polarPatternID)
            guard source.supportedPolarPatterns?.contains(pattern) == true else {
                throw AudioRouteConfigurationError.polarPatternUnavailable
            }
            if pattern == .stereo {
                try session.setPreferredInputOrientation(configuration.stereoOrientation.audioSessionValue)
            }
            try source.setPreferredPolarPattern(pattern)
        } else if source.supportedPolarPatterns != nil {
            try source.setPreferredPolarPattern(nil)
        }

        try input.setPreferredDataSource(source)
    }
    #endif

    public func refresh() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        availableInputs = (session.availableInputs ?? []).map(AudioRoutePort.init(portDescription:))
        currentRouteInputs = session.currentRoute.inputs.map(AudioRoutePort.init(portDescription:))
        currentRouteOutputs = session.currentRoute.outputs.map(AudioRoutePort.init(portDescription:))
        preferredInputID = session.preferredInput?.uid
        preferredInputName = session.preferredInput?.portName
        preferredInputDeviceID = nil
        currentInputName = currentRouteInputs.first?.name ?? preferredInputName ?? "Unknown"
        #elseif os(macOS)
        let inputs = MacAudioDeviceProvider.inputDevices()
        let defaultInput = MacAudioDeviceProvider.defaultInputDevice()
        availableInputs = inputs
        if let preferredInputID,
           let preferredInput = inputs.first(where: { $0.id == preferredInputID }) {
            preferredInputDeviceID = preferredInput.systemDeviceID
            preferredInputName = preferredInput.name
            currentInputName = preferredInput.name
            currentRouteInputs = [preferredInput]
        } else if preferredInputID != nil {
            preferredInputDeviceID = nil
            currentInputName = "Unavailable"
            currentRouteInputs = []
        } else {
            preferredInputID = defaultInput?.id
            preferredInputDeviceID = defaultInput?.systemDeviceID
            preferredInputName = defaultInput?.name
            currentInputName = defaultInput?.name ?? "Unknown"
            currentRouteInputs = defaultInput.map { [$0] } ?? []
        }
        currentRouteOutputs = []
        #endif
    }

    public func setPreferredInput(id: String) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        guard let input = session.availableInputs?.first(where: { $0.uid == id }) else {
            return
        }
        do {
            try session.setPreferredInput(input)
            preferredInputName = input.portName
            refresh()
        } catch {
            print("Failed to set preferred input: \(error.localizedDescription)")
        }
        #elseif os(macOS)
        guard let input = availableInputs.first(where: { $0.id == id }) else {
            return
        }
        preferredInputID = input.id
        preferredInputName = input.name
        preferredInputDeviceID = input.systemDeviceID
        currentInputName = input.name
        currentRouteInputs = [input]
        #endif
    }

    public func dumpRouteInfoToConsole() {
        refresh()
        print("Larmindon route info")
        print("Current input: \(currentInputName)")
        print("Preferred input: \(preferredInputName ?? "None")")
        print("Available inputs: \(availableInputs)")
        print("Current route inputs: \(currentRouteInputs)")
        print("Current route outputs: \(currentRouteOutputs)")
    }

    private func observeRouteChanges() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        #elseif os(macOS)
        deviceObservation = MacAudioDeviceObservation { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleDeviceListRefresh()
            }
        }
        #endif
    }

    #if os(macOS)
    private func scheduleDeviceListRefresh() {
        deviceListRefreshTask?.cancel()
        deviceListRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            handleDeviceListChange()
        }
    }

    private func handleDeviceListChange() {
        let selectedInputID = preferredInputID
        let selectedInputName = preferredInputName ?? "Unknown"
        let inputs = MacAudioDeviceProvider.inputDevices()
        let change = Self.availabilityChange(
            selectedInputID: selectedInputID,
            selectedInputName: selectedInputName,
            availableInputs: inputs
        )

        refresh()
        if let change {
            onInputAvailabilityChange?(change)
        }
    }

    static func availabilityChange(
        selectedInputID: String?,
        selectedInputName: String,
        availableInputs: [AudioRoutePort]
    ) -> AudioInputAvailabilityChange? {
        guard let selectedInputID else { return nil }
        if availableInputs.contains(where: { $0.id == selectedInputID }) {
            return .selectedInputRemainsAvailable
        }
        return .selectedInputUnavailable(name: selectedInputName)
    }
    #endif
}

#if os(iOS)
struct IOSAudioSessionCapturePolicy: Equatable {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions

    init(inputKind: String?) {
        if inputKind == AVAudioSession.Port.bluetoothHFP.rawValue {
            category = .playAndRecord
            mode = .voiceChat
            options = [.allowBluetoothHFP, .defaultToSpeaker]
        } else {
            category = .record
            mode = .measurement
            options = []
        }
    }
}

private enum AudioRouteConfigurationError: LocalizedError {
    case inputUnavailable
    case dataSourceUnavailable
    case polarPatternUnavailable

    var errorDescription: String? {
        switch self {
        case .inputUnavailable:
            "No audio input is available for the requested microphone configuration."
        case .dataSourceUnavailable:
            "The requested microphone position is unavailable for this input."
        case .polarPatternUnavailable:
            "The requested pickup pattern is unavailable for this microphone."
        }
    }
}

private extension MicrophoneStereoOrientation {
    var audioSessionValue: AVAudioSession.StereoOrientation {
        switch self {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        }
    }
}
#endif

#if os(iOS)
private extension AudioRoutePort {
    init(portDescription: AVAudioSessionPortDescription) {
        self.init(
            id: portDescription.uid,
            name: portDescription.portName,
            kind: portDescription.portType.rawValue
        )
    }
}
#endif

#if os(macOS)
private final class MacAudioDeviceObservation: @unchecked Sendable {
    private let listener: AudioObjectPropertyListenerBlock

    init(onChange: @escaping @Sendable () -> Void) {
        listener = { _, _ in onChange() }
        var address = MacAudioDeviceProvider.devicesPropertyAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            listener
        )
        if status != noErr {
            print("Failed to observe macOS audio device changes: \(status)")
        }
    }

    deinit {
        var address = MacAudioDeviceProvider.devicesPropertyAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            listener
        )
    }
}

private enum MacAudioRouteConfigurationError: LocalizedError {
    case selectedInputUnavailable

    var errorDescription: String? {
        "The selected macOS audio input is no longer available. Choose an available input before starting captions."
    }
}

private enum MacAudioDeviceProvider {
    private static let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

    static var devicesPropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func inputDevices() -> [AudioRoutePort] {
        var address = devicesPropertyAddress
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard deviceCount > 0 else {
            return []
        }

        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs
            .filter(isInputDevice)
            .compactMap(routePort)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultInputDevice() -> AudioRoutePort? {
        guard let deviceID = defaultInputDeviceID() else {
            return nil
        }
        return routePort(for: deviceID)
    }

    private static func inputDevicesWithIDs() -> [(deviceID: AudioObjectID, port: AudioRoutePort)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard deviceCount > 0 else {
            return []
        }

        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs
            .filter(isInputDevice)
            .compactMap { deviceID in
                routePort(for: deviceID).map { (deviceID, $0) }
            }
    }

    private static func defaultInputDeviceID() -> AudioObjectID? {
        var deviceID = AudioObjectID(0)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, &deviceID) == noErr,
              deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    private static func isInputDevice(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return false
        }

        guard let rawBufferList = malloc(Int(dataSize)) else {
            return false
        }
        defer {
            free(rawBufferList)
        }
        let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)

        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            audioBufferList
        ) == noErr else {
            return false
        }

        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func routePort(for deviceID: AudioObjectID) -> AudioRoutePort? {
        guard let uid = stringProperty(
            kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal,
            deviceID: deviceID
        ) else {
            return nil
        }

        let name = stringProperty(
            kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal,
            deviceID: deviceID
        ) ?? uid

        return AudioRoutePort(id: uid, name: name, kind: "CoreAudio", systemDeviceID: deviceID)
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        deviceID: AudioObjectID
    ) -> String? {
        var property: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &property) == noErr,
              let property else {
            return nil
        }
        return property.takeUnretainedValue() as String
    }
}
#endif
