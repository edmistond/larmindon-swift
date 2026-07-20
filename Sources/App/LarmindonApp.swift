import LarmindonKit
import SwiftUI

#if os(macOS)
import AppKit
#endif

@main
struct LarmindonApp: App {
    @State private var session = CaptionSession()

    var body: some Scene {
        WindowGroup {
            LarmindonRootView(session: session)
        }
        #if os(macOS)
        .commands {
            TranscriptCommands(session: session)
        }
        #endif

        #if os(macOS)
        Window("Debug", id: LarmindonWindowID.debug) {
            DebugPanelView(session: session)
                .frame(minWidth: 560, idealWidth: 640, minHeight: 620, idealHeight: 720)
        }
        .defaultSize(width: 640, height: 720)

        Window("Microphone", id: LarmindonWindowID.microphone) {
            MicrophonePanelView(session: session)
            .frame(minWidth: 560, idealWidth: 640, minHeight: 620, idealHeight: 760)
        }
        .defaultSize(width: 640, height: 760)

        Settings {
            PreferencesView()
                .frame(minWidth: 520, idealWidth: 600, minHeight: 520, idealHeight: 620)
        }
        #endif
    }
}

#if os(macOS)
private struct TranscriptCommands: Commands {
    let session: CaptionSession

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Copy Full Transcript to Clipboard") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(session.store.fullTranscript, forType: .string)
            }
            .disabled(session.store.fullTranscript.isEmpty)
        }
    }
}
#endif
