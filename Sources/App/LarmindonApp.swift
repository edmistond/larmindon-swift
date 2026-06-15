import LarmindonKit
import SwiftUI

@main
struct LarmindonApp: App {
    var body: some Scene {
        WindowGroup {
            LarmindonRootView()
        }

        #if os(macOS)
        Settings {
            PreferencesView()
                .padding()
                .frame(width: 420)
        }
        #endif
    }
}
