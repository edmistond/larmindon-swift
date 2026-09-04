import SwiftUI
import XCTest
@testable import LarmindonKit

final class UserPreferencesTests: XCTestCase {
    func testStandardAppearancesUseMatchingColorSchemes() {
        XCTAssertEqual(AppTheme.light.colorScheme, .light)
        XCTAssertEqual(AppTheme.dark.colorScheme, .dark)
    }

    func testTintedDarkAppearancesUseDarkColorScheme() {
        XCTAssertEqual(AppTheme.darkBlue.colorScheme, .dark)
        XCTAssertEqual(AppTheme.darkGreen.colorScheme, .dark)
    }

    func testTintedDarkAppearancesHaveCustomBackgrounds() {
        XCTAssertNotNil(AppTheme.darkBlue.customBackgroundColor)
        XCTAssertNotNil(AppTheme.darkBlue.customControlBackgroundColor)
        XCTAssertNotNil(AppTheme.darkGreen.customBackgroundColor)
        XCTAssertNotNil(AppTheme.darkGreen.customControlBackgroundColor)
    }

    func testThemesCanBeFilteredByColorScheme() {
        XCTAssertEqual(AppTheme.themes(for: .light), [.light, .rosePineDawn])
        XCTAssertEqual(
            AppTheme.themes(for: .dark),
            [.dark, .darkBlue, .darkGreen, .rosePine, .rosePineMoon]
        )
    }

    func testRosePineThemesUseCanonicalAppearancesAndPaletteRoles() {
        XCTAssertEqual(AppTheme.rosePine.colorScheme, .dark)
        XCTAssertEqual(AppTheme.rosePineMoon.colorScheme, .dark)
        XCTAssertEqual(AppTheme.rosePineDawn.colorScheme, .light)

        for theme in [AppTheme.rosePine, .rosePineMoon, .rosePineDawn] {
            XCTAssertNotNil(theme.customBackgroundColor)
            XCTAssertNotNil(theme.customControlBackgroundColor)
            XCTAssertNotNil(theme.customTextColor)
            XCTAssertEqual(theme.speakerAccentColors?.count, 6)
        }
    }

    func testFixedSelectionAlwaysUsesItsThemeAndColorScheme() {
        let selection = ThemeSelection.fixed(.darkBlue)

        XCTAssertEqual(selection.theme(for: .light), .darkBlue)
        XCTAssertEqual(selection.theme(for: .dark), .darkBlue)
        XCTAssertEqual(selection.preferredColorScheme, .dark)
    }

    func testSystemSelectionChoosesItsPairedThemeWithoutForcingAColorScheme() {
        let selection = ThemeSelection.followSystem(light: .light, dark: .darkGreen)

        XCTAssertEqual(selection.theme(for: .light), .light)
        XCTAssertEqual(selection.theme(for: .dark), .darkGreen)
        XCTAssertNil(selection.preferredColorScheme)
    }

    func testLegacySystemAppearanceMigratesToFollowingTheSystem() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("system", forKey: "appearancePreference")

        ThemePreference.migrateLegacySettings(in: defaults)

        XCTAssertEqual(defaults.string(forKey: ThemePreference.modeStorageKey), ThemeSelectionMode.followSystem.rawValue)
        XCTAssertEqual(defaults.string(forKey: ThemePreference.lightThemeStorageKey), AppTheme.light.rawValue)
        XCTAssertEqual(defaults.string(forKey: ThemePreference.darkThemeStorageKey), AppTheme.dark.rawValue)
    }

    func testLegacyConcreteAppearanceMigratesToFixedTheme() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("darkBlue", forKey: "appearancePreference")

        ThemePreference.migrateLegacySettings(in: defaults)

        XCTAssertEqual(defaults.string(forKey: ThemePreference.modeStorageKey), ThemeSelectionMode.fixed.rawValue)
        XCTAssertEqual(defaults.string(forKey: ThemePreference.fixedThemeStorageKey), AppTheme.darkBlue.rawValue)
    }

    func testMigrationDoesNotOverwriteNewThemeSettings() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ThemeSelectionMode.fixed.rawValue, forKey: ThemePreference.modeStorageKey)
        defaults.set(AppTheme.darkGreen.rawValue, forKey: ThemePreference.fixedThemeStorageKey)

        ThemePreference.migrateLegacySettings(in: defaults)

        XCTAssertEqual(defaults.string(forKey: ThemePreference.modeStorageKey), ThemeSelectionMode.fixed.rawValue)
        XCTAssertEqual(defaults.string(forKey: ThemePreference.fixedThemeStorageKey), AppTheme.darkGreen.rawValue)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "UserPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }
}
