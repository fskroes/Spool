import Darwin
import Foundation

/// The cost of the Spool process, read from the kernel counters. `MetricsStore.recordCost` gets the deltas
/// between two samples. Reading the counters starts no process and touches no file.
public struct CostSample: Equatable, Sendable {
    /// User plus system CPU time of the process since it started.
    public var cpuSeconds: Double
    /// Package idle wakeups since the process started: the wakeups that take the CPU out of idle, as the
    /// "Idle Wake Ups" of Activity Monitor. Not added to the interrupt wakeups: those include them.
    public var wakeups: UInt64
    /// The highest physical footprint of the process since it started (the "Memory" of Activity Monitor).
    public var peakMB: Double

    public init(cpuSeconds: Double, wakeups: UInt64, peakMB: Double) {
        self.cpuSeconds = cpuSeconds
        self.wakeups = wakeups
        self.peakMB = peakMB
    }

    /// The change from `earlier` to `self`, as `recordCost` wants it. A counter that went down (it cannot, but a
    /// wrong sample must not give a negative cost) gives 0. The memory is the peak now, not a delta.
    public func delta(since earlier: CostSample) -> (cpuSeconds: Double, wakeups: Int, peakMB: Double) {
        let cpu = cpuSeconds.isFinite && earlier.cpuSeconds.isFinite ? max(cpuSeconds - earlier.cpuSeconds, 0) : 0
        let wake = wakeups >= earlier.wakeups ? Int(clamping: wakeups - earlier.wakeups) : 0
        return (cpu, wake, peakMB.isFinite ? max(peakMB, 0) : 0)
    }

    /// The counters of this process now: `getrusage` for CPU time, `proc_pid_rusage` (v4) for wakeups and memory.
    /// Nil when the kernel refuses.
    public static func current() -> CostSample? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        let cpu = seconds(usage.ru_utime) + seconds(usage.ru_stime)
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return nil }
        return CostSample(cpuSeconds: cpu, wakeups: info.ri_pkg_idle_wkups,
                          peakMB: Double(info.ri_lifetime_max_phys_footprint) / 1_048_576)
    }
}
