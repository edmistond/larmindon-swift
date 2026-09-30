import Darwin
import Foundation

/// This process's own share of the device's work, as cumulative counters since launch.
///
/// Battery level alone can't say how much of a drain was this app: iOS reports it in 5%
/// steps, and the screen, radios and whatever else ran during a drive all draw from the
/// same battery. These counters are the app's alone. Subtracting two samples gives CPU
/// time, wakeups and energy over that interval, so a bundle can show how hard captioning
/// worked instead of inferring it from a thermal state that never moved.
///
/// Reading them is two syscalls, so taking them every sample costs nothing measurable.
struct ProcessEnergyReading: Equatable {
    /// CPU time spent in the app's own code.
    let userCPUMilliseconds: Int
    /// CPU time the kernel spent on the app's behalf: syscalls, I/O, audio and socket work.
    let systemCPUMilliseconds: Int
    /// Times the CPU was woken for this process. Each wakeup pulls a core out of idle,
    /// which costs power beyond the CPU time the work itself takes.
    let wakeups: Int?
    /// The kernel's energy estimate for this process, a raw counter. xnu accounts it in
    /// nanojoules on Apple silicon; treat it as relative until checked against a known
    /// load. Nil where the kernel doesn't provide it (Intel Macs).
    let energy: UInt64?

    var fields: [String: String] {
        var fields = [
            "cpu_user_ms": String(userCPUMilliseconds),
            "cpu_system_ms": String(systemCPUMilliseconds),
        ]
        if let wakeups {
            fields["wakeups"] = String(wakeups)
        }
        if let energy {
            fields["task_energy"] = String(energy)
        }
        return fields
    }

    static func current() -> ProcessEnergyReading? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }

        let power = powerInfo()
        return ProcessEnergyReading(
            userCPUMilliseconds: milliseconds(usage.ru_utime),
            systemCPUMilliseconds: milliseconds(usage.ru_stime),
            wakeups: power.map {
                Int(
                    clamping: $0.cpu_energy.task_interrupt_wakeups
                        + $0.cpu_energy.task_platform_idle_wakeups
                )
            },
            energy: power.flatMap(energy(from:))
        )
    }

    private static func milliseconds(_ time: timeval) -> Int {
        time.tv_sec * 1000 + Int(time.tv_usec) / 1000
    }

    private static func powerInfo() -> task_power_info_v2_data_t? {
        var info = task_power_info_v2_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_power_info_v2_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    private static func energy(from info: task_power_info_v2_data_t) -> UInt64? {
        #if arch(arm64)
        return info.task_energy
        #else
        return nil
        #endif
    }
}
