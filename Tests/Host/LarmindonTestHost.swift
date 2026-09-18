import SwiftUI

/// Supplies a real window scene for UIKit/SwiftUI layout tests on iOS.
@main
struct LarmindonTestHost: App {
    var body: some Scene {
        WindowGroup {
            Color.clear
        }
    }
}
