import AVFoundation
import Darwin

/// Monotonic time in nanoseconds on the same clock as `mach_absolute_time`
/// (and therefore `AVAudioTime.hostTime`), so latencies can span subsystems.
public enum MonoClock {
    public static func nowNs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    public static func ns(fromHostTime hostTime: UInt64) -> UInt64 {
        UInt64(AVAudioTime.seconds(forHostTime: hostTime) * 1_000_000_000)
    }

    public static func ms(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? Double(end - start) / 1_000_000 : -Double(start - end) / 1_000_000
    }
}
