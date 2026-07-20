import Foundation
import Observation

#if os(iOS)
import AVFAudio
#elseif os(macOS)
import CoreAudio
#endif

public struct MicrophoneCapabilityItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let value: String

    public init(id: String? = nil, label: String, value: String) {
        self.id = id ?? label
        self.label = label
        self.value = value
    }
}

public struct MicrophoneCapabilitySection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let items: [MicrophoneCapabilityItem]

    public init(id: String? = nil, title: String, items: [MicrophoneCapabilityItem]) {
        self.id = id ?? title
        self.title = title
        self.items = items
    }
}

public enum MicrophonePolarPattern: String, Equatable, Sendable {
    case omnidirectional
    case cardioid
    case subcardioid
    case stereo
    case unknown

    public var title: String {
        switch self {
        case .omnidirectional: "Omnidirectional"
        case .cardioid: "Cardioid"
        case .subcardioid: "Subcardioid"
        case .stereo: "Stereo"
        case .unknown: "Unspecified"
        }
    }
}

public struct MicrophoneCapabilitySnapshot: Equatable, Sendable {
    public let inputName: String
    public let inputKind: String
    public let orientation: String?
    public let selectedPattern: MicrophonePolarPattern?
    public let selectedPatternName: String?
    public let sections: [MicrophoneCapabilitySection]
    public let guidance: String

    public init(
        inputName: String,
        inputKind: String,
        orientation: String? = nil,
        selectedPattern: MicrophonePolarPattern? = nil,
        selectedPatternName: String? = nil,
        sections: [MicrophoneCapabilitySection],
        guidance: String
    ) {
        self.inputName = inputName
        self.inputKind = inputKind
        self.orientation = orientation
        self.selectedPattern = selectedPattern
        self.selectedPatternName = selectedPatternName
        self.sections = sections
        self.guidance = guidance
    }
}

@MainActor
@Observable
public final class MicrophoneCapabilityMonitor {
    public private(set) var snapshot: MicrophoneCapabilitySnapshot?
    public private(set) var lastError: String?
    public private(set) var refreshedAt: Date?

    private let routeManager: AudioRouteManager

    public init(routeManager: AudioRouteManager) {
        self.routeManager = routeManager
    }

    public func refresh() {
        routeManager.refresh()

        #if os(iOS)
        snapshot = Self.iOSSnapshot()
        #elseif os(macOS)
        guard let deviceID = routeManager.preferredInputDeviceID else {
            snapshot = nil
            lastError = "No macOS input device is selected."
            refreshedAt = Date()
            return
        }
        snapshot = Self.macOSSnapshot(deviceID: AudioDeviceID(deviceID))
        #endif

        lastError = nil
        refreshedAt = Date()
    }
}

#if os(iOS)
private extension MicrophoneCapabilityMonitor {
    static func iOSSnapshot() -> MicrophoneCapabilitySnapshot {
        let session = AVAudioSession.sharedInstance()
        let input = session.currentRoute.inputs.first ?? session.preferredInput
        let dataSources = input?.dataSources ?? session.inputDataSources ?? []
        let selectedDataSource = input?.selectedDataSource ?? session.inputDataSource
        let preferredDataSource = input?.preferredDataSource
        let selectedPatternName = selectedDataSource?.selectedPolarPattern?.rawValue

        var routeItems = [
            MicrophoneCapabilityItem(label: "Current input", value: input?.portName ?? "No active input"),
            MicrophoneCapabilityItem(label: "Port type", value: input?.portType.rawValue ?? "Unavailable"),
            MicrophoneCapabilityItem(label: "Port UID", value: input?.uid ?? "Unavailable"),
            MicrophoneCapabilityItem(
                label: "Hardware voice processing",
                value: yesNo(input?.hasHardwareVoiceCallProcessing ?? false)
            ),
        ]

        if let bluetooth = input?.bluetoothMicrophoneExtension {
            routeItems.append(
                MicrophoneCapabilityItem(
                    label: "Bluetooth high-quality recording",
                    value: capabilityDescription(bluetooth.highQualityRecording)
                )
            )
            routeItems.append(
                MicrophoneCapabilityItem(
                    label: "Bluetooth far-field capture",
                    value: capabilityDescription(bluetooth.farFieldCapture)
                )
            )
        }

        let dataSourceItems: [MicrophoneCapabilityItem]
        if dataSources.isEmpty {
            dataSourceItems = [
                MicrophoneCapabilityItem(
                    label: "Data sources",
                    value: "Not reported for this route"
                ),
            ]
        } else {
            dataSourceItems = dataSources.flatMap { source in
                let state: String
                if source == selectedDataSource {
                    state = "Active"
                } else if source == preferredDataSource {
                    state = "Requested"
                } else {
                    state = "Available"
                }

                let sourceID = source.dataSourceID.stringValue
                return [
                    MicrophoneCapabilityItem(
                        id: "source-\(sourceID)",
                        label: source.dataSourceName,
                        value: state
                    ),
                    MicrophoneCapabilityItem(
                        id: "source-\(sourceID)-position",
                        label: "  Position",
                        value: positionDescription(source)
                    ),
                    MicrophoneCapabilityItem(
                        id: "source-\(sourceID)-patterns",
                        label: "  Supported patterns",
                        value: patternList(source.supportedPolarPatterns)
                    ),
                    MicrophoneCapabilityItem(
                        id: "source-\(sourceID)-requested",
                        label: "  Requested pattern",
                        value: source.preferredPolarPattern?.rawValue ?? "None"
                    ),
                    MicrophoneCapabilityItem(
                        id: "source-\(sourceID)-active",
                        label: "  Active pattern",
                        value: source.selectedPolarPattern?.rawValue ?? "Not reported"
                    ),
                ]
            }
        }

        let channels = input?.channels ?? []
        var channelItems = [
            MicrophoneCapabilityItem(label: "Actual channels", value: "\(session.inputNumberOfChannels)"),
            MicrophoneCapabilityItem(label: "Maximum channels", value: "\(session.maximumInputNumberOfChannels)"),
            MicrophoneCapabilityItem(label: "Requested channels", value: "\(session.preferredInputNumberOfChannels)"),
        ]
        channelItems.append(contentsOf: channels.map { channel in
            MicrophoneCapabilityItem(
                id: "channel-\(channel.channelNumber)",
                label: "Channel \(channel.channelNumber)",
                value: channel.channelName
            )
        })

        let activeOrientation = stereoOrientationDescription(session.inputOrientation)
        let preferredOrientation = stereoOrientationDescription(session.preferredInputOrientation)
        let orientation = selectedDataSource?.orientation?.rawValue

        return MicrophoneCapabilitySnapshot(
            inputName: input?.portName ?? "No Active Input",
            inputKind: input?.portType.rawValue ?? "iOS audio session",
            orientation: orientation,
            selectedPattern: polarPattern(from: selectedPatternName),
            selectedPatternName: selectedPatternName,
            sections: [
                MicrophoneCapabilitySection(title: "Route", items: routeItems),
                MicrophoneCapabilitySection(title: "Microphone Data Sources", items: dataSourceItems),
                MicrophoneCapabilitySection(title: "Channels", items: channelItems),
                MicrophoneCapabilitySection(
                    title: "Audio Session",
                    items: [
                        MicrophoneCapabilityItem(label: "Category", value: session.category.rawValue),
                        MicrophoneCapabilityItem(label: "Mode", value: session.mode.rawValue),
                        MicrophoneCapabilityItem(label: "Sample rate", value: hertz(session.sampleRate)),
                        MicrophoneCapabilityItem(label: "I/O buffer", value: milliseconds(session.ioBufferDuration)),
                        MicrophoneCapabilityItem(label: "Input latency", value: milliseconds(session.inputLatency)),
                        MicrophoneCapabilityItem(
                            label: "Input gain",
                            value: session.isInputGainSettable
                                ? session.inputGain.formatted(.number.precision(.fractionLength(2)))
                                : "Not settable"
                        ),
                    ]
                ),
                MicrophoneCapabilitySection(
                    title: "Processing and Orientation",
                    items: [
                        MicrophoneCapabilityItem(
                            label: "Echo-cancelled input available",
                            value: yesNo(session.isEchoCancelledInputAvailable)
                        ),
                        MicrophoneCapabilityItem(
                            label: "Echo-cancelled input requested",
                            value: yesNo(session.prefersEchoCancelledInput)
                        ),
                        MicrophoneCapabilityItem(
                            label: "Echo-cancelled input active",
                            value: yesNo(session.isEchoCancelledInputEnabled)
                        ),
                        MicrophoneCapabilityItem(
                            label: "Requested stereo orientation",
                            value: preferredOrientation
                        ),
                        MicrophoneCapabilityItem(label: "Active stereo orientation", value: activeOrientation),
                    ]
                ),
            ],
            guidance: dataSources.isEmpty
                ? "This route does not report selectable microphone data sources. Start captions or select another input, then refresh."
                : "Patterns describe system-provided directivity. They do not imply access to the device's individual physical microphones."
        )
    }

    static func capabilityDescription(_ capability: AVAudioSessionCapability) -> String {
        guard capability.isSupported else { return "Unsupported" }
        return capability.isEnabled ? "Supported, active" : "Supported, inactive"
    }

    static func positionDescription(_ source: AVAudioSessionDataSourceDescription) -> String {
        let location = source.location?.rawValue ?? "unknown location"
        let orientation = source.orientation?.rawValue ?? "unknown orientation"
        return "\(location), \(orientation)"
    }

    static func patternList(_ patterns: [AVAudioSession.PolarPattern]?) -> String {
        guard let patterns, !patterns.isEmpty else { return "Not configurable" }
        return patterns.map(\.rawValue).joined(separator: ", ")
    }

    static func polarPattern(from rawValue: String?) -> MicrophonePolarPattern? {
        guard let rawValue else { return nil }
        let pattern = AVAudioSession.PolarPattern(rawValue: rawValue)
        if pattern == .omnidirectional { return MicrophonePolarPattern.omnidirectional }
        if pattern == .cardioid { return MicrophonePolarPattern.cardioid }
        if pattern == .subcardioid { return MicrophonePolarPattern.subcardioid }
        if pattern == .stereo { return MicrophonePolarPattern.stereo }
        return MicrophonePolarPattern.unknown
    }

    static func stereoOrientationDescription(_ orientation: AVAudioSession.StereoOrientation) -> String {
        switch orientation {
        case .none: "None"
        case .portrait: "Portrait"
        case .portraitUpsideDown: "Portrait upside down"
        case .landscapeRight: "Landscape right"
        case .landscapeLeft: "Landscape left"
        default: "Unknown (\(orientation.rawValue))"
        }
    }

    static func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    static func hertz(_ value: Double) -> String {
        value > 0 ? "\(value.formatted(.number.precision(.fractionLength(0)))) Hz" : "Unavailable"
    }

    static func milliseconds(_ value: TimeInterval) -> String {
        value > 0
            ? "\((value * 1_000).formatted(.number.precision(.fractionLength(1)))) ms"
            : "Unavailable"
    }
}
#endif

#if os(macOS)
private extension MicrophoneCapabilityMonitor {
    static func macOSSnapshot(deviceID: AudioDeviceID) -> MicrophoneCapabilitySnapshot {
        let name = stringProperty(
            deviceID: deviceID,
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal
        ) ?? "Unknown Input"
        let uid = stringProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal
        ) ?? "Unavailable"
        let manufacturer = stringProperty(
            deviceID: deviceID,
            selector: kAudioObjectPropertyManufacturer,
            scope: kAudioObjectPropertyScopeGlobal
        ) ?? "Unavailable"
        let channelCount = inputChannelCount(deviceID: deviceID)
        let dataSources = dataSourceDescriptions(deviceID: deviceID)

        var channelItems = [
            MicrophoneCapabilityItem(label: "Input channels", value: "\(channelCount)"),
        ]
        if channelCount > 0 {
            channelItems.append(contentsOf: (1...channelCount).map { channel in
                let channelName = stringProperty(
                    deviceID: deviceID,
                    selector: kAudioObjectPropertyElementName,
                    scope: kAudioDevicePropertyScopeInput,
                    element: AudioObjectPropertyElement(channel)
                ) ?? "Not reported"
                return MicrophoneCapabilityItem(
                    id: "channel-\(channel)",
                    label: "Channel \(channel)",
                    value: channelName
                )
            })
        }

        return MicrophoneCapabilitySnapshot(
            inputName: name,
            inputKind: "Core Audio device",
            sections: [
                MicrophoneCapabilitySection(
                    title: "Device",
                    items: [
                        MicrophoneCapabilityItem(label: "Name", value: name),
                        MicrophoneCapabilityItem(label: "UID", value: uid),
                        MicrophoneCapabilityItem(label: "Manufacturer", value: manufacturer),
                        MicrophoneCapabilityItem(label: "Device ID", value: "\(deviceID)"),
                        MicrophoneCapabilityItem(
                            label: "Alive",
                            value: booleanProperty(
                                deviceID: deviceID,
                                selector: kAudioDevicePropertyDeviceIsAlive,
                                scope: kAudioObjectPropertyScopeGlobal
                            ).map { $0 ? "Yes" : "No" } ?? "Unavailable"
                        ),
                    ]
                ),
                MicrophoneCapabilitySection(
                    title: "Input Data Sources",
                    items: dataSources.isEmpty
                        ? [MicrophoneCapabilityItem(label: "Data sources", value: "Not reported by driver")]
                        : dataSources
                ),
                MicrophoneCapabilitySection(title: "Channels", items: channelItems),
                MicrophoneCapabilitySection(
                    title: "Hardware Format",
                    items: [
                        MicrophoneCapabilityItem(
                            label: "Nominal sample rate",
                            value: doubleProperty(
                                deviceID: deviceID,
                                selector: kAudioDevicePropertyNominalSampleRate,
                                scope: kAudioObjectPropertyScopeGlobal
                            ).map(hertz) ?? "Unavailable"
                        ),
                        MicrophoneCapabilityItem(
                            label: "Available sample rates",
                            value: availableSampleRates(deviceID: deviceID)
                        ),
                        MicrophoneCapabilityItem(
                            label: "Buffer frame size",
                            value: uint32Property(
                                deviceID: deviceID,
                                selector: kAudioDevicePropertyBufferFrameSize,
                                scope: kAudioObjectPropertyScopeGlobal
                            ).map { "\($0) frames" } ?? "Unavailable"
                        ),
                        MicrophoneCapabilityItem(
                            label: "Buffer frame range",
                            value: valueRangeProperty(
                                deviceID: deviceID,
                                selector: kAudioDevicePropertyBufferFrameSizeRange,
                                scope: kAudioObjectPropertyScopeGlobal
                            ).map { "\(Int($0.mMinimum))–\(Int($0.mMaximum)) frames" } ?? "Unavailable"
                        ),
                        MicrophoneCapabilityItem(
                            label: "Input latency",
                            value: uint32Property(
                                deviceID: deviceID,
                                selector: kAudioDevicePropertyLatency,
                                scope: kAudioDevicePropertyScopeInput
                            ).map { "\($0) frames" } ?? "Unavailable"
                        ),
                        MicrophoneCapabilityItem(
                            label: "Safety offset",
                            value: uint32Property(
                                deviceID: deviceID,
                                selector: kAudioDevicePropertySafetyOffset,
                                scope: kAudioDevicePropertyScopeInput
                            ).map { "\($0) frames" } ?? "Unavailable"
                        ),
                    ]
                ),
            ],
            guidance: channelCount > 1
                ? "Core Audio exposes multiple input channels. This alone does not establish that they are independent physical microphone elements."
                : "Core Audio exposes a single input channel. Any built-in array processing is likely occurring below the app-visible stream."
        )
    }

    static func dataSourceDescriptions(deviceID: AudioDeviceID) -> [MicrophoneCapabilityItem] {
        let dataSources = uint32ArrayProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDataSources,
            scope: kAudioDevicePropertyScopeInput
        )
        let activeDataSources = uint32ArrayProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDataSource,
            scope: kAudioDevicePropertyScopeInput
        )

        return dataSources.map { sourceID in
            let name = dataSourceName(deviceID: deviceID, sourceID: sourceID) ?? "Source \(sourceID)"
            return MicrophoneCapabilityItem(
                id: "source-\(sourceID)",
                label: name,
                value: activeDataSources.contains(sourceID) ? "Active" : "Available"
            )
        }
    }

    static func dataSourceName(deviceID: AudioDeviceID, sourceID: UInt32) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var mutableSourceID = sourceID
        var result: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &mutableSourceID) { sourceIDPointer in
            withUnsafeMutablePointer(to: &result) { resultPointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(sourceIDPointer),
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: UnsafeMutableRawPointer(resultPointer),
                    mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                )
                var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    &translationSize,
                    &translation
                )
            }
        }
        guard status == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }

    static func inputChannelCount(deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              let storage = malloc(Int(dataSize)) else {
            return 0
        }
        defer { free(storage) }

        let bufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return 0
        }
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    static func availableSampleRates(deviceID: AudioDeviceID) -> String {
        let ranges = valueRangeArrayProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyAvailableNominalSampleRates,
            scope: kAudioObjectPropertyScopeGlobal
        )
        guard !ranges.isEmpty else { return "Unavailable" }
        return ranges.map { range in
            if range.mMinimum == range.mMaximum {
                return hertz(range.mMinimum)
            }
            return "\(hertz(range.mMinimum))–\(hertz(range.mMaximum))"
        }.joined(separator: ", ")
    }

    static func stringProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> String? {
        var result: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(deviceID, &address),
              AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &result) == noErr,
              let result else {
            return nil
        }
        return result.takeRetainedValue() as String
    }

    static func booleanProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Bool? {
        uint32Property(deviceID: deviceID, selector: selector, scope: scope).map { $0 != 0 }
    }

    static func uint32Property(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        scalarProperty(deviceID: deviceID, selector: selector, scope: scope, initialValue: UInt32(0))
    }

    static func doubleProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Double? {
        scalarProperty(deviceID: deviceID, selector: selector, scope: scope, initialValue: Double(0))
    }

    static func valueRangeProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> AudioValueRange? {
        scalarProperty(
            deviceID: deviceID,
            selector: selector,
            scope: scope,
            initialValue: AudioValueRange(mMinimum: 0, mMaximum: 0)
        )
    }

    static func scalarProperty<T>(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        initialValue: T
    ) -> T? {
        var value = initialValue
        var dataSize = UInt32(MemoryLayout<T>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bytes.baseAddress!)
        }
        guard status == noErr else { return nil }
        return value
    }

    static func uint32ArrayProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [UInt32] {
        arrayProperty(
            deviceID: deviceID,
            selector: selector,
            scope: scope,
            initialValue: UInt32(0)
        )
    }

    static func valueRangeArrayProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [AudioValueRange] {
        arrayProperty(
            deviceID: deviceID,
            selector: selector,
            scope: scope,
            initialValue: AudioValueRange(mMinimum: 0, mMaximum: 0)
        )
    }

    static func arrayProperty<T>(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        initialValue: T
    ) -> [T] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectHasProperty(deviceID, &address),
              AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<T>.stride
        var values = [T](repeating: initialValue, count: count)
        let status = values.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bytes.baseAddress!)
        }
        guard status == noErr else {
            return []
        }
        return values
    }

    static func hertz(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0)))) Hz"
    }
}
#endif
