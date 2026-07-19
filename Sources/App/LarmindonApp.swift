import LarmindonKit
import SwiftUI

@main
struct LarmindonApp: App {
    @State private var session = CaptionSession()

    var body: some Scene {
        WindowGroup {
            LarmindonRootView(session: session)
        }

        #if os(macOS)
        Window("Debug", id: LarmindonWindowID.debug) {
            DebugPanelView(session: session)
                .frame(minWidth: 560, idealWidth: 640, minHeight: 620, idealHeight: 720)
        }
        .defaultSize(width: 640, height: 720)

        Settings {
            PreferencesView()
                .frame(minWidth: 520, idealWidth: 600, minHeight: 520, idealHeight: 620)
        }
        #endif
    }
}
