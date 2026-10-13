import Foundation

// Local usage and performance metrics. CONTRACT: the types and signatures in this file are fixed.
// Method bodies marked `fatalError("contract")` are for the builders to write.
//
// Rules for everything in this file:
// - Local only. Nothing here opens a socket or sends data anywhere.
// - No window titles, no key presses, no text the user typed. App bundle IDs are allowed.
// - Pure Foundation. No AppKit, no AX, no process start. The store writes plain JSON files only.
// - Recording is cheap: one lock and a few integer or array updates. It never touches the disk.

/// Where a command came from.
public enum CommandSource: String, Codable, CaseIterable, Sendable {
    case hotkey, cli, url, menu, gesture, tab
}

/// Things that happen and are counted, outside commands and friction.
public enum MetricEvent: String, Codable, CaseIterable, Sendable {
    case engineStart = "engine.start"
    case engineStop = "engine.stop"
    case engineRestart = "engine.restart"
    /// The previous run ended without a clean quit (crash, force quit, power loss).
    case uncleanExit = "unclean.exit"
    /// The engine had to rebuild the AX observer of an app.
    case observerRepair = "observer.repair"
    case permissionLost = "permission.lost"
    /// Focus used the public NSRunningApplication.activate path, not the fast path.
    case focusFallback = "focus.fallback"
    case configError = "config.error"
    /// macOS refused to register a shortcut (another app has it).
    case hotkeyRefused = "hotkey.refused"
    /// An app stopped answering AX calls in time.
    case staleApp = "stale.app"
    case swipe
    case fling
    case mark
}

/// Signs that Striple did something the user or an app did not want. Counted per app bundle ID.
public enum FrictionKind: String, Codable, CaseIterable, Sendable {
    /// The app moved or resized a tiled window and Striple put it back.
    case appCorrection = "app.correction"
    /// The user resized a tiled window with the mouse after Striple placed it.
    case userResize = "user.resize"
    /// The user dragged a tiled window after Striple placed it.
    case userDrag = "user.drag"
    /// toggle-float on a tiled window: Striple should maybe not tile this app.
    case floatTiled = "float.tiled"
    /// toggle-float on a window that a rule or the smart check floated: it should maybe tile.
    case unfloatAuto = "unfloat.auto"
    /// wider, narrower or cycle-width within `MetricsStore.earlyResizeWindow` seconds after the window opened.
    case earlyResize = "early.resize"
    /// focus-left then focus-right (or up then down, and the reverse) within `MetricsStore.bounceWindow` seconds.
    case focusBounce = "focus.bounce"
}

/// Counts of samples in fixed buckets. Two histograms with the same buckets merge by adding.
/// Values are milliseconds. A value lands in the first bucket whose upper bound is >= the value;
/// values above the last bound land in the overflow bucket.
public struct Histogram: Codable, Equatable, Sendable {
    /// Upper bounds in ms, increasing. Fixed for schema 1: changing them is a schema change.
    public static let bounds: [Double] = [
        0.05, 0.1, 0.25, 0.5, 1, 1.5, 2, 3, 4, 5, 6, 8, 10, 12, 16.7, 20, 25, 33.4, 50, 75, 100,
        150, 250, 500, 1000, 2000, 5000,
    ]

    /// `bounds.count + 1` entries; the last one is the overflow bucket.
    public private(set) var counts: [Int]
    public private(set) var count: Int
    public private(set) var sum: Double
    public private(set) var max: Double

    public init() { fatalError("contract") }

    /// Ignores NaN, infinite and negative values.
    public mutating func add(_ ms: Double) { fatalError("contract") }

    public mutating func merge(_ other: Histogram) { fatalError("contract") }

    /// Nearest-rank percentile, `p` in 0...100. Returns the upper bound of the bucket that holds the rank,
    /// capped at `max` (so a single 0.3 ms sample reports 0.3, not 0.5). 0 when empty.
    public func percentile(_ p: Double) -> Double { fatalError("contract") }

    public var mean: Double { fatalError("contract") }

    /// Samples above `ms`. Exact only when `ms` is one of `bounds`.
    public func count(above ms: Double) -> Int { fatalError("contract") }
}

/// Per-app numbers, keyed by bundle ID in `DayMetrics.apps`.
public struct AppMetrics: Codable, Equatable, Sendable {
    /// The AX calls of one window write.
    public var axWrite = Histogram()
    public var axErrors = 0
    /// `FrictionKind.rawValue` to count.
    public var friction: [String: Int] = [:]

    public init() {}

    public mutating func merge(_ other: AppMetrics) { fatalError("contract") }
}

/// Everything measured on one local day. Saved as `<directory>/<day>.json`.
public struct DayMetrics: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schema = DayMetrics.schemaVersion
    /// Local calendar day, `YYYY-MM-DD`.
    public var day: String
    /// Every app version that wrote to this day, sorted.
    public var appVersions: [String] = []

    // Time
    /// Seconds the engine was running (managing windows).
    public var activeSeconds: Double = 0

    // Speed (ms)
    /// One frame write: all windows of one layout tick.
    public var frameWrite = Histogram()
    /// From the start of a command until its first frame is written.
    public var commandLatency = Histogram()
    /// From the start of a command until its animation ends.
    public var commandSettle = Histogram()
    /// Time between two display-link ticks while animating.
    public var tickInterval = Histogram()
    public var ticks = 0
    /// Ticks later than 1.5 times the display period.
    public var slowTicks = 0

    // Cost: added up from deltas at each flush.
    public var cpuSeconds: Double = 0
    /// Process wakeups (interrupt and package idle wakeups).
    public var wakeups = 0
    /// Highest resident memory seen, in MB.
    public var peakRSSMB: Double = 0

    // Reliability and usage
    /// `MetricEvent.rawValue` to count.
    public var events: [String: Int] = [:]
    /// Command metrics name (see `MetricsStore.metricName(for:)`) to source raw value to count.
    public var commands: [String: [String: Int]] = [:]
    /// Columns on a strip, sampled after each layout change: "1" ... "9" and "10+" to count.
    public var columnsPerStrip: [String: Int] = [:]
    /// Bundle ID to per-app numbers.
    public var apps: [String: AppMetrics] = [:]

    public init(day: String) { self.day = day }

    /// Adds `other` into this day. `day` stays; versions are unioned; peakRSSMB takes the max.
    public mutating func merge(_ other: DayMetrics) { fatalError("contract") }

    /// Decodes leniently: a missing field gets its default, so a file from an older build still loads.
    /// A file with a newer `schema` than `schemaVersion` throws `MetricsError.newerSchema`.
    public init(from decoder: Decoder) throws { fatalError("contract") }
}

public enum MetricsError: Error, Equatable {
    case newerSchema(Int)
}

/// Collects metrics in memory and saves one JSON file per local day.
///
/// Thread safe: every method can be called from any thread. Recording never does I/O.
/// The store has no timer. It calls `onFirstChange` once when it goes from saved to unsaved;
/// the owner then schedules one `flush()` (the engine waits 60 s). After a flush the next change calls it again.
public final class MetricsStore: @unchecked Sendable {
    /// Days of files kept by `prune()`.
    public static let defaultRetentionDays = 90
    /// Seconds after a window opened in which a width change counts as `FrictionKind.earlyResize`.
    public static let earlyResizeWindow: TimeInterval = 10
    /// Seconds between two opposite focus moves that count as `FrictionKind.focusBounce`.
    public static let bounceWindow: TimeInterval = 1

    public let directory: URL

    /// `directory` is created at the first flush, not here.
    /// `now` and `calendar` decide the local day; tests inject them.
    /// Loads today's file if there is one, so counts continue after a restart.
    public init(directory: URL, appVersion: String, retentionDays: Int = MetricsStore.defaultRetentionDays,
                calendar: Calendar = .current, now: @escaping @Sendable () -> Date = Date.init) {
        fatalError("contract")
    }

    /// When false, every record call is a no-op and `flush()` writes nothing. Turning it off keeps the files.
    public var isEnabled: Bool {
        get { fatalError("contract") }
        set { fatalError("contract") }
    }

    /// Called (on the recording thread, outside the lock) when the store goes from saved to unsaved.
    public var onFirstChange: (@Sendable () -> Void)? {
        get { fatalError("contract") }
        set { fatalError("contract") }
    }

    public var hasUnsavedChanges: Bool { fatalError("contract") }

    /// `focus-window-<id>` becomes `focus-window`; `focus-index-3` and `move-to-index-3` stay
    /// (there are only nine). Every other name stays as it is.
    public static func metricName(for command: Command) -> String { fatalError("contract") }

    /// `YYYY-MM-DD` of `date` in `calendar` (local day, Gregorian digits, not localized).
    public static func dayKey(_ date: Date, calendar: Calendar) -> String { fatalError("contract") }

    // MARK: Recording. Each one first checks for a new local day (see "Day rollover" below).

    public func record(command: Command, source: CommandSource) { fatalError("contract") }
    public func record(_ event: MetricEvent, count: Int = 1) { fatalError("contract") }
    public func record(_ friction: FrictionKind, bundleID: String) { fatalError("contract") }
    public func recordAXWrite(bundleID: String, ms: Double, failed: Bool) { fatalError("contract") }
    public func recordFrameWrite(ms: Double) { fatalError("contract") }
    public func recordCommandLatency(ms: Double) { fatalError("contract") }
    public func recordCommandSettle(ms: Double) { fatalError("contract") }
    /// `periodMs` is the display period (16.7 at 60 Hz). Above 1.5 times it counts as a slow tick.
    public func recordTick(intervalMs: Double, periodMs: Double) { fatalError("contract") }
    public func recordColumns(_ count: Int) { fatalError("contract") }
    public func recordActive(seconds: Double) { fatalError("contract") }
    /// Deltas since the last call, and the current resident memory.
    public func recordCost(cpuSeconds: Double, wakeups: Int, rssMB: Double) { fatalError("contract") }

    // MARK: Friction helpers. The engine calls these; the store keeps the small state they need.

    /// Call for every focus command. Records `focusBounce` for `bundleID` when this move reverses the
    /// previous one within `bounceWindow`.
    public func noteFocusMove(_ command: Command, bundleID: String?) { fatalError("contract") }
    /// Call for wider, narrower and cycle-width. Records `earlyResize` when the window was created
    /// less than `earlyResizeWindow` seconds before now.
    public func noteWidthChange(bundleID: String, windowCreatedAt: Date) { fatalError("contract") }

    // MARK: Day rollover and files

    /// The day in memory now, as a copy.
    public func snapshot() -> DayMetrics { fatalError("contract") }

    /// Writes the day in memory to `<directory>/<day>.json` (atomic write, sorted keys).
    /// When the local day changed since the last record, the old day is written first and a new day starts.
    /// Merges with a file written by another run of the same day only at `init` (one app runs at a time).
    /// Does nothing when disabled or when nothing changed. Calls `prune()` after a successful write.
    public func flush() throws { fatalError("contract") }

    /// Deletes `YYYY-MM-DD.json` files older than the retention. Never touches other files or folders.
    public func prune() { fatalError("contract") }

    /// Reads the files of the last `days` local days up to and including today, oldest first.
    /// A missing day is skipped. A broken file is skipped and named in `skipped`.
    public static func load(directory: URL, days: Int, calendar: Calendar = .current, now: Date = Date())
        -> (days: [DayMetrics], skipped: [String]) {
        fatalError("contract")
    }

    // MARK: Unclean exit

    /// Writes the `running` marker file in `directory`. Returns true when the marker was already there:
    /// the previous run did not end with `markCleanExit()`. Then it also records `uncleanExit`.
    @discardableResult
    public func markRunning() -> Bool { fatalError("contract") }

    /// Removes the marker. Call at a clean quit, after the last flush.
    public func markCleanExit() { fatalError("contract") }
}

/// A live budget that `striple report` checks. The numbers are the targets in docs/SPEC.md, "Live budget".
public struct MetricsBudget: Codable, Equatable, Sendable {
    public enum Comparison: String, Codable, Sendable { case atMost }

    public var name: String
    public var limit: Double
    public var unit: String
    public var comparison: Comparison

    public init(name: String, limit: Double, unit: String, comparison: Comparison = .atMost) {
        self.name = name
        self.limit = limit
        self.unit = unit
        self.comparison = comparison
    }

    /// frame-write-p95 <= 8 ms, command-latency-p95 <= 16.7 ms, command-settle-p95 <= 400 ms,
    /// slow-tick-ratio <= 1 %, cpu-while-active <= 1 %, unclean-exits <= 0.
    public static let live: [MetricsBudget] = [
        MetricsBudget(name: "frame-write-p95", limit: 8, unit: "ms"),
        MetricsBudget(name: "command-latency-p95", limit: 16.7, unit: "ms"),
        MetricsBudget(name: "command-settle-p95", limit: 400, unit: "ms"),
        MetricsBudget(name: "slow-tick-ratio", limit: 1, unit: "%"),
        MetricsBudget(name: "cpu-while-active", limit: 1, unit: "%"),
        MetricsBudget(name: "unclean-exits", limit: 0, unit: "count"),
    ]
}

/// The summary that `striple report` prints. Built from day files only; the same input gives the same output.
public struct MetricsReport: Codable, Equatable, Sendable {
    public struct BudgetResult: Codable, Equatable, Sendable {
        public var budget: MetricsBudget
        /// Nil when there is no data for it (for example no commands yet).
        public var value: Double?
        /// Nil when `value` is nil.
        public var pass: Bool?
    }

    public struct CommandRow: Codable, Equatable, Sendable {
        public var name: String
        public var total: Int
        /// Source raw value to count.
        public var bySource: [String: Int]
    }

    public struct FrictionRow: Codable, Equatable, Sendable {
        public var bundleID: String
        public var kind: String
        public var count: Int
    }

    public struct AppRow: Codable, Equatable, Sendable {
        public var bundleID: String
        public var writes: Int
        public var axP50: Double
        public var axP95: Double
        public var axErrors: Int
    }

    public var firstDay: String?
    public var lastDay: String?
    public var dayCount: Int
    /// All days merged.
    public var total: DayMetrics
    public var budgets: [BudgetResult]
    /// Most used first; ties by name.
    public var commands: [CommandRow]
    /// Highest count first; ties by bundle ID, then kind.
    public var friction: [FrictionRow]
    /// Slowest axP95 first; ties by bundle ID. Apps with at least 1 write.
    public var slowApps: [AppRow]
    /// Files that could not be read.
    public var skipped: [String]

    public static func make(days: [DayMetrics], skipped: [String] = [], budgets: [MetricsBudget] = MetricsBudget.live)
        -> MetricsReport {
        fatalError("contract")
    }

    /// The text for a terminal: period, active time, budgets (PASS, FAIL or no data), speed percentiles,
    /// cost, reliability events, top 10 commands, top 10 friction rows, 10 slowest apps, skipped files.
    /// Short lines, no colors, no emoji.
    public func renderText() -> String { fatalError("contract") }
}

// MARK: Marks

/// `striple mark` and the Mark shortcut save a bundle that shows the state at a bad moment.
/// Folder: `<metrics directory>/marks/<YYYY-MM-DDTHH-MM-SS>/` (local time; a suffix `-2`, `-3` when it exists).
public enum MetricsMark {
    /// Seconds of engine log kept in a mark.
    public static let logWindow: TimeInterval = 60

    /// The engine log lines from the last `window` seconds before `now`. Log lines start with an ISO 8601 time
    /// with fractional seconds. A line without a time belongs to the line before it.
    public static func logTail(_ log: String, now: Date, window: TimeInterval = logWindow) -> [String] {
        fatalError("contract")
    }

    /// The state with every window title removed (set to an empty string).
    public static func redacted(_ state: EngineState) -> EngineState { fatalError("contract") }

    /// Writes note.txt (the note, can be empty), state.json (redacted), stats.json, day.json (the snapshot)
    /// and engine.log (the tail). Returns the folder. Creates the folders it needs.
    public static func write(note: String, state: EngineState?, stats: EngineStats?, day: DayMetrics?,
                             logLines: [String], marksDirectory: URL, now: Date,
                             calendar: Calendar = .current) throws -> URL {
        fatalError("contract")
    }
}

extension StriplePaths {
    /// `<support>/metrics`
    public static var metricsDirectory: URL { supportDirectory.appendingPathComponent("metrics", isDirectory: true) }
    /// `<support>/metrics/marks`
    public static var marksDirectory: URL { metricsDirectory.appendingPathComponent("marks", isDirectory: true) }
}
