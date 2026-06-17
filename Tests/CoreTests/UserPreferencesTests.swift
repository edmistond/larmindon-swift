import SwiftUI
import XCTest
@testable import LarmindonKit

final class UserPreferencesTests: XCTestCase {
    func testSystemAppearanceUsesSystemColorScheme() {
        XCTAssertNil(AppearancePreference.system.colorScheme)
    }

    func testStandardAppearancesUseMatchingColorSchemes() {
        XCTAssertEqual(AppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(AppearancePreference.dark.colorScheme, .dark)
    }

    func testTintedDarkAppearancesUseDarkColorScheme() {
        XCTAssertEqual(AppearancePreference.darkBlue.colorScheme, .dark)
        XCTAssertEqual(AppearancePreference.darkGreen.colorScheme, .dark)
    }

    func testTintedDarkAppearancesHaveCustomBackgrounds() {
        XCTAssertNotNil(AppearancePreference.darkBlue.customBackgroundColor)
        XCTAssertNotNil(AppearancePreference.darkBlue.customControlBackgroundColor)
        XCTAssertNotNil(AppearancePreference.darkGreen.customBackgroundColor)
        XCTAssertNotNil(AppearancePreference.darkGreen.customControlBackgroundColor)
    }
}
