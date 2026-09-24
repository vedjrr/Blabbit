import Darwin

/// Monotonic time in nanoseconds on the same clock as `mach_absolute_time`
/// (and therefore `AVAudioTime.hostTime`), so latencies can span subsystems.
/// Pure arithmetic: safe to call from the realtime audio thread.
public enum MonoClock {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    public static func nowNs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// Converts mach host-time ticks to nanoseconds.
    public static func ns(fromHostTime hostTime: UInt64) -> UInt64 {
        let (numer, denom) = timebase
        // Split to avoid overflow: ticks * numer can exceed 64 bits after ~5 days of uptime.
        return (hostTime / denom) * numer + (hostTime % denom) * numer / denom
    }

    public static func ms(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? Double(end - start) / 1_000_000 : -Double(start - end) / 1_000_000
    }
}
