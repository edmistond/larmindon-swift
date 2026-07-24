import Foundation
import SwiftUI

public enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case darkBlue
    case darkGreen

    public var id: String { rawValue }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        case .darkBlue, .darkGreen:
            return .dark
        }
    }

    public var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        case .darkBlue:
            return "Dark Blue"
        case .darkGreen:
            return "Dark Green"
        }
    }

    public var tintColor: Color {
        switch self {
        case .system, .light, .dark:
            return .accentColor
        case .darkBlue:
            return Color(red: 0.35, green: 0.58, blue: 0.98)
        case .darkGreen:
            return Color(red: 0.34, green: 0.76, blue: 0.49)
        }
    }

    public var customBackgroundColor: Color? {
        switch self {
        case .system, .light, .dark:
            return nil
        case .darkBlue:
            return Color(red: 0.04, green: 0.08, blue: 0.16)
        case .darkGreen:
            return Color(red: 0.03, green: 0.12, blue: 0.08)
        }
    }

    public var customControlBackgroundColor: Color? {
        switch self {
        case .system, .light, .dark:
            return nil
        case .darkBlue:
            return Color(red: 0.07, green: 0.13, blue: 0.24).opacity(0.92)
        case .darkGreen:
            return Color(red: 0.05, green: 0.18, blue: 0.11).opacity(0.92)
        }
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
