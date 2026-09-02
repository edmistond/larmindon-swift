import AVFAudio
import Foundation

/// Asks for microphone access up front, off the main thread's critical path.
///
/// Without this, the first touch of `AVAudioEngine.inputNode` (or a Core Audio IOProc)
/// raises the system permission prompt from inside a synchronous Core Audio call, and the
/// main thread sits blocked in that call until the prompt is answered. A profile of a
/// frozen session showed exactly that stack, with the prompt itself wedged on screen.
/// `AVAudioApplication` prompts asynchronously, so the UI stays live and a denial can be
/// reported as an error instead of a hang.
enum MicrophonePermission {
    static func ensureGranted() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .denied:
            throw TranscriptionSourceError.unavailable(deniedMessage)
        case .undetermined:
            fallthrough
        @unknown default:
            guard await AVAudioApplication.requestRecordPermission() else {
                throw TranscriptionSourceError.unavailable(deniedMessage)
            }
        }
    }

    private static var deniedMessage: String {
        #if os(macOS)
        "Microphone access is denied. Allow Larmindon in System Settings → Privacy & Security → Microphone, then start again."
        #else
        "Microphone access is denied. Allow Larmindon in Settings → Privacy & Security → Microphone, then start again."
        #endif
    }
}
