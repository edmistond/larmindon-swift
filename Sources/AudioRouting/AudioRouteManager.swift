import AVFAudio
import Foundation
import Observation

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
        currentInputName = "Mac Default Microphone"
        preferredInputName = nil
        availableInputs = []
        currentRouteInputs = [AudioRoutePort(id: "mac-default-input", name: currentInputName, kind: "Default")]
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
        #else
        _ = id
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
