import SwiftUI
import XCTest
@testable import LarmindonKit

final class UserPreferencesTests: XCTestCase {
    func testEveryThemeHasSixSpeakerAccents() {
        for theme in AppTheme.allCases {
            XCTAssertEqual(theme.palette.speakerAccents.count, 6, "\(theme) should have 6 speaker accents")
        }
    }

    func testEveryThemeHasANonEmptyUniqueTitle() {
        let titles = AppTheme.allCases.map(\.title)

        for title in titles {
            XCTAssertFalse(title.isEmpty, "Theme title should not be empty")
        }
        XCTAssertEqual(Set(titles).count, titles.count, "Theme titles should be unique")
    }

    func testStandardThemesDeferToThePlatform() {
        for theme in [AppTheme.light, .dark] {
            let palette = theme.palette
            XCTAssertNil(palette.tint, "\(theme) should use the platform accent color")
            XCTAssertNil(palette.background, "\(theme) should use the platform background")
            XCTAssertNil(palette.controlBackground, "\(theme) should use the platform control material")
            XCTAssertNil(palette.text, "\(theme) should use the platform text color")
        }
    }

    func testCustomThemesPaintTheirOwnSurfaces() {
        for theme in AppTheme.allCases where theme != .light && theme != .dark {
            let palette = theme.palette
            XCTAssertNotNil(palette.background, "\(theme) should set its own background")
            XCTAssertNotNil(palette.controlBackground, "\(theme) should set its own control background")
        }
    }

    func testCustomTextColorRequiresACustomBackground() {
        for theme in AppTheme.allCases {
            let palette = theme.palette
            if palette.text != nil {
                XCTAssertNotNil(palette.background, "\(theme) sets a custom text color but not a background")
            }
        }
    }

    func testThemesCanBeFilteredByColorScheme() {
        XCTAssertEqual(AppTheme.themes(for: .light), [.light, .rosePineDawn, .alucard])
        XCTAssertEqual(
            AppTheme.themes(for: .dark),
            [.dark, .darkBlue, .darkGreen, .rosePine, .rosePineMoon, .dracula]
        )
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
