import Foundation

/// The performance budget of an E2E run. A run that misses it fails, so a slow Striple cannot pass.
public enum PerformanceBudget {
    /// One frame at 60 Hz. Striple writes the frames of one step in this time, or the scroll stutters.
    public static let frameWriteP95Ms = 16.0
    /// From a command to frames that did not change for 250 ms. The 250 ms are part of it.
    public static let settleP95Ms = 2000.0

    /// The failures; empty when the run is in the budget. `settleP95` is nil when the runner has no samples.
    public static func check(frameWriteP95: Double, settleP95: Double?, axErrors: Int) -> [String] {
        var failures: [String] = []
        if axErrors > 0 { failures.append("AX errors \(axErrors), want 0") }
        if frameWriteP95 >= frameWriteP95Ms {
            failures.append(String(format: "frame write p95 %.2f ms, want < %.0f ms", frameWriteP95, frameWriteP95Ms))
        }
        if let settleP95, settleP95 >= settleP95Ms {
            failures.append(String(format: "settle p95 %.0f ms, want < %.0f ms", settleP95, settleP95Ms))
        }
        return failures
    }

    /// The row of scenario h. SKIP when there is nothing to measure: no frame was written, or no settle was
    /// timed (the strip scenarios did not run). Then the numbers would be zeros and prove nothing.
    /// `settleTimeouts` settles ended at their timeout; their time is in `settleP95` too.
    public static func verdict(frameWriteP95: Double, settleP95: Double?, axErrors: Int, framesWritten: Int,
                               settleTimeouts: Int = 0) -> (result: Report.Result, failures: [String]) {
        var missing: [String] = []
        if framesWritten == 0 { missing.append("Striple wrote no frames") }
        if settleP95 == nil { missing.append("no settle was timed") }
        if !missing.isEmpty { return (.skip, ["nothing to measure: " + missing.joined(separator: ", ")]) }
        var failures = check(frameWriteP95: frameWriteP95, settleP95: settleP95, axErrors: axErrors)
        if settleTimeouts > 0 { failures.append("\(settleTimeouts) settle(s) reached their timeout") }
        return (failures.isEmpty ? .pass : .fail, failures)
    }
}

/// What the runner writes while a run is active, so the next run can stop a test Striple and delete a
/// STRIPLE_HOME that a crashed run left behind. A PID alone is not enough: the system reuses PIDs, so the start
/// time of the process must match too.
public struct E2ERunRecord: Codable, Equatable, Sendable {
    public var home: String
    /// The runner of the run. While it lives, the run is not orphaned: another runner must not touch it.
    public var runnerPID: Int32
    public var runnerStart: String
    public var striplePID: Int32?
    public var stripleStart: String?

    public init(home: String, runnerPID: Int32, runnerStart: String, striplePID: Int32? = nil, stripleStart: String? = nil) {
        self.home = home
        self.runnerPID = runnerPID
        self.runnerStart = runnerStart
        self.striplePID = striplePID
        self.stripleStart = stripleStart
    }

    /// True when the runner of the record still runs (`currentRunnerStart` is the start time of the process now
    /// at `runnerPID`).
    public func runnerIsAlive(currentRunnerStart: String?) -> Bool { currentRunnerStart == runnerStart }

    public static let path = "/tmp/striple/e2e/active-run.json"
    /// The prefix of every STRIPLE_HOME the runner makes (mkdtemp).
    public static let homePrefix = "/tmp/striple-e2e-"

    /// True when the process now at `striplePID` is the test Striple of this record: same PID, same start time.
    public func isOrphan(currentStart: String?) -> Bool {
        guard striplePID != nil, let stripleStart, let currentStart else { return false }
        return stripleStart == currentStart
    }

    /// True when `home` is a folder the runner made, so it may be deleted. Nothing else is ever deleted.
    public var homeIsDeletable: Bool {
        let name = String(home.dropFirst(Self.homePrefix.count))
        return home.hasPrefix(Self.homePrefix) && !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }
}
