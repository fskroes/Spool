import Foundation
import StripleCore
import StripleE2EKit

/// The live scenarios. Each adds one row to the report. A scenario that cannot start (an earlier one left
/// the strip in an unknown state) is a FAIL too, never a silent pass.
final class Scenarios {
    let h: Harness
    let g: StripGeometry
    private(set) var rows: [Report.Row] = []
    /// The column width of each window, as the runner expects it after the commands it sent.
    private var proportions: [UInt32: Double] = [:]

    init(harness: Harness) {
        h = harness
        g = harness.geometry()
    }

    func proportion(_ id: UInt32) -> Double { proportions[id] ?? h.layout.defaultWidth }

    // MARK: Helpers

    /// The strip (on any display) that holds the test windows.
    func testStrip(_ s: EngineState) -> EngineState.DisplayState? {
        s.displays.first { d in d.columns.joined().contains { $0.bundleID == E2EIDs.windowsBundleID } }
    }

    func ids(_ d: EngineState.DisplayState) -> [UInt32] { d.columns.compactMap { $0.first?.id } }

    /// The window of the focused column, or nil when the state has no such column. Never traps.
    func focusedID(_ d: EngineState.DisplayState) -> UInt32? { ids(d)[safe: d.focusedColumn] }

    func title(_ id: UInt32, _ f: WindowReport?) -> String { f?.window(number: Int(id))?.title ?? "window \(id)" }

    /// A check for `settle`: the strip has `count` single-window columns (in `order` when given), the frames
    /// follow the layout rules, and with `focusedInView` the focused column is fully in view.
    func stripCheck(count: Int, order: [UInt32]? = nil, focusedColumn: Int? = nil, focusedInView: Bool = true,
                    extra: ((EngineState, WindowReport) -> [String])? = nil) -> (WindowReport) -> [String] {
        return { f in
            guard let s = self.h.state() else { return ["striple state failed"] }
            guard let d = self.testStrip(s) else { return ["no strip holds a test window"] }
            var failures: [String] = []
            if let bad = d.columns.first(where: { $0.count != 1 }) {
                failures.append("a column holds \(bad.count) windows")
            }
            let ids = self.ids(d)
            if ids.count != count { failures.append("strip has \(ids.count) columns, want \(count)") }
            if let order, ids != order {
                failures.append("order \(ids.map { self.title($0, f) }), want \(order.map { self.title($0, f) })")
            }
            if let focusedColumn, d.focusedColumn != focusedColumn {
                failures.append("focused column \(d.focusedColumn + 1), want \(focusedColumn + 1)")
            }
            var columns: [FrameChecks.Column] = []
            for id in ids {
                guard let w = f.window(number: Int(id)) else {
                    failures.append("window \(id) is in the strip but the test app does not show it")
                    continue
                }
                columns.append(.init(title: w.title, frame: w.frame, proportion: self.proportion(id)))
            }
            failures += FrameChecks.checkStrip(columns, geometry: self.g)
            if focusedInView, ids.indices.contains(d.focusedColumn), let w = f.window(number: Int(ids[d.focusedColumn])) {
                failures += FrameChecks.checkInView(w.title, w.frame, geometry: self.g)
            }
            if let extra { failures += extra(s, f) }
            return failures
        }
    }

    func current() -> (EngineState, EngineState.DisplayState)? {
        guard let s = h.state(), let d = testStrip(s) else { return nil }
        return (s, d)
    }

    /// Runs one scenario and adds its row. Returns true when it passed.
    @discardableResult
    private func record(_ scenario: String, _ body: () -> (failures: [String], details: String)) -> Bool {
        h.log("scenario: \(scenario)")
        let started = Date()
        let focusBefore = h.focusFailures.count
        var r = body()
        r.failures += h.focusFailures.dropFirst(focusBefore).map { "focus: \($0)" }
        let secs = String(format: "%.1f s", Date().timeIntervalSince(started))
        let row = Report.Row(scenario: scenario, result: r.failures.isEmpty ? .pass : .fail,
                             details: (r.failures.isEmpty ? r.details : r.failures.prefix(6).joined(separator: "\n")) + " (\(secs))")
        h.log("  \(row.result.rawValue): \(row.details)")
        rows.append(row)
        return row.result == .pass
    }

    func add(_ row: Report.Row) { rows.append(row) }

    /// A SKIP row (it counts as a failure) for a scenario that cannot start from a known state.
    func skip(_ scenario: String, because why: String) {
        h.log("scenario: \(scenario)\n  SKIP: \(why)")
        rows.append(.init(scenario: scenario, result: .skip, details: "not run: \(why)"))
    }

    /// The names of the strip scenarios b to f. They need the tiled strip of scenario a.
    enum Name {
        static let focus = "b. focus-left / focus-right scroll the focused column into view"
        static let move = "c. move-left / move-right change the column order"
        static let widths = "d. cycle-width and toggle-full-width"
        static let closeAndOpen = "e. Close one window, open one more"
        static let float = "f. toggle-float takes a window out of the strip and back"
    }
    static let stripScenarios = [Name.focus, Name.move, Name.widths, Name.closeAndOpen, Name.float]

    // MARK: a. Tiling

    /// Returns true when the strip is tiled. The later strip scenarios need that start.
    func tiling() -> Bool {
        record("a. Tiling: 3 windows become columns") {
            let n = h.config.windowCount
            let fails = h.settle(timeout: 10, stripCheck(count: n))
            let f = h.frames()
            let widths = f?.windows.map { String(format: "%.0f", $0.w) }.joined(separator: ", ") ?? "?"
            return (fails, "\(n) columns, top \(Int(g.work.minY)), height \(Int(g.work.height)), widths \(widths), gap \(Int(g.gap)); "
                    + "focused column in view, parked columns keep a sliver")
        }
    }

    // MARK: b. Focus

    func focus() {
        record(Name.focus) {
            guard let (_, d) = current() else { return (["no test strip"], "") }
            let n = d.columns.count
            guard let start = focusedID(d) else { return (["focused column \(d.focusedColumn + 1) of \(n) does not exist"], "") }
            var fails: [String] = []
            var steps = 0
            var col = d.focusedColumn
            h.lastTestFocus = start
            while col > 0 && fails.isEmpty {
                _ = h.command("focus-left")
                col -= 1
                steps += 1
                fails += h.settle(stripCheck(count: n, focusedColumn: col)).map { "focus-left to \(col + 1): \($0)" }
            }
            while col < n - 1 && fails.isEmpty {
                _ = h.command("focus-right")
                col += 1
                steps += 1
                fails += h.settle(stripCheck(count: n, focusedColumn: col)).map { "focus-right to \(col + 1): \($0)" }
            }
            // Striple's focus and the system focus (test app active, that window key) must both be on the column.
            if fails.isEmpty, !h.poll(timeout: 3, { [self] in
                guard let (s, d) = current(), let want = ids(d)[safe: col] else { return false }
                return s.focusedWindow?.id == want && h.frames()?.hasSystemFocus(Int(want)) == true
            }) {
                let id = current()?.0.focusedWindow?.id
                let f = h.frames()
                fails.append("column \(col + 1): Striple focus \(id.map(String.init) ?? "none"), "
                             + "system focus: test app active \(f?.active ?? false), key window \(f?.key.map(String.init) ?? "none")")
            }
            if let (_, d) = current(), let id = focusedID(d) { h.lastTestFocus = id }
            return (fails, "\(steps) focus steps, each focused column fully in view; Striple and system focus on column \(col + 1)")
        }
    }

    // MARK: c. Move

    func move() {
        record(Name.move) {
            guard let (_, d) = current() else { return (["no test strip"], "") }
            var order = ids(d)
            var col = d.focusedColumn
            let n = order.count
            guard n >= 2 else { return (["need 2 columns, have \(n)"], "") }
            guard order.indices.contains(col) else { return (["focused column \(col + 1) of \(n) does not exist"], "") }
            var fails: [String] = []
            var moves: [String] = []
            // Move the focused column to the far left, then back to the far right.
            for (name, delta) in [("move-left", -1), ("move-right", 1)] {
                let steps = delta < 0 ? col : n - 1 - col
                for _ in 0..<steps where fails.isEmpty {
                    _ = h.command(name)
                    order.swapAt(col, col + delta)
                    col += delta
                    moves.append(name)
                    fails += h.settle(stripCheck(count: n, order: order, focusedColumn: col)).map { "\(name): \($0)" }
                }
            }
            return (fails, "\(moves.count) moves (\(moves.joined(separator: ", "))), order and frames as expected")
        }
    }

    // MARK: d. Widths

    func widths() {
        record(Name.widths) {
            guard let (_, d) = current() else { return (["no test strip"], "") }
            let n = d.columns.count
            guard let id = focusedID(d) else { return (["focused column \(d.focusedColumn + 1) of \(n) does not exist"], "") }
            let presets = h.layout.presetWidths.sorted()
            var fails: [String] = []
            var seen: [String] = []
            func step(_ name: String, _ next: Double) {
                guard fails.isEmpty else { return }
                _ = h.command(name, focus: id)
                proportions[id] = next
                let want = g.columnWidth(next)
                seen.append("\(name) -> \(Int(want.rounded()))")
                fails += h.settle(stripCheck(count: n)).map { "\(name): \($0)" }
            }
            guard let smallest = presets.first else { return (["layout.presetWidths is empty"], "") }
            func nextPreset() -> Double { presets.first { $0 > proportion(id) + 0.01 } ?? smallest }
            step("cycle-width", nextPreset())
            step("cycle-width", nextPreset())
            let beforeFull = proportion(id)
            step("toggle-full-width", 1.0)
            if fails.isEmpty, let w = h.frames()?.window(number: Int(id)), !FrameChecks.near(w.x, Double(g.work.minX)) {
                fails.append("full width window starts at x \(w.x), want \(g.work.minX)")
            }
            step("toggle-full-width", beforeFull)
            // Back to the default width, so the later scenarios start from the default layout.
            while fails.isEmpty, abs(proportion(id) - h.layout.defaultWidth) > 0.01, seen.count < 10 {
                step("cycle-width", nextPreset())
            }
            return (fails, "\(title(id, h.frames())): " + seen.joined(separator: ", ") + " pt; other columns reflow with gap \(Int(g.gap))")
        }
    }

    // MARK: e. Close and open

    func closeAndOpen() {
        record(Name.closeAndOpen) {
            guard let (_, d) = current() else { return (["no test strip"], "") }
            let before = ids(d)
            let n = before.count
            guard n >= 2 else { return (["need 2 columns, have \(n)"], "") }
            // The middle (or second) column: closing it would leave a hole between two others.
            let victim = before[min(1, n - 1)]
            let name = title(victim, h.frames())
            var fails: [String] = []
            if !h.send(.close(title: name)) { fails.append("the test app did not close \(name)") }
            if fails.isEmpty {
                if h.lastTestFocus == victim { h.lastTestFocus = before.first { $0 != victim } }
                let rest = before.filter { $0 != victim }
                fails += h.settle(stripCheck(count: n - 1, order: rest)).map { "after closing \(name): \($0)" }
            }
            let titlesBefore = Set(h.frames()?.windows.map(\.title) ?? [])
            // docs/SPEC.md: a new window opens directly to the right of the focused column.
            let focusedBefore = current()?.1.focusedColumn
            if fails.isEmpty, focusedBefore == nil { fails.append("no test strip after closing \(name)") }
            if fails.isEmpty, !h.send(.open) { fails.append("the test app did not open a window") }
            var opened = "?"
            var column = 0
            if fails.isEmpty, let focusedBefore {
                fails += h.settle(timeout: 5, stripCheck(count: n) { [self] s, f in
                    let fresh = f.windows.filter { !titlesBefore.contains($0.title) }
                    guard let w = fresh.first else { return ["no new window yet"] }
                    opened = w.title
                    guard let d = testStrip(s), let i = ids(d).firstIndex(of: UInt32(w.number)) else {
                        return ["\(w.title) is not in the strip"]
                    }
                    column = i + 1
                    return i == focusedBefore + 1 ? [] : ["\(w.title) is column \(i + 1), want \(focusedBefore + 2) (right of the focused column \(focusedBefore + 1))"]
                }).map { "after opening: \($0)" }
            }
            return (fails, "closed \(name): \(n - 1) columns, no hole; opened \(opened): column \(column), right of the focused column")
        }
    }

    // MARK: f. Float

    func float() {
        record(Name.float) {
            guard let (_, d) = current() else { return (["no test strip"], "") }
            let before = ids(d)
            let n = before.count
            guard n >= 2 else { return (["need 2 columns, have \(n)"], "") }
            let id = before[1]
            let name = title(id, h.frames())
            var fails: [String] = []
            _ = h.command("toggle-float", focus: id)
            fails += h.settle(stripCheck(count: n - 1, order: before.filter { $0 != id }) { s, _ in
                s.floating.contains { $0.id == id } ? [] : ["\(name) is not floating"]
            }).map { "float: \($0)" }
            if fails.isEmpty {
                _ = h.command("toggle-float", focus: id)
                h.lastTestFocus = id
                fails += h.settle(stripCheck(count: n) { s, _ in
                    s.floating.contains { $0.id == id } ? ["\(name) still floats"] : []
                }).map { "tile again: \($0)" }
            }
            return (fails, "\(name) floated: \(n - 1) columns close the gap; toggled back: \(n) columns")
        }
    }

    // MARK: h. Performance

    func performance() {
        guard let s = h.stats() else {
            add(.init(scenario: "h. Performance (striple stats)", result: .fail, details: "striple stats --json failed"))
            return
        }
        let cli = Percentiles(h.cliCommandMs)
        let settle = Percentiles(h.settleMs)
        let details = String(format: "frame write p50 %.2f ms, p95 %.2f ms; command latency p50 %.2f ms, p95 %.2f ms; "
                             + "%d frames, %d window writes, %d skipped, %d coalesced; AX errors %d; "
                             + "CLI round trip p50 %.0f ms, p95 %.0f ms; settle p50 %.0f ms, p95 %.0f ms",
                             s.frameWriteP50, s.frameWriteP95, s.commandLatencyP50, s.commandLatencyP95, s.framesWritten,
                             s.windowWrites, s.skippedWrites, s.coalescedWrites, s.axErrors, cli.p50, cli.p95, settle.p50, settle.p95)
        h.log("stats: \(details)")
        let over = PerformanceBudget.check(frameWriteP95: s.frameWriteP95, settleP95: h.settleMs.isEmpty ? nil : settle.p95,
                                           axErrors: s.axErrors)
        add(.init(scenario: "h. Performance (striple stats)", result: over.isEmpty ? .pass : .fail,
                  details: (over.isEmpty ? "" : over.joined(separator: "; ") + ". ") + details))
    }

    // MARK: g. Quit

    func quit() {
        record("g. SIGTERM: every test window ends fully on screen") {
            let pid = h.striple?.processIdentifier ?? 0
            guard h.stopStriple(wait: 5) else { return (["Striple (pid \(pid)) did not quit within 5 s of SIGTERM"], "") }
            let code = h.striple?.terminationStatus ?? -1
            let displays = h.displayFrames()
            var fails = h.settle { f in
                f.windows.filter { !FrameChecks.isFullyOnScreen($0.frame, displays: displays) }
                    .map { "\($0.title) \(FrameChecks.describe($0.frame)) is not fully on screen" }
            }
            if code != 0 { fails.append("Striple exit status \(code), want 0") }
            return (fails, "Striple quit with status \(code); \(h.frames()?.windows.count ?? 0) windows fully on screen")
        }
    }
}

/// Nearest-rank percentiles of a list of samples.
struct Percentiles {
    var p50 = 0.0, p95 = 0.0
    init(_ samples: [Double]) {
        var w = SampleWindow(capacity: max(samples.count, 1))
        samples.forEach { w.add($0) }
        p50 = w.percentile(50)
        p95 = w.percentile(95)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
