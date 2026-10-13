import Foundation

/// The performance budget of an E2E run. A run that misses it fails, so a slow Striple cannot pass.
/// The limits depend on `Animations`: with animations off every frame write also resizes the windows, which
/// costs the test app more time than a move.
public struct PerformanceBudget: Equatable, Sendable {
    /// `--animations on|off` of the runner.
    public enum Animations: String, CaseIterable, Sendable {
        case on, off

        /// Parses the value of `--animations`. Nil for anything else.
        public init?(argument: String) { self.init(rawValue: argument.lowercased()) }
    }

    /// p95 of one frame write (all windows of one frame), from `striple stats`.
    public var frameWriteP95Ms: Double
    /// p95 of Striple's own part of a frame write (the wall time minus the AX time of the slowest app). It does
    /// not depend on how fast the test app answers, so it is the same in both modes.
    public var frameOwnP95Ms: Double
    /// p95 from a command until its first frame is written, from `striple stats`.
    public var commandLatencyP95Ms: Double
    /// p95 from a command to frames that did not change for 250 ms, measured by the runner. The 250 ms are part
    /// of it.
    public var settleP95Ms: Double

    public static let frameOwnP95Ms = 1.0

    /// Animations on: a frame write within one frame at 60 Hz (16 ms), or the scroll stutters. Measured on
    /// 2026-10-13 (docs/E2E.md, Limits): frame write p95 up to 1.14 ms, latency p95 up to 12.4 ms, settle p95 up to
    /// 920 ms.
    public static let animated = PerformanceBudget(frameWriteP95Ms: 16, frameOwnP95Ms: frameOwnP95Ms,
                                                   commandLatencyP95Ms: 16.7, settleP95Ms: 2000)
    /// Animations off: every command is one frame write of the final frames. Measured on 2026-10-13: frame write
    /// p95 up to 10.1 ms, latency p95 up to 10.1 ms, settle p95 up to 580 ms.
    public static let instant = PerformanceBudget(frameWriteP95Ms: 16, frameOwnP95Ms: frameOwnP95Ms,
                                                  commandLatencyP95Ms: 16.7, settleP95Ms: 1000)

    public static func budget(_ animations: Animations) -> PerformanceBudget {
        animations == .on ? animated : instant
    }

    /// What `striple stats` reported. `frameOwnP95` is nil from a Striple that does not report it.
    public struct Stats: Equatable, Sendable {
        public var frameWriteP95: Double
        public var frameOwnP95: Double?
        public var commandLatencyP95: Double
        public var axErrors: Int
        public var framesWritten: Int

        public init(frameWriteP95: Double, frameOwnP95: Double?, commandLatencyP95: Double, axErrors: Int,
                    framesWritten: Int) {
            self.frameWriteP95 = frameWriteP95
            self.frameOwnP95 = frameOwnP95
            self.commandLatencyP95 = commandLatencyP95
            self.axErrors = axErrors
            self.framesWritten = framesWritten
        }
    }

    /// The failures; empty when the run is in the budget. `settleP95` is nil when the runner has no samples.
    /// Every limit is strict: a value equal to it fails.
    public func check(_ s: Stats, settleP95: Double?) -> [String] {
        var failures: [String] = []
        if s.axErrors > 0 { failures.append("AX errors \(s.axErrors), want 0") }
        func over(_ name: String, _ value: Double, _ limit: Double) {
            guard value >= limit else { return }
            failures.append(String(format: "%@ p95 %.2f ms, want < %@ ms", name, value, Self.limit(limit)))
        }
        over("frame write", s.frameWriteP95, frameWriteP95Ms)
        if let own = s.frameOwnP95 {
            over("Striple's part of a frame write", own, frameOwnP95Ms)
        } else {
            failures.append("Striple did not report its part of a frame write")
        }
        over("command latency", s.commandLatencyP95, commandLatencyP95Ms)
        if let settleP95, settleP95 >= settleP95Ms {
            failures.append(String(format: "settle p95 %.0f ms, want < %@ ms", settleP95, Self.limit(settleP95Ms)))
        }
        return failures
    }

    /// `16`, `16.7`, `0.5`: no trailing zeros.
    static func limit(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }

    /// The row of scenario h. SKIP when there is nothing to measure: no frame was written, or no settle was
    /// timed (the strip scenarios did not run). Then the numbers would be zeros and prove nothing.
    /// `settleTimeouts` settles ended at their timeout; their time is in `settleP95` too.
    public func verdict(_ s: Stats, settleP95: Double?, settleTimeouts: Int = 0) -> (result: Report.Result, failures: [String]) {
        var missing: [String] = []
        if s.framesWritten == 0 { missing.append("Striple wrote no frames") }
        if settleP95 == nil { missing.append("no settle was timed") }
        if !missing.isEmpty { return (.skip, ["nothing to measure: " + missing.joined(separator: ", ")]) }
        var failures = check(s, settleP95: settleP95)
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
