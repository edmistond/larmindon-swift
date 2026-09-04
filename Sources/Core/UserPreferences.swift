import Foundation
import SwiftUI

/// Every color a theme contributes, kept together so a theme reads as one literal
/// rather than one arm in each of several switches. Optional surfaces mean "defer to the
/// platform": the Light and Dark themes keep the system accent, background, label color,
/// and translucent control material instead of painting over them.
public struct ThemePalette: Sendable {
    public let title: String
    public let colorScheme: ColorScheme
    /// `nil` uses the platform accent color.
    public let tint: Color?
    /// `nil` uses the platform window background.
    public let background: Color?
    /// `nil` uses `.thinMaterial` behind the capture controls.
    public let controlBackground: Color?
    /// `nil` uses the platform label color.
    public let text: Color?
    /// Speaker-bar colors, assigned per speaker in order and cycled once exhausted.
    public let speakerAccents: [Color]

    public init(
        title: String,
        colorScheme: ColorScheme,
        tint: Color? = nil,
        background: Color? = nil,
        controlBackground: Color? = nil,
        text: Color? = nil,
        speakerAccents: [Color]
    ) {
        self.title = title
        self.colorScheme = colorScheme
        self.tint = tint
        self.background = background
        self.controlBackground = controlBackground
        self.text = text
        self.speakerAccents = speakerAccents
    }
}

public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark
    case darkBlue
    case darkGreen
    case rosePine
    case rosePineMoon
    case rosePineDawn

    public var id: String { rawValue }

    public var title: String { palette.title }

    public var colorScheme: ColorScheme { palette.colorScheme }

    public var palette: ThemePalette {
        switch self {
        case .light:
            return ThemePalette(
                title: "Light",
                colorScheme: .light,
                speakerAccents: [
                    Color(hex: 0x146BD1),
                    Color(hex: 0xD95C0A),
                    Color(hex: 0x148C40),
                    Color(hex: 0xB8267A),
                    Color(hex: 0x6B40C7),
                    Color(hex: 0x008085),
                ]
            )
        case .dark:
            return ThemePalette(
                title: "Dark",
                colorScheme: .dark,
                speakerAccents: Self.darkSpeakerAccents
            )
        case .darkBlue:
            return ThemePalette(
                title: "Dark Blue",
                colorScheme: .dark,
                tint: Color(hex: 0x5994FA),
                background: Color(hex: 0x0A1429),
                controlBackground: Color(hex: 0x12213D).opacity(0.92),
                speakerAccents: Self.darkSpeakerAccents
            )
        case .darkGreen:
            return ThemePalette(
                title: "Dark Green",
                colorScheme: .dark,
                tint: Color(hex: 0x57C27D),
                background: Color(hex: 0x081F14),
                controlBackground: Color(hex: 0x0D2E1C).opacity(0.92),
                speakerAccents: Self.darkSpeakerAccents
            )
        // Canonical values come from the upstream Rosé Pine palette:
        // https://github.com/rose-pine/rose-pine-palette/blob/main/palette.json
        case .rosePine:
            return ThemePalette(
                title: "Rosé Pine",
                colorScheme: .dark,
                tint: Color(hex: 0x31748F),
                background: Color(hex: 0x191724),
                controlBackground: Color(hex: 0x1F1D2E),
                text: Color(hex: 0xE0DEF4),
                speakerAccents: [
                    Color(hex: 0xEB6F92),
                    Color(hex: 0xF6C177),
                    Color(hex: 0xEBBCBA),
                    Color(hex: 0x31748F),
                    Color(hex: 0x9CCFD8),
                    Color(hex: 0xC4A7E7),
                ]
            )
        case .rosePineMoon:
            return ThemePalette(
                title: "Rosé Pine Moon",
                colorScheme: .dark,
                tint: Color(hex: 0x3E8FB0),
                background: Color(hex: 0x232136),
                controlBackground: Color(hex: 0x2A273F),
                text: Color(hex: 0xE0DEF4),
                speakerAccents: [
                    Color(hex: 0xEB6F92),
                    Color(hex: 0xF6C177),
                    Color(hex: 0xEA9A97),
                    Color(hex: 0x3E8FB0),
                    Color(hex: 0x9CCFD8),
                    Color(hex: 0xC4A7E7),
                ]
            )
        case .rosePineDawn:
            return ThemePalette(
                title: "Rosé Pine Dawn",
                colorScheme: .light,
                tint: Color(hex: 0x286983),
                background: Color(hex: 0xFAF4ED),
                controlBackground: Color(hex: 0xFFFAF3),
                text: Color(hex: 0x464261),
                speakerAccents: [
                    Color(hex: 0xB4637A),
                    Color(hex: 0xEA9D34),
                    Color(hex: 0xD7827E),
                    Color(hex: 0x286983),
                    Color(hex: 0x56949F),
                    Color(hex: 0x907AA9),
                ]
            )
        }
    }

    public static func themes(for colorScheme: ColorScheme) -> [AppTheme] {
        allCases.filter { $0.colorScheme == colorScheme }
    }

    /// Shared by every dark theme that doesn't bring its own speaker palette.
    private static let darkSpeakerAccents: [Color] = [
        Color(hex: 0x59A6FF),
        Color(hex: 0xFF943D),
        Color(hex: 0x59CC7A),
        Color(hex: 0xFF6BB3),
        Color(hex: 0xB38CFF),
        Color(hex: 0x40CCD1),
    ]
}

extension Color {
    /// Builds an opaque color from a 24-bit `0xRRGGBB` literal.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

public enum ThemeSelectionMode: String, CaseIterable, Identifiable, Sendable {
    case fixed
    case followSystem

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fixed:
            return "Always use one theme"
        case .followSystem:
            return "Match system appearance"
        }
    }
}

public enum ThemeSelection: Equatable, Sendable {
    case fixed(AppTheme)
    case followSystem(light: AppTheme, dark: AppTheme)

    public func theme(for systemColorScheme: ColorScheme) -> AppTheme {
        switch self {
        case let .fixed(theme):
            return theme
        case let .followSystem(lightTheme, darkTheme):
            return systemColorScheme == .dark ? darkTheme : lightTheme
        }
    }

    public var preferredColorScheme: ColorScheme? {
        switch self {
        case let .fixed(theme):
            return theme.colorScheme
        case .followSystem:
            return nil
        }
    }
}

public enum ThemePreference {
    public static let modeStorageKey = "themeSelectionMode"
    public static let fixedThemeStorageKey = "fixedTheme"
    public static let lightThemeStorageKey = "lightTheme"
    public static let darkThemeStorageKey = "darkTheme"

    public static let defaultMode = ThemeSelectionMode.followSystem
    public static let defaultFixedTheme = AppTheme.dark
    public static let defaultLightTheme = AppTheme.light
    public static let defaultDarkTheme = AppTheme.dark

    private static let legacyAppearanceStorageKey = "appearancePreference"

    public static func migrateLegacySettings(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: modeStorageKey) == nil else { return }

        let legacyValue = defaults.string(forKey: legacyAppearanceStorageKey)
        let legacyTheme = legacyValue.flatMap(AppTheme.init(rawValue:))

        if let legacyTheme {
            defaults.set(ThemeSelectionMode.fixed.rawValue, forKey: modeStorageKey)
            set(legacyTheme.rawValue, forKey: fixedThemeStorageKey, ifMissingIn: defaults)
        } else {
            defaults.set(ThemeSelectionMode.followSystem.rawValue, forKey: modeStorageKey)
        }

        set(defaultLightTheme.rawValue, forKey: lightThemeStorageKey, ifMissingIn: defaults)
        set(defaultDarkTheme.rawValue, forKey: darkThemeStorageKey, ifMissingIn: defaults)
        set(defaultFixedTheme.rawValue, forKey: fixedThemeStorageKey, ifMissingIn: defaults)
    }

    private static func set(_ value: String, forKey key: String, ifMissingIn defaults: UserDefaults) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(value, forKey: key)
    }
}

public enum TranscriptionSourceKind: String, CaseIterable, Identifiable {
    case fake
    case live

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fake:
            return "Fake"
        case .live:
            return "Live"
        }
    }
}

public enum TranscriptionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case onDevice
    case server

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .onDevice:
            return "On-device"
        case .server:
            return "Soniox"
        }
    }
}

public enum ServerProviderID: String, CaseIterable, Identifiable, Codable, Sendable {
    case soniox

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .soniox:
            return "Soniox"
        }
    }
}

public enum TranscriptionPreference {
    public static let modeStorageKey = "transcriptionMode"
    public static let activeServerProviderStorageKey = "activeServerProvider"
}

public enum VADSensitivity: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        }
    }
}

public enum AudioCaptureBufferFrames {
    public static let storageKey = "audioCaptureBufferFrameCount"
    public static let min = 160
    public static let max = 2048
    public static let step = 32
    public static let defaultValue = 768

    public static func clamped(_ value: Int) -> Int {
        Swift.min(max, Swift.max(min, value))
    }
}

public enum VoiceProcessingPreference {
    public static let storageKey = "voiceProcessingEnabled"
    public static let defaultValue = true
}
