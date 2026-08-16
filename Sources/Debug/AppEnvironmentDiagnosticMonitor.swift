import Foundation
import OSLog

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Records the context every other diagnostic event needs: whether the app was in the
/// foreground, how close it was to its memory limit, and how hot the device was.
///
/// Without the lifecycle half, a bundle can't distinguish "captions stopped while I was
/// watching" from "captions stopped twenty minutes into being backgrounded", which is the
/// distinction that matters now that sessions survive backgrounding. Without the resource
/// half, a jetsam kill is indistinguishable from a crash.
@MainActor
public final class AppEnvironmentDiagnosticMonitor {
    /// Holds the notification tokens so they can be removed when the monitor goes away.
    /// A `@MainActor` class gets a nonisolated `deinit`, which can't touch isolated stored
    /// properties — so ownership moves to a box that cleans up in its own deinit instead.
    private final class ObserverBag: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []

        deinit {
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    private let recorder: DiagnosticRecorder
    private var samplingTask: Task<Void, Never>?
    private let observers = ObserverBag()

    /// Frequent enough to catch memory climbing before a kill, rare enough to be free.
    private static let sampleInterval = Duration.seconds(30)

    public init(recorder: DiagnosticRecorder = .shared) {
        self.recorder = recorder
        observeLifecycle()
    }

    deinit {
        samplingTask?.cancel()
    }

    // MARK: - Lifecycle

    private func observeLifecycle() {
        #if os(iOS)
        observe(UIApplication.didEnterBackgroundNotification, as: "did_enter_background") {
            [recorder] in
            // A kill can follow backgrounding with no further warning, so everything
            // buffered goes to disk now rather than on the next batch boundary.
            await recorder.flush()
        }
        observe(UIApplication.willEnterForegroundNotification, as: "will_enter_foreground")
        observe(UIApplication.didBecomeActiveNotification, as: "did_become_active")
        observe(UIApplication.willResignActiveNotification, as: "will_resign_active")
        observe(UIApplication.willTerminateNotification, as: "will_terminate") {
            [recorder] in
            // The one graceful exit iOS tells us about. Its absence on the next launch is
            // what marks a session as killed.
            await recorder.markCleanExit(reason: "will_terminate")
        }
        observe(UIApplication.didReceiveMemoryWarningNotification, as: "memory_warning")
        #elseif os(macOS)
        // macOS can't background-kill the app the way iOS can, but a clean-exit marker is
        // still what distinguishes a normal quit from a crash on the next launch.
        observe(NSApplication.willTerminateNotification, as: "will_terminate") {
            [recorder] in
            await recorder.markCleanExit(reason: "will_terminate")
        }
        observe(NSApplication.didBecomeActiveNotification, as: "did_become_active")
        observe(NSApplication.willResignActiveNotification, as: "will_resign_active")
        #endif
    }

    private func observe(
        _ name: Notification.Name,
        as eventName: String,
        then followUp: (@Sendable () async -> Void)? = nil
    ) {
        let observer = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await recorder.record(
                    category: "lifecycle",
                    name: eventName,
                    fields: Self.resourceFields()
                )
                await followUp?()
            }
        }
        observers.tokens.append(observer)
    }

    // MARK: - Sampling

    /// Sampling runs only while a session is active. Idle sampling would log a flat line and
    /// spend battery to do it.
    public func startSampling() {
        guard samplingTask == nil else { return }
        samplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await recorder.record(
                    category: "resources",
                    name: "sample",
                    fields: Self.resourceFields()
                )
                try? await Task.sleep(for: Self.sampleInterval)
            }
        }
    }

    public func stopSampling() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    /// The numbers that explain a disappearance after the fact.
    static func resourceFields() -> [String: String] {
        var fields: [String: String] = [
            "thermal_state": describe(ProcessInfo.processInfo.thermalState),
            "low_power_mode": String(ProcessInfo.processInfo.isLowPowerModeEnabled),
        ]

        #if os(iOS)
        // How much more this process may allocate before iOS kills it. Watching this fall
        // across a long backgrounded session is the difference between "jetsam" and "no
        // idea what happened".
        fields["available_memory_mb"] = String(os_proc_available_memory() / (1024 * 1024))
        fields["app_state"] = describe(UIApplication.shared.applicationState)
        #endif

        return fields
    }

    private static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    #if os(iOS)
    private static func describe(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
    #endif
}
