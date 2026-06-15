import SwiftUI

public struct PreferencesView: View {
    @AppStorage("captionFontSize") private var captionFontSize = defaultCaptionFontSize
    @AppStorage("appearancePreference") private var appearancePreferenceRaw = AppearancePreference.system.rawValue
    @AppStorage("transcriptionSourceKind") private var sourceKindRaw = TranscriptionSourceKind.live.rawValue
    @AppStorage("vadSensitivity") private var vadSensitivityRaw = VADSensitivity.medium.rawValue
    @AppStorage("voiceProcessingEnabled") private var voiceProcessingEnabled = true
    @AppStorage("showDebugPanel") private var showDebugPanel = false

    public init() {}

    public var body: some View {
        Form {
            Section("Caption Text") {
                HStack {
                    Text("Font size")
                    Slider(value: $captionFontSize, in: 20...72, step: 1)
                    Text("\(Int(captionFontSize))")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }

            Section("Appearance") {
                Picker("Mode", selection: $appearancePreferenceRaw) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.title).tag(preference.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Transcription") {
                Picker("Source", selection: $sourceKindRaw) {
                    ForEach(TranscriptionSourceKind.allCases) { source in
                        Text(source.title).tag(source.rawValue)
                    }
                }

                Picker("VAD sensitivity", selection: $vadSensitivityRaw) {
                    ForEach(VADSensitivity.allCases) { sensitivity in
                        Text(sensitivity.title).tag(sensitivity.rawValue)
                    }
                }

                Toggle("Voice processing", isOn: $voiceProcessingEnabled)
                Toggle("Show debug panel", isOn: $showDebugPanel)
            }
        }
        .formStyle(.grouped)
    }
}

private let defaultCaptionFontSize: Double = {
    #if os(macOS)
    return 30
    #else
    return 34
    #endif
}()
