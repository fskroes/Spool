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

    public init() {
        counts = Array(repeating: 0, count: Histogram.bounds.count + 1)
        count = 0
        sum = 0
        max = 0
    }

    /// Ignores NaN, infinite and negative values.
    public mutating func add(_ ms: Double) { insert(ms) }

    public mutating func merge(_ other: Histogram) {
        // Decoded histograms are checked in `LenientHistogram`, so both arrays have the same size.
        for i in 0..<Swift.min(counts.count, other.counts.count) { counts[i] += other.counts[i] }
        count += other.count
        sum += other.sum
        max = Swift.max(max, other.max)
    }

    /// Nearest-rank percentile, `p` in 0...100. Returns the upper bound of the bucket that holds the rank,
    /// capped at `max` (so a single 0.3 ms sample reports 0.3, not 0.5). 0 when empty.
    public func percentile(_ p: Double) -> Double {
        guard count > 0 else { return 0 }
        let q = p.isNaN ? 0 : Swift.min(Swift.max(p, 0), 100)
        // q * count / 100, not q / 100 * count: 95 * 20 / 100 is exactly 19, 0.95 * 20 is not.
        let rank = Swift.max(1, Int((q * Double(count) / 100).rounded(.up)))
        var seen = 0
        for (i, n) in counts.enumerated() {
            seen += n
            if seen >= rank {
                return i < Histogram.bounds.count ? Swift.min(Histogram.bounds[i], max) : max
            }
        }
        return max
    }

    public var mean: Double { count > 0 ? sum / Double(count) : 0 }

    /// Samples above `ms`. Exact only when `ms` is one of `bounds`.
    public func count(above ms: Double) -> Int {
        var n = 0
        for (i, c) in counts.enumerated() where i >= Histogram.bounds.count || Histogram.bounds[i] > ms { n += c }
        return n
    }
}

extension Histogram {
    /// True when `add` keeps the value: finite, not negative, and the sum stays finite (JSON has no infinity).
    func accepts(_ ms: Double) -> Bool { ms >= 0 && ms.isFinite && (sum + ms).isFinite }

    /// `add` that tells whether the value was kept.
    @discardableResult
    mutating func insert(_ ms: Double) -> Bool {
        guard accepts(ms) else { return false }
        counts[Histogram.bucket(for: ms)] += 1
        count += 1
        sum += ms
        if ms > max { max = ms }
        return true
    }

    /// Index of the first bound >= `ms`, or `bounds.count` (the overflow bucket). Binary search.
    static func bucket(for ms: Double) -> Int {
        let b = bounds
        var lo = 0, hi = b.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if b[mid] < ms { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// A histogram from decoded parts. A bad `counts` array gives an empty histogram, because the buckets
    /// cannot be trusted. `count` always is the sum of `counts`.
    init(checking counts: [Int], sum: Double, max: Double) {
        self.init()
        guard counts.count == Histogram.bounds.count + 1, counts.allSatisfy({ $0 >= 0 }) else { return }
        let total = counts.reduce(0, +)
        guard total > 0 else { return }
        self.counts = counts
        self.count = total
        self.sum = sum.isFinite && sum >= 0 ? sum : 0
        self.max = max.isFinite && max >= 0 ? max : 0
    }
}

/// Decodes a `Histogram` leniently and checks it, so a hand-edited or broken file cannot crash `add` or `merge`.
private struct LenientHistogram: Decodable {
    private enum Keys: String, CodingKey { case counts, sum, max }

    var histogram = Histogram()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        histogram = Histogram(checking: c.value(.counts, [Int]()), sum: c.value(.sum, 0.0), max: c.value(.max, 0.0))
    }
}

/// Decodes `AppMetrics` leniently: a missing field gets its default.
private struct LenientApp: Decodable {
    private enum Keys: String, CodingKey { case axWrite, axErrors, friction }

    var app = AppMetrics()

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        app.axWrite = c.value(.axWrite, LenientHistogram()).histogram
        app.axErrors = Swift.max(0, c.value(.axErrors, 0))
        app.friction = c.value(.friction, [String: Int]())
    }
}

/// Per-app numbers, keyed by bundle ID in `DayMetrics.apps`.
public struct AppMetrics: Codable, Equatable, Sendable {
    /// The AX calls of one window write.
    public var axWrite = Histogram()
    public var axErrors = 0
    /// `FrictionKind.rawValue` to count.
    public var friction: [String: Int] = [:]

    public init() {}

    public mutating func merge(_ other: AppMetrics) {
        axWrite.merge(other.axWrite)
        axErrors += other.axErrors
        friction.merge(other.friction, uniquingKeysWith: +)
    }
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
    public mutating func merge(_ other: DayMetrics) {
        appVersions = Set(appVersions).union(other.appVersions).sorted()
        activeSeconds += other.activeSeconds
        frameWrite.merge(other.frameWrite)
        commandLatency.merge(other.commandLatency)
        commandSettle.merge(other.commandSettle)
        tickInterval.merge(other.tickInterval)
        ticks += other.ticks
        slowTicks += other.slowTicks
        cpuSeconds += other.cpuSeconds
        wakeups += other.wakeups
        peakRSSMB = Swift.max(peakRSSMB, other.peakRSSMB)
        events.merge(other.events, uniquingKeysWith: +)
        for (name, bySource) in other.commands {
            commands[name, default: [:]].merge(bySource, uniquingKeysWith: +)
        }
        columnsPerStrip.merge(other.columnsPerStrip, uniquingKeysWith: +)
        for (bundleID, app) in other.apps {
            apps[bundleID, default: AppMetrics()].merge(app)
        }
    }

    /// Decodes leniently: a missing field gets its default, so a file from an older build still loads.
    /// A file with a newer `schema` than `schemaVersion` throws `MetricsError.newerSchema`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = c.value(.schema, DayMetrics.schemaVersion)
        if version > DayMetrics.schemaVersion { throw MetricsError.newerSchema(version) }
        // An older file is read into the current layout, so it is saved with the current schema.
        schema = DayMetrics.schemaVersion
        day = c.value(.day, "")
        appVersions = Set(c.value(.appVersions, [String]())).sorted()
        activeSeconds = Self.amount(c.value(.activeSeconds, 0.0))
        frameWrite = c.value(.frameWrite, LenientHistogram()).histogram
        commandLatency = c.value(.commandLatency, LenientHistogram()).histogram
        commandSettle = c.value(.commandSettle, LenientHistogram()).histogram
        tickInterval = c.value(.tickInterval, LenientHistogram()).histogram
        ticks = Swift.max(0, c.value(.ticks, 0))
        slowTicks = Swift.max(0, c.value(.slowTicks, 0))
        cpuSeconds = Self.amount(c.value(.cpuSeconds, 0.0))
        wakeups = Swift.max(0, c.value(.wakeups, 0))
        peakRSSMB = Self.amount(c.value(.peakRSSMB, 0.0))
        events = c.value(.events, [String: Int]())
        commands = c.value(.commands, [String: [String: Int]]())
        columnsPerStrip = c.value(.columnsPerStrip, [String: Int]())
        apps = c.value(.apps, [String: LenientApp]()).mapValues(\.app)
    }

    /// A finite, not negative amount, else 0.
    private static func amount(_ v: Double) -> Double { v.isFinite && v >= 0 ? v : 0 }
}

public enum MetricsError: Error, Equatable {
    case newerSchema(Int)
}

/// All the logic of `MetricsStore`, as a value without a clock, a lock or files.
/// Every call gets the time from its caller. A call that changes data returns true when it made
/// `needsFlush` go from false to true: then the store calls `onFirstChange`.
struct MetricsAccumulator {
    enum FocusDirection {
        case left, right, up, down

        init?(_ command: Command) {
            switch command {
            case .focusLeft: self = .left
            case .focusRight: self = .right
            case .focusUp: self = .up
            case .focusDown: self = .down
            default: return nil
            }
        }

        var opposite: FocusDirection {
            switch self {
            case .left: return .right
            case .right: return .left
            case .up: return .down
            case .down: return .up
            }
        }
    }

    /// Gregorian, in the time zone of the calendar the store got.
    let calendar: Calendar
    let appVersion: String
    /// Days whose file this run must not replace (newer schema or unreadable at init).
    let protectedDays: Set<String>
    /// The day that records go to.
    private(set) var current: DayMetrics
    /// Older days with changes that are not on disk yet, oldest first. Each day is here at most once.
    private(set) var pending: [DayMetrics] = []
    /// `current` has changes that are not on disk yet.
    private(set) var currentDirty = false
    /// Records with a time in [dayStart, dayEnd) go to `current` without a new day key. Seconds since 2001.
    private var dayStart: Double = 0
    private var dayEnd: Double = 0
    private var lastFocus: (direction: FocusDirection, at: Date)?

    init(day: DayMetrics, appVersion: String, calendar: Calendar, protectedDays: Set<String> = [], now: Date) {
        self.calendar = MetricsStore.gregorian(calendar)
        self.appVersion = appVersion
        self.protectedDays = protectedDays
        current = day
        if !appVersion.isEmpty, !current.appVersions.contains(appVersion) {
            current.appVersions = Set(current.appVersions).union([appVersion]).sorted()
        }
        if MetricsStore.dayKey(now, calendar: self.calendar) == day.day { cacheDay(of: now) }
    }

    /// There are changes that are not on disk yet.
    var needsFlush: Bool { currentDirty || !pending.isEmpty }

    /// Starts a new day when `now` is on a later local day than `current`. The old day goes to `pending` when it
    /// has unsaved changes. The day only moves forward: when the clock goes back (for example a clock correction
    /// just after midnight), records stay on the newer day, so a day already written is never started again
    /// from zero and overwritten.
    mutating func rollOver(now: Date) {
        let t = now.timeIntervalSinceReferenceDate
        if t >= dayStart && t < dayEnd { return }
        let key = MetricsStore.dayKey(now, calendar: calendar)
        if key > current.day {
            if currentDirty { pending.append(current) }
            current = DayMetrics(day: key)
            if !appVersion.isEmpty { current.appVersions = [appVersion] }
            currentDirty = false
        }
        cacheDay(of: now)
    }

    private mutating func cacheDay(of now: Date) {
        if let interval = calendar.dateInterval(of: .day, for: now) {
            dayStart = interval.start.timeIntervalSinceReferenceDate
            dayEnd = interval.end.timeIntervalSinceReferenceDate
        } else {
            dayStart = 0
            dayEnd = 0
        }
    }

    /// Rolls over, then applies `body` to the current day. `body` returns false when it changed nothing.
    @inline(__always)
    private mutating func change(now: Date, _ body: (inout DayMetrics) -> Bool) -> Bool {
        rollOver(now: now)
        let wasDirty = needsFlush
        guard body(&current) else { return false }
        currentDirty = true
        return !wasDirty
    }

    // MARK: Records

    mutating func record(command: Command, source: CommandSource, now: Date) -> Bool {
        let name = MetricsStore.metricName(for: command)
        return change(now: now) { $0.commands[name, default: [:]][source.rawValue, default: 0] += 1; return true }
    }

    mutating func record(_ event: MetricEvent, count: Int, now: Date) -> Bool {
        guard count > 0 else { return false }
        return change(now: now) { $0.events[event.rawValue, default: 0] += count; return true }
    }

    mutating func record(_ friction: FrictionKind, bundleID: String, now: Date) -> Bool {
        change(now: now) { $0.apps[bundleID, default: AppMetrics()].friction[friction.rawValue, default: 0] += 1; return true }
    }

    mutating func recordAXWrite(bundleID: String, ms: Double, failed: Bool, now: Date) -> Bool {
        change(now: now) { day in
            // A failed write still took time, so its time is kept too.
            let timed = day.apps[bundleID, default: AppMetrics()].axWrite.insert(ms)
            if failed { day.apps[bundleID, default: AppMetrics()].axErrors += 1 }
            return timed || failed
        }
    }

    mutating func recordFrameWrite(ms: Double, now: Date) -> Bool {
        change(now: now) { $0.frameWrite.insert(ms) }
    }

    mutating func recordCommandLatency(ms: Double, now: Date) -> Bool {
        change(now: now) { $0.commandLatency.insert(ms) }
    }

    mutating func recordCommandSettle(ms: Double, now: Date) -> Bool {
        change(now: now) { $0.commandSettle.insert(ms) }
    }

    /// A tick with a bad interval (NaN, infinite, negative) is not counted. With a bad period no tick is slow.
    mutating func recordTick(intervalMs: Double, periodMs: Double, now: Date) -> Bool {
        change(now: now) { day in
            guard day.tickInterval.insert(intervalMs) else { return false }
            day.ticks += 1
            if periodMs.isFinite, periodMs > 0, intervalMs > periodMs * 1.5 { day.slowTicks += 1 }
            return true
        }
    }

    private static let columnKeys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10+"]

    mutating func recordColumns(_ count: Int, now: Date) -> Bool {
        guard count >= 1 else { return false }
        let key = MetricsAccumulator.columnKeys[Swift.min(count, 10) - 1]
        return change(now: now) { $0.columnsPerStrip[key, default: 0] += 1; return true }
    }

    mutating func recordActive(seconds: Double, now: Date) -> Bool {
        guard seconds > 0, seconds.isFinite else { return false }
        return change(now: now) { day in
            guard (day.activeSeconds + seconds).isFinite else { return false }
            day.activeSeconds += seconds
            return true
        }
    }

    /// Bad values (NaN, infinite, negative) are left out one by one.
    mutating func recordCost(cpuSeconds: Double, wakeups: Int, rssMB: Double, now: Date) -> Bool {
        change(now: now) { day in
            var changed = false
            if cpuSeconds > 0, (day.cpuSeconds + cpuSeconds).isFinite {
                day.cpuSeconds += cpuSeconds
                changed = true
            }
            if wakeups > 0 {
                day.wakeups += wakeups
                changed = true
            }
            if rssMB.isFinite, rssMB > day.peakRSSMB {
                day.peakRSSMB = rssMB
                changed = true
            }
            return changed
        }
    }

    // MARK: Friction helpers

    /// See `MetricsStore.noteFocusMove`.
    mutating func noteFocusMove(_ command: Command, bundleID: String?, now: Date) -> Bool {
        guard let direction = FocusDirection(command) else {
            lastFocus = nil
            return false
        }
        defer { lastFocus = (direction, now) }
        guard let last = lastFocus, last.direction == direction.opposite, let bundleID else { return false }
        let elapsed = now.timeIntervalSince(last.at)
        guard elapsed >= 0, elapsed <= MetricsStore.bounceWindow else { return false }
        return record(.focusBounce, bundleID: bundleID, now: now)
    }

    mutating func noteWidthChange(bundleID: String, windowCreatedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(windowCreatedAt)
        guard age >= 0, age < MetricsStore.earlyResizeWindow else { return false }
        return record(.earlyResize, bundleID: bundleID, now: now)
    }

    // MARK: Flush

    /// The days to write, oldest first, and marks everything as saved. The caller writes them outside the lock
    /// and calls `restore` with the days it could not write. Changes made during the write make the store unsaved
    /// again, so they call `onFirstChange` as usual. Protected days are dropped here: their file is never replaced.
    mutating func takeFlushBatch(now: Date) -> [DayMetrics] {
        rollOver(now: now)
        var batch = pending
        if currentDirty { batch.append(current) }
        pending = []
        currentDirty = false
        return batch.filter { !protectedDays.contains($0.day) }
    }

    /// Puts back the days that a failed flush did not write. The data in memory is always the full day, so a day
    /// that is still current, or that is in `pending` again, has the newer copy and is only marked unsaved.
    mutating func restore(_ unwritten: [DayMetrics]) -> Bool {
        let wasDirty = needsFlush
        for day in unwritten {
            if day.day == current.day {
                currentDirty = true
            } else if !pending.contains(where: { $0.day == day.day }) {
                pending.append(day)
            }
        }
        pending.sort { $0.day < $1.day }
        return !wasDirty && needsFlush
    }
}

/// Collects metrics in memory and saves one JSON file per local day.
///
/// Thread safe: every method can be called from any thread. Recording never does I/O.
/// The store has no timer. It calls `onFirstChange` once when it goes from saved to unsaved;
/// the owner then schedules one `flush()` (the engine waits 60 s). After a flush the next change calls it again.
///
/// The logic is in `MetricsAccumulator`. This class reads the clock, holds the one lock (an `NSCondition`, so a
/// second `flush()` waits until the first one has written its files), calls `onFirstChange` and does the file I/O.
public final class MetricsStore: @unchecked Sendable {
    /// Days of files kept by `prune()`.
    public static let defaultRetentionDays = 90
    /// Seconds after a window opened in which a width change counts as `FrictionKind.earlyResize`.
    public static let earlyResizeWindow: TimeInterval = 10
    /// Seconds between two opposite focus moves that count as `FrictionKind.focusBounce`.
    public static let bounceWindow: TimeInterval = 1

    public let directory: URL

    private let lock = NSCondition()
    private let clock: @Sendable () -> Date
    private let calendar: Calendar
    private let retentionDays: Int
    // Guarded by `lock`.
    private var state: MetricsAccumulator
    private var enabled = true
    private var firstChange: (@Sendable () -> Void)?
    /// A flush is writing files now.
    private var writing = false

    /// `directory` is created at the first flush, not here.
    /// `now` and `calendar` decide the local day; tests inject them.
    /// Loads today's file if there is one, so counts continue after a restart.
    ///
    /// When today's file has a newer schema (a newer build wrote it) or cannot be read, the store never replaces
    /// it: records of today stay in memory (`snapshot()` shows them) but `flush()` skips that day. The next day
    /// is saved as usual. So a downgrade or a broken file never loses the data that is already on disk.
    public init(directory: URL, appVersion: String, retentionDays: Int = MetricsStore.defaultRetentionDays,
                calendar: Calendar = .current, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.clock = now
        self.calendar = MetricsStore.gregorian(calendar)
        self.retentionDays = retentionDays
        let today = now()
        let key = MetricsStore.dayKey(today, calendar: self.calendar)
        let file = MetricsStore.fileURL(directory: directory, day: key)
        var day = DayMetrics(day: key)
        var protected: Set<String> = []
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                day = try JSONDecoder().decode(DayMetrics.self, from: Data(contentsOf: file))
                day.day = key
            } catch {
                protected.insert(key)
            }
        }
        state = MetricsAccumulator(day: day, appVersion: appVersion, calendar: self.calendar,
                                   protectedDays: protected, now: today)
    }

    /// When false, every record call is a no-op and `flush()` writes nothing. Turning it off keeps the files.
    /// Turning it on again with unsaved data calls `onFirstChange`, so the owner schedules a flush.
    public var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return enabled
        }
        set {
            lock.lock()
            let resume = newValue && !enabled && state.needsFlush
            enabled = newValue
            let callback = resume ? firstChange : nil
            lock.unlock()
            callback?()
        }
    }

    /// Called (on the recording thread, outside the lock) when the store goes from saved to unsaved.
    public var onFirstChange: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return firstChange
        }
        set {
            lock.lock()
            firstChange = newValue
            lock.unlock()
        }
    }

    /// True also while a flush is still writing.
    public var hasUnsavedChanges: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.needsFlush || writing
    }

    /// `focus-window-<id>` becomes `focus-window`; `focus-index-3` and `move-to-index-3` stay
    /// (there are only nine). Every other name stays as it is.
    public static func metricName(for command: Command) -> String {
        if case .focusWindow = command { return "focus-window" }
        return command.name
    }

    /// `YYYY-MM-DD` of `date` in `calendar` (local day, Gregorian digits, not localized).
    /// A calendar that is not Gregorian (for example Buddhist) gives the Gregorian date in its time zone,
    /// so the file names stay the same when the user changes the calendar.
    public static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = gregorian(calendar).dateComponents([.year, .month, .day], from: date)
        return "\(digits(c.year ?? 0, 4))-\(digits(c.month ?? 0, 2))-\(digits(c.day ?? 0, 2))"
    }

    // MARK: Recording. Each one first checks for a new local day (see "Day rollover" below).

    public func record(command: Command, source: CommandSource) {
        update { $0.record(command: command, source: source, now: $1) }
    }

    public func record(_ event: MetricEvent, count: Int = 1) {
        update { $0.record(event, count: count, now: $1) }
    }

    public func record(_ friction: FrictionKind, bundleID: String) {
        update { $0.record(friction, bundleID: bundleID, now: $1) }
    }

    public func recordAXWrite(bundleID: String, ms: Double, failed: Bool) {
        update { $0.recordAXWrite(bundleID: bundleID, ms: ms, failed: failed, now: $1) }
    }

    public func recordFrameWrite(ms: Double) {
        update { $0.recordFrameWrite(ms: ms, now: $1) }
    }

    public func recordCommandLatency(ms: Double) {
        update { $0.recordCommandLatency(ms: ms, now: $1) }
    }

    public func recordCommandSettle(ms: Double) {
        update { $0.recordCommandSettle(ms: ms, now: $1) }
    }

    /// `periodMs` is the display period (16.7 at 60 Hz). Above 1.5 times it counts as a slow tick.
    public func recordTick(intervalMs: Double, periodMs: Double) {
        update { $0.recordTick(intervalMs: intervalMs, periodMs: periodMs, now: $1) }
    }

    /// Counts below 1 are ignored; 10 and more count as "10+".
    public func recordColumns(_ count: Int) {
        update { $0.recordColumns(count, now: $1) }
    }

    public func recordActive(seconds: Double) {
        update { $0.recordActive(seconds: seconds, now: $1) }
    }

    /// Deltas since the last call, and the current resident memory.
    public func recordCost(cpuSeconds: Double, wakeups: Int, rssMB: Double) {
        update { $0.recordCost(cpuSeconds: cpuSeconds, wakeups: wakeups, rssMB: rssMB, now: $1) }
    }

    // MARK: Friction helpers. The engine calls these; the store keeps the small state they need.

    /// Call for every focus command. Records `focusBounce` for `bundleID` when this move reverses the
    /// previous one within `bounceWindow`.
    /// Only focus-left, focus-right, focus-up and focus-down are moves. Any other command clears the previous
    /// move, so left, focus-first, right is not a bounce. Each reversal counts: left, right, left is two bounces.
    /// A nil `bundleID` records nothing but the move is still remembered.
    public func noteFocusMove(_ command: Command, bundleID: String?) {
        update { $0.noteFocusMove(command, bundleID: bundleID, now: $1) }
    }

    /// Call for wider, narrower and cycle-width. Records `earlyResize` when the window was created
    /// less than `earlyResizeWindow` seconds before now.
    public func noteWidthChange(bundleID: String, windowCreatedAt: Date) {
        update { $0.noteWidthChange(bundleID: bundleID, windowCreatedAt: windowCreatedAt, now: $1) }
    }

    /// Reads the clock, then runs `body` under the lock and calls `onFirstChange` after the lock is released.
    @inline(__always)
    private func update(_ body: (inout MetricsAccumulator, Date) -> Bool) {
        let now = clock()
        lock.lock()
        guard enabled else {
            lock.unlock()
            return
        }
        let callback = body(&state, now) ? firstChange : nil
        lock.unlock()
        callback?()
    }

    // MARK: Day rollover and files

    /// The day in memory now, as a copy.
    public func snapshot() -> DayMetrics {
        lock.lock()
        defer { lock.unlock() }
        return state.current
    }

    /// Writes the day in memory to `<directory>/<day>.json` (atomic write, sorted keys).
    /// When the local day changed since the last record, the old day is written first and a new day starts.
    /// Merges with a file written by another run of the same day only at `init` (one app runs at a time).
    /// Does nothing when disabled or when nothing changed. Calls `prune()` after a successful write.
    ///
    /// The files are written outside the lock, so recording never waits for the disk. When a write fails, the
    /// days that were not written stay in memory as unsaved, `onFirstChange` is called (the owner retries later)
    /// and the error is thrown.
    public func flush() throws {
        lock.lock()
        while writing { lock.wait() }
        guard enabled else {
            lock.unlock()
            return
        }
        let batch = state.takeFlushBatch(now: clock())
        guard !batch.isEmpty else {
            lock.unlock()
            return
        }
        writing = true
        lock.unlock()

        var written = 0
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = MetricsStore.encoder()
            for day in batch {
                try encoder.encode(day).write(to: MetricsStore.fileURL(directory: directory, day: day.day), options: .atomic)
                written += 1
            }
        } catch {
            lock.lock()
            let callback = state.restore(Array(batch[written...])) ? firstChange : nil
            writing = false
            lock.broadcast()
            lock.unlock()
            callback?()
            throw error
        }
        lock.lock()
        writing = false
        lock.broadcast()
        lock.unlock()
        prune()
    }

    /// Deletes `YYYY-MM-DD.json` files older than the retention. Never touches other files or folders.
    /// The retention counts today: with 90, today and the 89 days before it stay.
    public func prune() {
        let today = calendar.startOfDay(for: clock())
        guard let oldestKept = calendar.date(byAdding: .day, value: -(Swift.max(retentionDays, 1) - 1), to: today) else { return }
        let cutoff = MetricsStore.dayKey(oldestKept, calendar: calendar)
        for (key, url) in MetricsStore.dayFiles(in: directory) where key < cutoff {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Reads the files of the last `days` local days up to and including today, oldest first.
    /// A missing day is skipped. A broken file is skipped and named in `skipped`.
    public static func load(directory: URL, days: Int, calendar: Calendar = .current, now: Date = Date())
        -> (days: [DayMetrics], skipped: [String]) {
        guard days > 0 else { return ([], []) }
        let calendar = gregorian(calendar)
        let today = calendar.startOfDay(for: now)
        let last = dayKey(today, calendar: calendar)
        // Very large `days` have no first day: then every file up to today is read.
        let first = calendar.date(byAdding: .day, value: -(Swift.min(days, 1_000_000) - 1), to: today)
            .map { dayKey($0, calendar: calendar) } ?? ""
        let decoder = JSONDecoder()
        var result: [DayMetrics] = []
        var skipped: [String] = []
        for (key, url) in dayFiles(in: directory).sorted(by: { $0.key < $1.key }) where key >= first && key <= last {
            do {
                var day = try decoder.decode(DayMetrics.self, from: Data(contentsOf: url))
                day.day = key
                result.append(day)
            } catch {
                skipped.append(url.lastPathComponent)
            }
        }
        return (result, skipped)
    }

    // MARK: Unclean exit

    /// Writes the `running` marker file in `directory`. Returns true when the marker was already there:
    /// the previous run did not end with `markCleanExit()`. Then it also records `uncleanExit`.
    /// When the store is disabled it writes nothing and returns false.
    @discardableResult
    public func markRunning() -> Bool {
        guard isEnabled else { return false }
        let fm = FileManager.default
        let marker = directory.appendingPathComponent(MetricsStore.runningMarker)
        let wasThere = fm.fileExists(atPath: marker.path)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let started = ISO8601DateFormatter().string(from: clock())
        try? Data("\(started)\n".utf8).write(to: marker, options: .atomic)
        if wasThere { record(.uncleanExit) }
        return wasThere
    }

    /// Removes the marker. Call at a clean quit, after the last flush.
    public func markCleanExit() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(MetricsStore.runningMarker))
    }
}

extension MetricsStore {
    static let runningMarker = "running"

    static func fileURL(directory: URL, day: String) -> URL {
        directory.appendingPathComponent("\(day).json", isDirectory: false)
    }

    /// Sorted keys so that the same day gives the same bytes; pretty, so a person can read the file.
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }

    /// The same calendar, but Gregorian. Day boundaries come from the time zone, which stays.
    static func gregorian(_ calendar: Calendar) -> Calendar {
        if calendar.identifier == .gregorian { return calendar }
        var g = Calendar(identifier: .gregorian)
        g.timeZone = calendar.timeZone
        return g
    }

    /// `n` in ASCII digits, padded with zeros to `width`.
    static func digits(_ n: Int, _ width: Int) -> String {
        let s = String(n.magnitude)
        let padded = s.count < width ? String(repeating: "0", count: width - s.count) + s : s
        return n < 0 ? "-" + padded : padded
    }

    /// The key of a day file name (`2026-10-13.json` gives `2026-10-13`), or nil for any other name.
    static func dayKey(fileName name: String) -> String? {
        let u = Array(name.utf8)
        guard u.count == 15, name.hasSuffix(".json") else { return nil }
        for (i, ch) in u.prefix(10).enumerated() {
            let ok = (i == 4 || i == 7) ? ch == UInt8(ascii: "-") : (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(ch)
            if !ok { return nil }
        }
        return String(name.prefix(10))
    }

    /// The regular files in `directory` whose name is a day file name. Folders and other files are left out.
    static func dayFiles(in directory: URL) -> [(key: String, url: URL)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return urls.compactMap { url in
            guard let key = dayKey(fileName: url.lastPathComponent),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            return (key, url)
        }
    }
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

    /// `total.day` is the last day, or "" without days. Rows with a count of 0 are left out.
    /// A budget with a name that is not in `MetricsBudget.live` has no value. Without days no budget has a value,
    /// also not unclean-exits: no file means nothing is known.
    public static func make(days: [DayMetrics], skipped: [String] = [], budgets: [MetricsBudget] = MetricsBudget.live)
        -> MetricsReport {
        var total = DayMetrics(day: days.last?.day ?? "")
        for day in days { total.merge(day) }

        let results = budgets.map { budget -> BudgetResult in
            let value = days.isEmpty ? nil : budgetValue(budget.name, total)
            let pass = value.map { v -> Bool in
                switch budget.comparison {
                case .atMost: return v <= budget.limit
                }
            }
            return BudgetResult(budget: budget, value: value, pass: pass)
        }

        let commands = total.commands
            .map { CommandRow(name: $0.key, total: $0.value.values.reduce(0, +), bySource: $0.value) }
            .filter { $0.total > 0 }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }

        var friction: [FrictionRow] = []
        for (bundleID, app) in total.apps {
            for (kind, count) in app.friction where count > 0 {
                friction.append(FrictionRow(bundleID: bundleID, kind: kind, count: count))
            }
        }
        friction.sort {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.bundleID != $1.bundleID { return $0.bundleID < $1.bundleID }
            return $0.kind < $1.kind
        }

        let slowApps = total.apps
            .filter { $0.value.axWrite.count >= 1 }
            .map { AppRow(bundleID: $0.key, writes: $0.value.axWrite.count, axP50: $0.value.axWrite.percentile(50),
                          axP95: $0.value.axWrite.percentile(95), axErrors: $0.value.axErrors) }
            .sorted { $0.axP95 != $1.axP95 ? $0.axP95 > $1.axP95 : $0.bundleID < $1.bundleID }

        return MetricsReport(firstDay: days.first?.day, lastDay: days.last?.day, dayCount: days.count, total: total,
                             budgets: results, commands: commands, friction: friction, slowApps: slowApps,
                             skipped: skipped)
    }

    private static func budgetValue(_ name: String, _ t: DayMetrics) -> Double? {
        func p95(_ h: Histogram) -> Double? { h.count > 0 ? h.percentile(95) : nil }
        switch name {
        case "frame-write-p95": return p95(t.frameWrite)
        case "command-latency-p95": return p95(t.commandLatency)
        case "command-settle-p95": return p95(t.commandSettle)
        case "slow-tick-ratio": return t.ticks > 0 ? Double(t.slowTicks) / Double(t.ticks) * 100 : nil
        case "cpu-while-active": return t.activeSeconds > 0 ? t.cpuSeconds / t.activeSeconds * 100 : nil
        case "unclean-exits": return Double(t.events[MetricEvent.uncleanExit.rawValue] ?? 0)
        default: return nil
        }
    }

    /// The text for a terminal: period, active time, budgets (PASS, FAIL or no data), speed percentiles,
    /// cost, reliability events, top 10 commands, top 10 friction rows, 10 slowest apps, skipped files.
    /// Short lines, no colors, no emoji.
    public func renderText() -> String {
        typealias F = ReportFormat
        var out: [String] = []
        if let first = firstDay, let last = lastDay {
            let span = first == last ? first : "\(first) to \(last)"
            out.append("Striple metrics: \(span) (\(dayCount) \(dayCount == 1 ? "day" : "days") with data)")
        } else {
            out.append("Striple metrics: no data yet")
        }
        out.append("Active time: \(F.duration(total.activeSeconds))")
        if !total.appVersions.isEmpty { out.append("App versions: \(total.appVersions.joined(separator: ", "))") }

        out.append("")
        out.append("Budgets")
        out += F.table(budgets.map { r in
            let result = r.pass.map { $0 ? "PASS" : "FAIL" } ?? "no data"
            return [r.budget.name, r.value.map { F.amount($0, unit: r.budget.unit) } ?? "-",
                    "limit \(F.amount(r.budget.limit, unit: r.budget.unit, short: true))", result]
        }, right: [1])

        out.append("")
        out.append("Speed (ms)")
        var ax = Histogram()
        for app in total.apps.values { ax.merge(app.axWrite) }
        let speed: [(String, Histogram)] = [("frame write", total.frameWrite), ("command latency", total.commandLatency),
                                            ("command settle", total.commandSettle), ("tick interval", total.tickInterval),
                                            ("AX write (all apps)", ax)]
        out += F.table([["", "count", "p50", "p95", "p99", "max"]] + speed.map { name, h in
            [name, String(h.count)] + (h.count > 0
                ? [h.percentile(50), h.percentile(95), h.percentile(99), h.max].map { F.number($0) }
                : ["-", "-", "-", "-"])
        }, right: [1, 2, 3, 4, 5])
        let slowShare = total.ticks > 0 ? " (\(F.number(Double(total.slowTicks) / Double(total.ticks) * 100)) %)" : ""
        out.append("  Ticks: \(total.ticks), slow: \(total.slowTicks)\(slowShare)")

        out.append("")
        out.append("Cost")
        let cpuShare = total.activeSeconds > 0
            ? " (\(F.number(total.cpuSeconds / total.activeSeconds * 100)) % of active time)" : ""
        out.append("  CPU: \(F.number(total.cpuSeconds)) s\(cpuShare)")
        let wakeRate = total.activeSeconds > 0
            ? " (\(F.number(Double(total.wakeups) / total.activeSeconds)) per active second)" : ""
        out.append("  Wakeups: \(total.wakeups)\(wakeRate)")
        out.append("  Peak memory: \(F.number(total.peakRSSMB, digits: 1)) MB")

        out.append("")
        out.append("Reliability")
        let reliability: [MetricEvent] = [.uncleanExit, .permissionLost, .observerRepair, .focusFallback, .staleApp,
                                          .hotkeyRefused, .configError, .engineRestart]
        let axErrors = total.apps.values.reduce(0) { $0 + $1.axErrors }
        out += F.table(reliability.map { [$0.rawValue, String(total.events[$0.rawValue] ?? 0)] }
                       + [["ax.errors", String(axErrors)]], right: [1])

        out.append("")
        out.append("Usage")
        let shown = Set(reliability.map(\.rawValue))
        let usage = total.events.filter { !shown.contains($0.key) && $0.value > 0 }.sorted { $0.key < $1.key }
        out += F.table(usage.map { [$0.key, String($0.value)] }, right: [1])
        let columnKeys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10+"]
        let columns = columnKeys.compactMap { key in total.columnsPerStrip[key].flatMap { $0 > 0 ? "\(key): \($0)" : nil } }
        out.append("  Columns per strip: \(columns.isEmpty ? "no data" : columns.joined(separator: ", "))")

        out.append("")
        out.append(F.heading("Commands", shown: Swift.min(commands.count, 10), of: commands.count))
        out += F.table(commands.prefix(10).map { row in
            let sources = row.bySource.filter { $0.value > 0 }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            return [row.name, String(row.total), sources]
        }, right: [1])

        out.append("")
        out.append(F.heading("Friction", shown: Swift.min(friction.count, 10), of: friction.count))
        out += F.table(friction.prefix(10).map { [$0.bundleID, $0.kind, String($0.count)] }, right: [2])

        out.append("")
        out.append(F.heading("Slowest apps (AX write ms)", shown: Swift.min(slowApps.count, 10), of: slowApps.count))
        if !slowApps.isEmpty {
            out += F.table([["", "writes", "p50", "p95", "errors"]] + slowApps.prefix(10).map {
                [$0.bundleID, String($0.writes), F.number($0.axP50), F.number($0.axP95), String($0.axErrors)]
            }, right: [1, 2, 3, 4])
        }

        if !skipped.isEmpty {
            out.append("")
            out.append("Skipped files (cannot be read)")
            out += skipped.map { "  \($0)" }
        }
        return out.joined(separator: "\n") + "\n"
    }
}

/// Plain text helpers for `MetricsReport.renderText()`. Locale independent.
enum ReportFormat {
    static func number(_ v: Double, digits: Int = 2) -> String { String(format: "%.\(digits)f", v) }

    /// `8`, `16.7`, `0.25`: no trailing zeros.
    static func shortNumber(_ v: Double) -> String {
        var s = number(v)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func amount(_ v: Double, unit: String, short: Bool = false) -> String {
        if unit == "count" { return short ? shortNumber(v) : String(Int(v.rounded())) }
        return "\(short ? shortNumber(v) : number(v)) \(unit)"
    }

    static func duration(_ seconds: Double) -> String {
        let s = seconds.isFinite ? Int(Swift.max(seconds, 0).rounded()) : 0
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(MetricsStore.digits(s % 60, 2))s" }
        return "\(s / 3600)h \(MetricsStore.digits(s / 60 % 60, 2))m"
    }

    static func heading(_ title: String, shown: Int, of total: Int) -> String {
        if total == 0 { return "\(title): none" }
        return shown == total ? title : "\(title) (top \(shown) of \(total))"
    }

    /// Rows with columns lined up, two spaces in front and between. Columns in `right` are right aligned.
    /// An empty table gives "  none".
    static func table(_ rows: [[String]], right: Set<Int>) -> [String] {
        guard !rows.isEmpty else { return ["  none"] }
        var widths: [Int] = []
        for row in rows {
            for (i, cell) in row.enumerated() {
                if i == widths.count { widths.append(0) }
                widths[i] = Swift.max(widths[i], cell.count)
            }
        }
        return rows.map { row in
            let cells = row.enumerated().map { i, cell -> String in
                let pad = String(repeating: " ", count: widths[i] - cell.count)
                return right.contains(i) ? pad + cell : cell + pad
            }
            var line = "  " + cells.joined(separator: "  ")
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }
    }
}

// MARK: Marks

/// `striple mark` and the Mark shortcut save a bundle that shows the state at a bad moment.
/// Folder: `<metrics directory>/marks/<YYYY-MM-DDTHH-MM-SS>/` (local time; a suffix `-2`, `-3` when it exists).
public enum MetricsMark {
    /// Seconds of engine log kept in a mark.
    public static let logWindow: TimeInterval = 60

    /// The engine log lines from the last `window` seconds before `now`. Log lines start with an ISO 8601 time
    /// with fractional seconds. A line without a time belongs to the line before it.
    /// Lines after `now` are left out, and so are lines without a time at the start of the log.
    public static func logTail(_ log: String, now: Date, window: TimeInterval = logWindow) -> [String] {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = now.addingTimeInterval(-window)
        var lines = log.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var tail: [String] = []
        var keep = false
        for raw in lines {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let time = leadingTime(line, parser) { keep = time >= start && time <= now }
            if keep { tail.append(line) }
        }
        return tail
    }

    private static func leadingTime(_ line: String, _ parser: ISO8601DateFormatter) -> Date? {
        guard let first = line.utf8.first, first >= UInt8(ascii: "0"), first <= UInt8(ascii: "9") else { return nil }
        return parser.date(from: String(line.prefix { $0 != " " && $0 != "\t" }))
    }

    /// The state with every window title removed (set to an empty string).
    public static func redacted(_ state: EngineState) -> EngineState {
        var s = state
        s.focusedWindow?.title = ""
        for d in s.displays.indices {
            for c in s.displays[d].columns.indices {
                for w in s.displays[d].columns[c].indices { s.displays[d].columns[c][w].title = "" }
            }
        }
        for i in s.floating.indices { s.floating[i].title = "" }
        return s
    }

    /// Writes note.txt (the note, can be empty), state.json (redacted), stats.json, day.json (the snapshot)
    /// and engine.log (the tail). Returns the folder. Creates the folders it needs.
    /// note.txt and engine.log are always written; state.json, stats.json and day.json only when the value is not nil.
    public static func write(note: String, state: EngineState?, stats: EngineStats?, day: DayMetrics?,
                             logLines: [String], marksDirectory: URL, now: Date,
                             calendar: Calendar = .current) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: marksDirectory, withIntermediateDirectories: true)
        let base = folderName(now, calendar: calendar)
        var folder: URL?
        var suffix = 1
        while folder == nil {
            let url = marksDirectory.appendingPathComponent(suffix == 1 ? base : "\(base)-\(suffix)", isDirectory: true)
            do {
                // Not intermediate: creating fails when the folder exists, so two marks never share one.
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
                folder = url
            } catch {
                guard fm.fileExists(atPath: url.path), suffix < 10_000 else { throw error }
                suffix += 1
            }
        }
        let dir = folder!
        let encoder = MetricsStore.encoder()
        try Data(note.utf8).write(to: dir.appendingPathComponent("note.txt"), options: .atomic)
        if let state { try encoder.encode(redacted(state)).write(to: dir.appendingPathComponent("state.json"), options: .atomic) }
        if let stats { try encoder.encode(stats).write(to: dir.appendingPathComponent("stats.json"), options: .atomic) }
        if let day { try encoder.encode(day).write(to: dir.appendingPathComponent("day.json"), options: .atomic) }
        let log = logLines.isEmpty ? "" : logLines.joined(separator: "\n") + "\n"
        try Data(log.utf8).write(to: dir.appendingPathComponent("engine.log"), options: .atomic)
        return dir
    }

    /// `YYYY-MM-DDTHH-MM-SS` of `now` in `calendar`, Gregorian, ASCII digits. No colons: they are not safe in file names.
    static func folderName(_ now: Date, calendar: Calendar) -> String {
        let c = MetricsStore.gregorian(calendar).dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let d = MetricsStore.digits
        return "\(d(c.year ?? 0, 4))-\(d(c.month ?? 0, 2))-\(d(c.day ?? 0, 2))T\(d(c.hour ?? 0, 2))-\(d(c.minute ?? 0, 2))-\(d(c.second ?? 0, 2))"
    }
}

extension StriplePaths {
    /// `<support>/metrics`
    public static var metricsDirectory: URL { supportDirectory.appendingPathComponent("metrics", isDirectory: true) }
    /// `<support>/metrics/marks`
    public static var marksDirectory: URL { metricsDirectory.appendingPathComponent("marks", isDirectory: true) }
}
