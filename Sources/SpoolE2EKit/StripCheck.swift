import Foundation

/// The strip that holds the test windows, as `spool state` shows it.
public struct StripView: Equatable, Sendable {
    /// The window numbers of each column, left to right.
    public var columns: [[UInt32]]
    public var focusedColumn: Int

    public init(columns: [[UInt32]], focusedColumn: Int) {
        self.columns = columns
        self.focusedColumn = focusedColumn
    }

    /// The first window of each column.
    public var ids: [UInt32] { columns.compactMap(\.first) }
}

/// What a strip scenario expects after its command.
public struct StripExpectation: Equatable, Sendable {
    public var count: Int
    /// The window order, left to right. Nil: any order.
    public var order: [UInt32]?
    /// The focused column (0-based). Nil: any column.
    public var focusedColumn: Int?
    /// The focused column must be fully in view.
    public var focusedInView: Bool

    public init(count: Int, order: [UInt32]? = nil, focusedColumn: Int? = nil, focusedInView: Bool = true) {
        self.count = count
        self.order = order
        self.focusedColumn = focusedColumn
        self.focusedInView = focusedInView
    }
}

/// The checks of the strip scenarios: Spool's state and the frames the test app reports.
public enum StripCheck {
    public static func title(_ id: UInt32, _ report: WindowReport?) -> String {
        report?.window(number: Int(id))?.title ?? "window \(id)"
    }

    /// The failures; empty when the strip is as expected. `strip` is nil when no strip holds a test window.
    /// `floating` are the test windows Spool floats. `proportion` gives the column width the runner expects
    /// for a window. The frames must match the scroll of the default center mode `onOverflow` for Spool's
    /// focused column, and that column must hold the key window when the test app is frontmost.
    public static func failures(_ strip: StripView?, _ report: WindowReport, floating: [UInt32], expect: StripExpectation,
                                geometry: StripGeometry, proportion: (UInt32) -> Double) -> [String] {
        guard let strip else { return ["no strip holds a test window"] }
        var failures: [String] = []
        if let bad = strip.columns.first(where: { $0.count != 1 }) {
            failures.append("a column holds \(bad.count) windows")
        }
        let ids = strip.ids
        if ids.count != expect.count { failures.append("strip has \(ids.count) columns, want \(expect.count)") }
        // Every window of the test app is in the strip or floats, never both, never neither.
        let inStrip = Set(strip.columns.joined()), floats = Set(floating)
        for id in inStrip.intersection(floats).sorted() {
            failures.append("\(title(id, report)) is in the strip and floats")
        }
        for w in report.windows where !inStrip.contains(UInt32(w.number)) && !floats.contains(UInt32(w.number)) {
            failures.append("\(w.title) is shown by the test app but is not in the strip and does not float")
        }
        if let order = expect.order, ids != order {
            failures.append("order \(ids.map { title($0, report) }), want \(order.map { title($0, report) })")
        }
        if let want = expect.focusedColumn, strip.focusedColumn != want {
            failures.append("focused column \(strip.focusedColumn + 1), want \(want + 1)")
        }
        // The expected scroll follows Spool's focused column, so that column must be the one the user sees
        // focused: when the test app is frontmost and a strip window is key, it is the key window.
        if report.active, let key = report.key.map(UInt32.init), inStrip.contains(key), ids.indices.contains(strip.focusedColumn),
           ids[strip.focusedColumn] != key {
            failures.append("\(title(key, report)) is the key window, but Spool's focused column \(strip.focusedColumn + 1) is \(title(ids[strip.focusedColumn], report))")
        }
        var columns: [FrameChecks.Column] = []
        for id in ids {
            guard let w = report.window(number: Int(id)) else {
                failures.append("window \(id) is in the strip but the test app does not show it")
                continue
            }
            columns.append(.init(title: w.title, frame: w.frame, proportion: proportion(id)))
        }
        // The scroll needs every column; a missing window is already a failure above.
        let scroll = columns.count == ids.count && ids.indices.contains(strip.focusedColumn)
            ? geometry.expectedScroll(columns.map(\.proportion), focused: strip.focusedColumn) : nil
        failures += FrameChecks.checkStrip(columns, geometry: geometry, scroll: scroll)
        if expect.focusedInView {
            if !ids.indices.contains(strip.focusedColumn) {
                failures.append("focused column \(strip.focusedColumn + 1) does not exist (\(ids.count) columns)")
            } else if let w = report.window(number: Int(ids[strip.focusedColumn])) {
                failures += FrameChecks.checkInView(w.title, w.frame, geometry: geometry)
            }
        }
        return failures
    }

    /// True when `id` has Spool's focus and the system focus (test app active, that window key). Spool acts
    /// on its focused window, the user sees the system focus: both must agree.
    public static func hasFocus(_ id: UInt32, spoolFocus: UInt32?, report: WindowReport?) -> Bool {
        spoolFocus == id && report?.hasSystemFocus(Int(id)) == true
    }
}

/// Decides when the frames have settled: the check passes on frames that did not change for `stableFor`
/// seconds (the animation is over). The runner feeds it one observation per poll.
public struct SettleTracker: Sendable {
    public static let stableFor = 0.25

    private var stableSince: (time: Double, windows: [ReportedWindow])?
    /// The failures of the last observation; "frames did not stay still" while the check passes but the
    /// frames still move.
    public private(set) var last: [String] = ["no frame report from the test app"]

    public init() {}

    /// One observation at `now` (seconds, any monotonic origin). Returns true when settled.
    public mutating func observe(_ windows: [ReportedWindow], failures: [String], now: Double) -> Bool {
        guard failures.isEmpty else {
            stableSince = nil
            last = failures
            return false
        }
        if let s = stableSince, s.windows == windows {
            if now - s.time >= Self.stableFor { last = []; return true }
        } else {
            stableSince = (now, windows)
        }
        last = ["frames did not stay still"]
        return false
    }
}
