import XCTest
@testable import LarmindonKit

#if os(iOS)
import AVFAudio
#elseif os(macOS)
import CoreAudio
#endif

final class MicrophoneCapabilitiesTests: XCTestCase {
    func testKnownPolarPatternsHaveReadableTitles() {
        XCTAssertEqual(MicrophonePolarPattern.omnidirectional.title, "Omnidirectional")
        XCTAssertEqual(MicrophonePolarPattern.cardioid.title, "Cardioid")
        XCTAssertEqual(MicrophonePolarPattern.subcardioid.title, "Subcardioid")
        XCTAssertEqual(MicrophonePolarPattern.stereo.title, "Stereo")
    }

    func testCapabilityItemsUseLabelAsStableDefaultIdentifier() {
        let item = MicrophoneCapabilityItem(label: "Actual channels", value: "2")

        XCTAssertEqual(item.id, "Actual channels")
    }

    func testCapabilitySectionsUseTitleAsStableDefaultIdentifier() {
        let section = MicrophoneCapabilitySection(
            title: "Channels",
            items: [MicrophoneCapabilityItem(label: "Actual", value: "1")]
        )

        XCTAssertEqual(section.id, "Channels")
    }

    func testAutomaticDataSourceAlsoClearsPolarPatternPreference() {
        let configuration = MicrophoneCaptureConfiguration(
            dataSourceID: nil,
            polarPatternID: "Cardioid"
        )

        XCTAssertNil(configuration.polarPatternID)
    }

    func testDataSourceDisplayNameIncludesReportedPosition() {
        let source = MicrophoneDataSourceOption(
            id: "1",
            name: "Built-in Microphone",
            location: "Upper",
            orientation: "Front"
        )

        XCTAssertEqual(source.displayName, "Built-in Microphone — Upper, Front")
    }

    func testMicrophoneConfigurationRoundTripsThroughPersistenceEncoding() throws {
        let configuration = MicrophoneCaptureConfiguration(
            inputPortID: "built-in",
            dataSourceID: "front",
            polarPatternID: "cardioid",
            stereoOrientation: .landscapeLeft
        )

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(MicrophoneCaptureConfiguration.self, from: data)

        XCTAssertEqual(decoded, configuration)
    }

    @MainActor
    func testNewlySelectedInputReplacesAStaleCaptureInput() {
        let staleConfiguration = MicrophoneCaptureConfiguration(
            inputPortID: "built-in",
            dataSourceID: "front",
            polarPatternID: "cardioid"
        )

        let resolvedConfiguration = CaptionSession.resolvedMicrophoneConfiguration(
            inputPortID: "hearing-aid",
            storedConfiguration: staleConfiguration
        )

        XCTAssertEqual(resolvedConfiguration.inputPortID, "hearing-aid")
        XCTAssertNil(resolvedConfiguration.dataSourceID)
        XCTAssertNil(resolvedConfiguration.polarPatternID)
    }

    #if os(iOS)
    func testBuiltInCapturePolicyDoesNotOpenAnOutputOrBluetoothHFPRoute() {
        let policy = IOSAudioSessionCapturePolicy(
            inputKind: AVAudioSession.Port.builtInMic.rawValue,
            voiceProcessingEnabled: false
        )

        XCTAssertEqual(policy.category, .record)
        XCTAssertEqual(policy.mode, .measurement)
        XCTAssertFalse(policy.options.contains(.allowBluetoothHFP))
    }

    func testBluetoothHFPCapturePolicyKeepsBluetoothInputAvailable() {
        let policy = IOSAudioSessionCapturePolicy(
            inputKind: AVAudioSession.Port.bluetoothHFP.rawValue,
            voiceProcessingEnabled: false
        )

        XCTAssertEqual(policy.category, .playAndRecord)
        XCTAssertEqual(policy.mode, .voiceChat)
        XCTAssertTrue(policy.options.contains(.allowBluetoothHFP))
    }

    func testVoiceProcessingUsesFullDuplexVoiceChatPolicy() {
        let policy = IOSAudioSessionCapturePolicy(
            inputKind: AVAudioSession.Port.builtInMic.rawValue,
            voiceProcessingEnabled: true
        )

        XCTAssertEqual(policy.category, .playAndRecord)
        XCTAssertEqual(policy.mode, .voiceChat)
        XCTAssertTrue(policy.options.contains(.allowBluetoothHFP))
        XCTAssertTrue(policy.options.contains(.defaultToSpeaker))
    }
    #endif

    @MainActor
    func testCaptionSessionTracksRequestedVoiceProcessingPreference() {
        let session = CaptionSession(voiceProcessingEnabled: true)

        XCTAssertTrue(session.requestedVoiceProcessingEnabled)
        XCTAssertNil(session.activeVoiceProcessingEnabled)

        session.setVoiceProcessingPreference(false)

        XCTAssertFalse(session.requestedVoiceProcessingEnabled)
        XCTAssertNil(session.activeVoiceProcessingEnabled)
    }

    #if os(macOS)
    @MainActor
    func testRefreshingConnectedMacMicrophoneCapabilitiesDoesNotCrash() {
        let routeManager = AudioRouteManager()
        let monitor = MicrophoneCapabilityMonitor(routeManager: routeManager)

        monitor.refresh()

        XCTAssertTrue(monitor.snapshot != nil || monitor.lastError != nil)
    }

    @MainActor
    func testMacAudioDeviceChangeKeepsSelectedInputByStableUID() {
        let selectedInput = AudioRoutePort(
            id: "selected-device-uid",
            name: "Selected microphone",
            kind: "CoreAudio",
            systemDeviceID: 42
        )

        XCTAssertEqual(
            AudioRouteManager.availabilityChange(
                selectedInputID: selectedInput.id,
                selectedInputName: selectedInput.name,
                availableInputs: [selectedInput]
            ),
            .selectedInputRemainsAvailable
        )
    }

    @MainActor
    func testMacAudioDeviceChangeReportsSelectedInputDisconnection() {
        XCTAssertEqual(
            AudioRouteManager.availabilityChange(
                selectedInputID: "missing-device-uid",
                selectedInputName: "Hearing aid",
                availableInputs: []
            ),
            .selectedInputUnavailable(name: "Hearing aid")
        )
    }

    func testAggregateAndVirtualDevicesUseDirectCoreAudioCapture() {
        XCTAssertEqual(
            MacOSAudioCaptureStrategy.forTransportType(kAudioDeviceTransportTypeAggregate),
            .coreAudioDevice
        )
        XCTAssertEqual(
            MacOSAudioCaptureStrategy.forTransportType(kAudioDeviceTransportTypeVirtual),
            .coreAudioDevice
        )
    }

    func testPhysicalDevicesKeepAudioEngineCapture() {
        XCTAssertEqual(
            MacOSAudioCaptureStrategy.forTransportType(kAudioDeviceTransportTypeBuiltIn),
            .audioEngine
        )
        XCTAssertEqual(
            MacOSAudioCaptureStrategy.forTransportType(kAudioDeviceTransportTypeUSB),
            .audioEngine
        )
    }
    #endif
}
