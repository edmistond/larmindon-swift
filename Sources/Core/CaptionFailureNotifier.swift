import Foundation

#if os(iOS)
import UserNotifications
#endif

/// Tells the user captions died when they aren't looking at the app.
///
/// Injected into `CaptionSession` so the "did a give-up actually notify?" question is
/// answerable in a unit test, rather than only by backgrounding a real device and waiting
/// for a real phone call.
@MainActor
public protocol CaptionFailureNotifying: AnyObject {
    /// Asks for notification authorization if it hasn't been asked for yet.
    func prepare() async
    func notifyCaptionsStopped(reason: AudioInterruptionFailureReason) async
}

@MainActor
public final class UserNotificationCaptionFailureNotifier: CaptionFailureNotifying {
    /// Repeated failures replace the previous banner instead of stacking. A pocketful of
    /// identical "captions stopped" alerts is noise, and only the latest is true.
    private static let notificationID = "com.davidedmiston.larmindon.captions-stopped"

    private var didRequestAuthorization = false
    private var isAuthorized = false

    public init() {}

    public func prepare() async {
        #if os(iOS)
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true

        do {
            isAuthorized = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            // A denied or failed authorization must never affect capture. The session
            // degrades to reporting through `lastError`, which is visible on return to
            // the app.
            isAuthorized = false
        }
        #endif
    }

    public func notifyCaptionsStopped(reason: AudioInterruptionFailureReason) async {
        #if os(iOS)
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Larmindon"
        content.body = reason.message
        content.sound = .default

        // `trigger: nil` delivers immediately. In the foreground iOS suppresses the banner
        // unless a delegate opts in, which is the behavior we want: the app is on screen,
        // so `lastError` is already showing it.
        let request = UNNotificationRequest(
            identifier: Self.notificationID,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
        #endif
    }
}
