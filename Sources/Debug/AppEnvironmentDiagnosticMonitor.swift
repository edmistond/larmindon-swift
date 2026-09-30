import Foundation
import OSLog

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
import IOKit.ps
#endif

/// Battery charge and plug state, encoded as diagnostic fields.
///
/// Platform-neutral so the iOS and macOS readers share one encoding. The question it answers
/// is "was the charger keeping up": a falling `battery_percent` next to
/// `battery_state=charging` means the device was drawing more than it was being given, or
/// that heat had throttled charging (compare `thermal_state`).
struct BatteryReading: Equatable {
    enum ChargeState: String {
        case unplugged
        case charging
        case full
        /// On external power but neither charging nor full. macOS reports this while it
        /// holds the charge below 100% to protect the battery; iOS has no equivalent state.
        case pluggedIn = "plugged_in"
        case unknown
    }

    let percent: Int?
    let state: ChargeState

    init(percent: Int?, state: ChargeState) {
        self.percent = percent
        self.state = state
    }

    /// `UIDevice.batteryLevel` is 0...1, or -1 when monitoring is off or the level is unknown.
    init(level: Float, state: ChargeState) {
        self.init(
            percent: level < 0 ? nil : Int((level * 100).rounded()),
            state: state
        )
    }

    var fields: [String: String] {
        [
            "battery_percent": percent.map(String.init) ?? "unknown",
            "battery_state": state.rawValue,
        ]
    }
}

/// Records the context every other diagnostic event needs: whether the app was in the
/// foreground, how close it was to its memory limit, how hot the device was, and whether it
/// was charging.
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
        #if os(iOS)
        // Battery level and state read as unknown until monitoring is on. It stays on for the
        // app's lifetime: the samples and lifecycle events all carry battery fields.
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
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
        // Plugging in, unplugging, and reaching full. Samples only run during a session and
        // only every 30 seconds, so this pins down exactly when the phone went onto a charger.
        observe(
            UIDevice.batteryStateDidChangeNotification,
            category: "resources",
            as: "battery_state_changed"
        )
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
        category: String = "lifecycle",
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
                    category: category,
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

    /// The numbers that explain a disappearance, or a drained battery, after the fact.
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
        // The screen is usually the largest draw during a foreground session, and its cost
        // scales with brightness. Auto-brightness in a sunny car runs far above a meeting room.
        if let screen = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.screen })
            .first
        {
            fields["screen_brightness"] = String(format: "%.2f", screen.brightness)
        }
        #endif

        if let battery = currentBattery() {
            fields.merge(battery.fields) { _, new in new }
        }

        if let energy = ProcessEnergyReading.current() {
            fields.merge(energy.fields) { _, new in new }
        }

        return fields
    }

    #if os(iOS)
    /// iOS reports the level in 5% steps, which is still enough to see a charger losing
    /// ground over a drive.
    private static func currentBattery() -> BatteryReading? {
        let device = UIDevice.current
        let state: BatteryReading.ChargeState
        switch device.batteryState {
        case .unplugged: state = .unplugged
        case .charging: state = .charging
        case .full: state = .full
        case .unknown: state = .unknown
        @unknown default: state = .unknown
        }
        return BatteryReading(level: device.batteryLevel, state: state)
    }
    #elseif os(macOS)
    /// Reads the internal battery through IOKit. Returns nil on a Mac without one, so a
    /// desktop's events carry no battery fields rather than a misleading "unknown".
    private static func currentBattery() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            var percent: Int?
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int,
                maximum > 0
            {
                percent = Int((Double(current) / Double(maximum) * 100).rounded())
            }

            let state: BatteryReading.ChargeState
            if description[kIOPSPowerSourceStateKey] as? String != kIOPSACPowerValue {
                state = .unplugged
            } else if description[kIOPSIsChargingKey] as? Bool == true {
                state = .charging
            } else if description[kIOPSIsChargedKey] as? Bool == true {
                state = .full
            } else {
                state = .pluggedIn
            }
            return BatteryReading(percent: percent, state: state)
        }
        return nil
    }
    #endif

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
