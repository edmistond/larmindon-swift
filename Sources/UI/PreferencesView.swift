import SwiftUI

public struct PreferencesView: View {
    @AppStorage("captionFontSize") private var captionFontSize = defaultCaptionFontSize
    @AppStorage("appearancePreference") private var appearancePreferenceRaw = AppearancePreference.system.rawValue
    @AppStorage("transcriptionSourceKind") private var sourceKindRaw = TranscriptionSourceKind.live.rawValue
    @AppStorage("vadSensitivity") private var vadSensitivityRaw = VADSensitivity.medium.rawValue
    @AppStorage(AudioCaptureBufferFrames.storageKey) private var audioBufferFrameCount = AudioCaptureBufferFrames.defaultValue
    @AppStorage("voiceProcessingEnabled") private var voiceProcessingEnabled = true
    @AppStorage("profanityFilterEnabled") private var profanityFilterEnabled = false
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

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Buffer size")
                        Spacer()
                        Text("\(audioBufferFrameCount) frames")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Slider(
                        value: audioBufferFrameCountBinding,
                        in: Double(AudioCaptureBufferFrames.min)...Double(AudioCaptureBufferFrames.max),
                        step: Double(AudioCaptureBufferFrames.step)
                    )

                    Stepper(
                        "Capture buffer",
                        value: $audioBufferFrameCount,
                        in: AudioCaptureBufferFrames.min...AudioCaptureBufferFrames.max,
                        step: AudioCaptureBufferFrames.step
                    )
                    .labelsHidden()
                }

                Toggle("Voice processing", isOn: $voiceProcessingEnabled)

                Toggle("Filter profanity", isOn: $profanityFilterEnabled)
                Text("Replaces profane words with a milder form. Takes effect the next time captioning starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show debug panel", isOn: $showDebugPanel)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            normalizeAudioBufferFrameCount()
        }
        .onChange(of: audioBufferFrameCount) {
            normalizeAudioBufferFrameCount()
        }
    }

    private var audioBufferFrameCountBinding: Binding<Double> {
        Binding {
            Double(audioBufferFrameCount)
        } set: { newValue in
            audioBufferFrameCount = AudioCaptureBufferFrames.clamped(Int(newValue.rounded()))
        }
    }

    private func normalizeAudioBufferFrameCount() {
        let clamped = AudioCaptureBufferFrames.clamped(audioBufferFrameCount)
        if audioBufferFrameCount != clamped {
            audioBufferFrameCount = clamped
        }
    }
}

private let defaultCaptionFontSize: Double = {
    #if os(macOS)
    return 30
    #else
    return 34
    #endif
}()

#Preview {
    PreferencesView()
        .frame(width: 520, height: 620)
}
