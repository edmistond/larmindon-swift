import SwiftUI

public struct PreferencesView: View {
    @AppStorage("captionFontSize") private var captionFontSize = defaultCaptionFontSize
    @AppStorage(ThemePreference.modeStorageKey)
    private var themeSelectionModeRaw = ThemePreference.defaultMode.rawValue
    @AppStorage(ThemePreference.fixedThemeStorageKey)
    private var fixedThemeRaw = ThemePreference.defaultFixedTheme.rawValue
    @AppStorage(ThemePreference.lightThemeStorageKey)
    private var lightThemeRaw = ThemePreference.defaultLightTheme.rawValue
    @AppStorage(ThemePreference.darkThemeStorageKey)
    private var darkThemeRaw = ThemePreference.defaultDarkTheme.rawValue
    @AppStorage("vadSensitivity") private var vadSensitivityRaw = VADSensitivity.medium.rawValue
    @AppStorage(AudioCaptureBufferFrames.storageKey) private var audioBufferFrameCount = AudioCaptureBufferFrames
        .defaultValue
    @AppStorage(VoiceProcessingPreference.storageKey)
    private var voiceProcessingEnabled = VoiceProcessingPreference.defaultValue
    @AppStorage("profanityFilterEnabled") private var profanityFilterEnabled = false
    @AppStorage(SonioxAudioEncoding.storageKey)
    private var sonioxAudioEncodingRaw = SonioxAudioEncoding.defaultValue.rawValue
    @AppStorage(SonioxOpusBitRate.storageKey)
    private var sonioxOpusBitRateRaw = SonioxOpusBitRate.defaultValue.rawValue
    @AppStorage(SonioxFLACSampleRate.storageKey)
    private var sonioxFLACSampleRateRaw = SonioxFLACSampleRate.defaultValue.rawValue
    @AppStorage(TranscriptionPreference.activeServerProviderStorageKey)
    private var activeServerProviderRaw = ServerProviderID.soniox.rawValue

    @State private var sonioxAPIKey = ""
    @State private var hasSonioxCredential = false
    @State private var credentialMessage: String?
    private let credentialStore = KeychainProviderCredentialStore()

    public init() {
        ThemePreference.migrateLegacySettings()
    }

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
                Picker("Theme behavior", selection: $themeSelectionModeRaw) {
                    ForEach(ThemeSelectionMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)

                if themeSelectionMode == .fixed {
                    themePicker("Theme", selection: $fixedThemeRaw, themes: AppTheme.allCases)
                } else {
                    themePicker("Light theme", selection: $lightThemeRaw, themes: AppTheme.themes(for: .light))
                    themePicker("Dark theme", selection: $darkThemeRaw, themes: AppTheme.themes(for: .dark))
                }
            }

            Section("Transcription") {
                Picker("On-device VAD sensitivity", selection: $vadSensitivityRaw) {
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

                #if os(iOS)
                Toggle("Voice processing", isOn: $voiceProcessingEnabled)
                Text(
                    "Uses Apple Voice Processing I/O, including system-managed gain correction. Takes effect the next time capture starts."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                #endif

                Toggle("Filter profanity on device", isOn: $profanityFilterEnabled)
                Text(
                    "Replaces profane words in Apple’s on-device results. Takes effect the next time on-device captioning starts."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Server Transcription") {
                Picker("Provider", selection: $activeServerProviderRaw) {
                    ForEach(ServerProviderID.allCases) { provider in
                        Text(provider.title).tag(provider.rawValue)
                    }
                }

                Picker("Audio upload", selection: $sonioxAudioEncodingRaw) {
                    ForEach(SonioxAudioEncoding.allCases) { encoding in
                        Text(encoding.title).tag(encoding.rawValue)
                    }
                }
                if sonioxAudioEncodingRaw == SonioxAudioEncoding.opus.rawValue {
                    Picker("Opus quality", selection: $sonioxOpusBitRateRaw) {
                        ForEach(SonioxOpusBitRate.allCases) { rate in
                            Text(rate.title).tag(rate.rawValue)
                        }
                    }
                }
                if sonioxAudioEncodingRaw == SonioxAudioEncoding.flac.rawValue {
                    Picker("FLAC sample rate", selection: $sonioxFLACSampleRateRaw) {
                        ForEach(SonioxFLACSampleRate.allCases) { rate in
                            Text(rate.title).tag(rate.rawValue)
                        }
                    }
                }
                Text(
                    "Opus sends a fraction of the data, which matters on cellular. Higher quality keeps more speech detail if captions are less accurate. FLAC sends exactly the uncompressed audio in less data; 24 kHz keeps more high-pitched detail. Takes effect the next time captioning starts."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                SecureField("Soniox API key", text: $sonioxAPIKey)
                    .textContentType(.password)
                    .privacySensitive()

                HStack {
                    Button(hasSonioxCredential ? "Replace Key" : "Save Key") {
                        saveSonioxCredential()
                    }
                    .disabled(
                        sonioxAPIKey.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    )

                    if hasSonioxCredential {
                        Button("Remove Key", role: .destructive) {
                            removeSonioxCredential()
                        }
                    }
                }

                if let credentialMessage {
                    Text(credentialMessage)
                        .font(.caption)
                        .foregroundStyle(
                            hasSonioxCredential
                                ? Color.secondary
                                : Color.red
                        )
                } else {
                    Text(
                        hasSonioxCredential
                            ? "A Soniox key is stored in Keychain. The saved value is never displayed."
                            : "A key is required before Soniox captioning can start."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Text(
                    "The key is sent only in the authorization header when connecting to Soniox. It is not stored in UserDefaults or included in diagnostics."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            normalizeAudioBufferFrameCount()
            refreshCredentialState()
        }
        .onChange(of: audioBufferFrameCount) {
            normalizeAudioBufferFrameCount()
        }
    }

    private var themeSelectionMode: ThemeSelectionMode {
        ThemeSelectionMode(rawValue: themeSelectionModeRaw) ?? ThemePreference.defaultMode
    }

    private func themePicker(
        _ title: String,
        selection: Binding<String>,
        themes: [AppTheme]
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(themes) { theme in
                Text(theme.title).tag(theme.rawValue)
            }
        }
        .pickerStyle(.menu)
    }

    private func saveSonioxCredential() {
        do {
            try credentialStore.saveCredential(
                sonioxAPIKey,
                for: .soniox
            )
            sonioxAPIKey = ""
            hasSonioxCredential = true
            credentialMessage =
                "Key saved. It will be validated on the first Soniox connection."
        } catch {
            refreshCredentialState()
            credentialMessage = error.localizedDescription
        }
    }

    private func removeSonioxCredential() {
        do {
            try credentialStore.removeCredential(for: .soniox)
            sonioxAPIKey = ""
            hasSonioxCredential = false
            credentialMessage = "Soniox key removed."
        } catch {
            credentialMessage = error.localizedDescription
        }
    }

    private func refreshCredentialState() {
        hasSonioxCredential = credentialStore.hasCredential(for: .soniox)
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
