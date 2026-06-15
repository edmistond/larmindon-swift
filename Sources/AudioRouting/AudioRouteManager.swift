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

    public init(id: String, name: String, kind: String) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

@MainActor
@Observable
public final class AudioRouteManager {
    public private(set) var currentInputName = "Unknown"
    public private(set) var preferredInputName: String?
    public private(set) var availableInputs: [AudioRoutePort] = []
    public private(set) var currentRouteInputs: [AudioRoutePort] = []
    public private(set) var currentRouteOutputs: [AudioRoutePort] = []

    public init() {
        refresh()
        observeRouteChanges()
    }

    public func configureForCapture() async throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setActive(true, options: [])
        #endif
        refresh()
    }

    public func refresh() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        availableInputs = (session.availableInputs ?? []).map(AudioRoutePort.init(portDescription:))
        currentRouteInputs = session.currentRoute.inputs.map(AudioRoutePort.init(portDescription:))
        currentRouteOutputs = session.currentRoute.outputs.map(AudioRoutePort.init(portDescription:))
        preferredInputName = session.preferredInput?.portName
        currentInputName = currentRouteInputs.first?.name ?? "Unknown"
        #elseif os(macOS)
        let inputs = MacAudioDeviceProvider.inputDevices()
        let defaultInput = MacAudioDeviceProvider.defaultInputDevice()
        availableInputs = inputs
        preferredInputName = defaultInput?.name
        currentInputName = defaultInput?.name ?? "Unknown"
        currentRouteInputs = defaultInput.map { [$0] } ?? []
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
        do {
            try MacAudioDeviceProvider.setDefaultInputDevice(uid: id)
            preferredInputName = input.name
            refresh()
        } catch {
            print("Failed to set default macOS input: \(error.localizedDescription)")
        }
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
        MacAudioDeviceProvider.observeInputChanges { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }
        #endif
    }
}

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
private enum MacAudioDeviceProvider {
    private static let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

    static func inputDevices() -> [AudioRoutePort] {
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
            .compactMap(routePort)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultInputDevice() -> AudioRoutePort? {
        guard let deviceID = defaultInputDeviceID() else {
            return nil
        }
        return routePort(for: deviceID)
    }

    static func setDefaultInputDevice(uid: String) throws {
        guard let deviceID = inputDevicesWithIDs().first(where: { $0.port.id == uid })?.deviceID else {
            throw TranscriptionSourceError.unavailable("No macOS input device found for \(uid)")
        }

        var mutableDeviceID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            systemObjectID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &mutableDeviceID
        )
        guard status == noErr else {
            throw TranscriptionSourceError.unavailable(
                "Could not set macOS default input device \(uid): \(status)"
            )
        }
    }

    static func observeInputChanges(_ handler: @escaping @Sendable () -> Void) {
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            systemObjectID,
            &defaultInputAddress,
            DispatchQueue.main
        ) { _, _ in
            handler()
        }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            systemObjectID,
            &devicesAddress,
            DispatchQueue.main
        ) { _, _ in
            handler()
        }
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
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr && dataSize > 0
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

        return AudioRoutePort(id: uid, name: name, kind: "CoreAudio")
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
