import Foundation

/// The route may be released only after local microphone owners have finished.
/// BackgroundFinishing sources own no capture and drain separately in CaptionSession.
@MainActor
enum CaptionSessionTeardown {
    static func stopLocalResources(
        capture: AudioCaptureSession?,
        source: (any TranscriptionSource)?,
        releaseRoute: () -> Void
    ) async {
        await capture?.stop()
        if let source, !(source is any BackgroundFinishingTranscriptionSource) {
            await source.stop()
        }
        releaseRoute()
    }
}
