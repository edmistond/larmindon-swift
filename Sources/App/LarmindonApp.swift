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
                // Opens the durable event store, records this launch, prunes aged-out rows,
                // and reports any previous session that never recorded an end — which is
                // how a background kill becomes visible at all.
                .task {
                    await session.diagnostics.activatePersistence()
                }
        }
        #if os(macOS)
        .commands {
            TranscriptCommands(session: session)
        }
        #endif

        #if os(macOS)
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
