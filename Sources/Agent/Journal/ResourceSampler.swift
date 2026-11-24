import Darwin

enum ResourceSampler {
    struct Sample {
        let cpuNanos: UInt64
        let wakeups: UInt64
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func sample() -> Sample? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }

        let ticks = info.ri_user_time + info.ri_system_time
        return Sample(
            cpuNanos: ticks * UInt64(timebase.numer) / UInt64(timebase.denom),
            wakeups: info.ri_pkg_idle_wkups + info.ri_interrupt_wkups
        )
    }
}
