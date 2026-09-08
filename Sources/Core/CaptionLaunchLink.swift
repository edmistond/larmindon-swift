import Foundation

/// Shared by the app and its lightweight widget; never carries provider credentials.
public enum CaptionLaunchLink {
    public static let url = URL(string: "larmindon://captions/start")!

    public static func matches(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme == "larmindon"
            && components.host == "captions"
            && components.path == "/start"
            && components.user == nil && components.password == nil
            && components.port == nil && components.query == nil && components.fragment == nil
    }
}
