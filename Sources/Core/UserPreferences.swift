import Foundation
import SwiftUI

public enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
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
