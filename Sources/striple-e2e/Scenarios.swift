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
    /// The number of test windows, from the windows the runner opened and closed. Never read from Striple's
    /// state: a lost or extra column must fail, not change what the next scenario expects.
    private(set) var expected: Int

    init(harness: Harness) {
        h = harness
        g = harness.geometry()
        expected = harness.config.windowCount
    }

    func proportion(_ id: UInt32) -> Double { proportions[id] ?? h.layout.defaultWidth }

    // MARK: Helpers

    /// The strip (on any display) that holds the test windows.
    func testStrip(_ s: EngineState) -> EngineState.DisplayState? {
        s.displays.first { d in d.columns.joined().contains { $0.bundleID == E2EIDs.windowsBundleID } }
    }

    func ids(_ d: EngineState.DisplayState) -> [UInt32] { d.columns.compactMap { $0.first?.id } }

    func title(_ id: UInt32, _ f: WindowReport?) -> String { StripCheck.title(id, f) }

    /// The strip as the pure checks in StripleE2EKit see it.
    func view(_ d: EngineState.DisplayState) -> StripView {
        StripView(columns: d.columns.map { $0.map(\.id) }, focusedColumn: d.focusedColumn)
    }

    /// A check for `settle`: `StripCheck.failures` on the current state, plus `extra` when a test strip exists.
    func stripCheck(count: Int, order: [UInt32]? = nil, focusedColumn: Int? = nil, focusedInView: Bool = true,
                    extra: ((EngineState, WindowReport) -> [String])? = nil) -> (WindowReport) -> [String] {
        let expect = StripExpectation(count: count, order: order, focusedColumn: focusedColumn, focusedInView: focusedInView)
        return { f in
            guard let s = self.h.state() else { return ["striple state failed"] }
            let strip = self.testStrip(s)
            let floating = s.floating.filter { $0.bundleID == E2EIDs.windowsBundleID }.map(\.id)
            var failures = StripCheck.failures(strip.map(self.view), f, floating: floating, expect: expect, geometry: self.g,
                                               proportion: self.proportion)
            if strip != nil, let extra { failures += extra(s, f) }
            return failures
        }
    }

    func current() -> (EngineState, EngineState.DisplayState)? {
        guard let s = h.state(), let d = testStrip(s) else { return nil }
        return (s, d)
    }

    /// The column order at the start of a scenario, or the failure when the strip does not have `expected`
    /// columns of one window each (the scenario then does not start).
    func startOrder(atLeast minimum: Int = 2) -> (order: [UInt32], focused: Int, failure: String?) {
        guard let (_, d) = current() else { return ([], 0, "no test strip") }
        let order = ids(d)
        if order.count != expected || d.columns.contains(where: { $0.count != 1 }) {
            return (order, d.focusedColumn, "strip has \(d.columns.map(\.count)) windows per column, want \(expected) columns of 1")
        }
        if expected < minimum { return (order, d.focusedColumn, "need \(minimum) columns, have \(expected)") }
        if !order.indices.contains(d.focusedColumn) {
            return (order, d.focusedColumn, "focused column \(d.focusedColumn + 1) of \(order.count) does not exist")
        }
        return (order, d.focusedColumn, nil)
    }

    /// Runs one scenario and adds its row. Returns true when it passed.
    @discardableResult
    private func record(_ scenario: String, _ body: () -> (failures: [String], details: String)) -> Bool {
        h.log("scenario: \(scenario)")
        let started = Date()
        let focusBefore = h.focusFailures.count
        let theftsBefore = h.thefts.count
        var r = body()
        r.failures += h.focusFailures.dropFirst(focusBefore).map { "focus: \($0)" }
        let thefts = h.thefts.dropFirst(theftsBefore)
        // The thefts go on the row in both cases: on a failure, they may explain it.
        let given = thefts.isEmpty ? "" : "focus given back after: " + thefts.joined(separator: "; ")
        if !given.isEmpty { r.details += "; " + given }
        let secs = String(format: "%.1f s", Date().timeIntervalSince(started))
        let shown = r.failures.isEmpty ? r.details : (r.failures.prefix(6) + (given.isEmpty ? [] : [given])).joined(separator: "\n")
        let row = Report.Row(scenario: scenario, result: r.failures.isEmpty ? .pass : .fail, details: shown + " (\(secs))")
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
        static let closeWhileMoving = "i. A window that closes while Striple moves it gives no AX error"
    }
    static let stripScenarios = [Name.focus, Name.move, Name.widths, Name.closeAndOpen, Name.float, Name.closeWhileMoving]

    // MARK: a. Tiling

    /// Returns true when the strip is tiled. The later strip scenarios need that start.
    func tiling() -> Bool {
        record("a. Tiling: 3 windows become columns") {
            let n = expected
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
            let (order, _, bad) = startOrder()
            if let bad { return ([bad], "") }
            let n = order.count
            var fails: [String] = []
            // Start on the last column, so the steps never depend on where scenario a left the focus:
            // n - 1 focus-left steps to column 1, then n - 1 focus-right steps back.
            let last = order[n - 1]
            // Counted from here, so a theft given back at the start also breaks the "exactly 2" check.
            let theftsBefore = h.thefts.count
            fails += takeFocus(last, check: stripCheck(count: n, order: order, focusedColumn: n - 1))
                .map { "start on column \(n): \($0)" }
            var col = n - 1
            var steps = 0
            // `--steal-focus`: the thief takes the focus after step 1 (the check after a step gives it back) and
            // before step 3 (the check before a command gives it back).
            let steal = h.config.stealFocus
            func step(_ name: String, _ delta: Int) {
                guard fails.isEmpty else { return }
                if steal, steps == 2, !h.stealFocus("before step 3") {
                    fails.append("--steal-focus: the thief did not take the focus before step 3")
                    return
                }
                // No focus repair: a step that does not leave the system focus on its column is a failure.
                _ = h.command(name, focus: order[col], repair: false)
                col += delta
                steps += 1
                if steal, steps == 1 {
                    // Steal after Striple's focus landed, so the check below finds the theft every time. If the focus
                    // never landed, that is a failure of step 1: the theft recovery must not hide it.
                    guard h.poll(timeout: 3, { h.hasFocus(order[col]) }) else {
                        fails.append("\(name) to \(col + 1): before the steal, " + focusState(order[col]))
                        return
                    }
                    if !h.stealFocus("after step 1") {
                        fails.append("--steal-focus: the thief did not take the focus after step 1")
                        return
                    }
                }
                fails += h.settle(stripCheck(count: n, order: order, focusedColumn: col)).map { "\(name) to \(col + 1): \($0)" }
                if fails.isEmpty, !h.waitForFocus(order[col], during: "after `\(name)` to column \(col + 1)") {
                    fails.append("\(name) to \(col + 1): " + focusState(order[col]))
                }
            }
            for _ in 1..<n { step("focus-left", -1) }
            for _ in 1..<n { step("focus-right", 1) }
            h.lastTestFocus = order[col]
            let recovered = h.thefts.count - theftsBefore
            if steal, fails.isEmpty, recovered != 2 {
                fails.append("--steal-focus: \(recovered) thefts given back, want 2 (after step 1 and before step 3)")
            }
            return (fails, "\(steps) focus steps from column \(n) to 1 and back; after each, the focused column is in view "
                    + "at the expected scroll, and Striple and the system focus are on it")
        }
    }

    /// Gives `id` the focus with `focus-window`, waits until the strip passes `check`, then waits until Striple and
    /// the system both have the focus on `id`. Returns the failures. The strip check comes first: when another app
    /// took the focus, `waitForFocus` gives it back with one more `focus-window`, which would also put right a
    /// wrong focused column or scroll of the first one.
    private func takeFocus(_ id: UInt32, check: (WindowReport) -> [String]) -> [String] {
        h.run(["focus-window", "\(id)"])
        let strip = h.settle(check)
        if !strip.isEmpty { return strip.map { "focus-window \(id): \($0)" } }
        if h.waitForFocus(id, during: "after `focus-window \(id)`") {
            h.lastTestFocus = id
            return []
        }
        return ["focus-window: " + focusState(id)]
    }

    /// Sends a command with no focus repair, waits until the strip passes `check`, then checks that the focus is
    /// still (or now) on `to`. The strip check comes first: when another app took the focus, `waitForFocus` gives
    /// it back with `focus-window`, which would also put right a wrong focused column or scroll.
    private func commandKeepingFocus(_ name: String, from: UInt32, to: UInt32,
                                     check: (WindowReport) -> [String]) -> [String] {
        _ = h.command(name, focus: from, repair: false)
        let strip = h.settle(check)
        if !strip.isEmpty { return strip.map { "\(name): \($0)" } }
        return h.waitForFocus(to, during: "after `\(name)`") ? [] : ["\(name): " + focusState(to)]
    }

    /// Why `id` does not have the focus, for a failure.
    private func focusState(_ id: UInt32) -> String {
        let f = h.frames()
        return "\(title(id, f)) has no focus: Striple focus \(h.state()?.focusedWindow.map { "\($0.id)" } ?? "none"), "
            + "test app active \(f?.active ?? false), key window \(f?.key.map(String.init) ?? "none")"
    }

    // MARK: c. Move

    func move() {
        record(Name.move) {
            let start = startOrder()
            if let bad = start.failure { return ([bad], "") }
            var order = start.order
            var col = start.focused
            let n = order.count
            let id = order[col]
            var fails: [String] = []
            var moves: [String] = []
            fails += takeFocus(id, check: stripCheck(count: n, order: order, focusedColumn: col))
            // Move the focused column to the far left, then back to the far right. The window keeps the focus.
            for (name, delta) in [("move-left", -1), ("move-right", 1)] {
                let steps = delta < 0 ? col : n - 1 - col
                for _ in 0..<steps where fails.isEmpty {
                    order.swapAt(col, col + delta)
                    col += delta
                    fails += commandKeepingFocus(name, from: id, to: id,
                                                 check: stripCheck(count: n, order: order, focusedColumn: col))
                    if !fails.isEmpty { break }
                    moves.append(name)
                }
            }
            return (fails, "\(moves.count) moves (\(moves.joined(separator: ", "))), order and frames as expected")
        }
    }

    // MARK: d. Widths

    func widths() {
        record(Name.widths) {
            let start = startOrder(atLeast: 1)
            if let bad = start.failure { return ([bad], "") }
            let n = start.order.count
            let id = start.order[start.focused]
            let presets = h.layout.presetWidths.sorted()
            var fails: [String] = []
            var seen: [String] = []
            fails += takeFocus(id, check: stripCheck(count: n, order: start.order, focusedColumn: start.focused))
            // A width command changes only the width: the order, the focused column and the focus stay.
            func step(_ name: String, _ next: Double) {
                guard fails.isEmpty else { return }
                proportions[id] = next
                let want = g.columnWidth(next)
                seen.append("\(name) -> \(Int(want.rounded()))")
                fails += commandKeepingFocus(name, from: id, to: id,
                                             check: stripCheck(count: n, order: start.order, focusedColumn: start.focused))
            }
            guard let smallest = presets.first else { return (["layout.presetWidths is empty"], "") }
            func nextPreset() -> Double { nextPresetWidth(id) ?? smallest }
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
            // At least 3 columns: after the close, the runner gives the focus to column 1 of at least 2, so "right
            // of the focused column" (column 2) is not "at the end".
            let start = startOrder(atLeast: 3)
            if let bad = start.failure { return ([bad], "") }
            let before = start.order
            let n = before.count
            // The middle column: closing it would leave a hole between two others.
            let victim = before[1]
            let name = title(victim, h.frames())
            let rest = before.filter { $0 != victim }
            var fails: [String] = []
            if !h.send(.close(title: name)) { fails.append("the test app did not close \(name)") } else { expected -= 1 }
            if fails.isEmpty {
                if h.lastTestFocus == victim { h.lastTestFocus = rest[0] }
                fails += h.settle(stripCheck(count: n - 1, order: rest)).map { "after closing \(name): \($0)" }
            }
            if fails.isEmpty {
                fails += takeFocus(rest[0], check: stripCheck(count: n - 1, order: rest, focusedColumn: 0))
                    .map { "focus on column 1: \($0)" }
            }
            let titlesBefore = Set(h.frames()?.windows.map(\.title) ?? [])
            if fails.isEmpty {
                if h.send(.open) { expected += 1 } else { fails.append("the test app did not open a window") }
            }
            // docs/SPEC.md: a new window opens directly to the right of the focused column (column 1 here).
            var opened = "?"
            if fails.isEmpty {
                fails += h.settle(timeout: 5, stripCheck(count: n) { [self] s, f in
                    let fresh = f.windows.filter { !titlesBefore.contains($0.title) }
                    guard let w = fresh.first else { return ["no new window yet"] }
                    opened = w.title
                    guard let d = testStrip(s) else { return ["no test strip"] }
                    let want = [rest[0], UInt32(w.number)] + rest.dropFirst()
                    return ids(d) == want ? [] : ["order \(ids(d).map { title($0, f) }), want \(want.map { title($0, f) }): "
                                                  + "\(w.title) right of the focused column 1"]
                }).map { "after opening: \($0)" }
            }
            return (fails, "closed \(name): \(n - 1) columns, no hole; focus on column 1, opened \(opened): column 2, "
                    + "right of the focused column, the others keep their order")
        }
    }

    // MARK: f. Float

    func float() {
        record(Name.float) {
            let start = startOrder()
            if let bad = start.failure { return ([bad], "") }
            let before = start.order
            let n = before.count
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

    /// The width `cycle-width` gives `id` next: the next larger preset, after the largest the smallest.
    func nextPresetWidth(_ id: UInt32) -> Double? {
        let presets = h.layout.presetWidths.sorted()
        return presets.first { $0 > proportion(id) + 0.01 } ?? presets.first
    }

    // MARK: i. Close while moving

    /// A window that closes while Striple animates it. The writes that reach it before Striple hears of the close
    /// fail with kAXErrorInvalidUIElement: the window is gone, that is not an AX error (docs/SPEC.md F2).
    func closeWhileMoving() {
        record(Name.closeWhileMoving) {
            let start = startOrder(atLeast: 3)
            if let bad = start.failure { return ([bad], "") }
            let order = start.order
            let n = order.count
            // `cycle-width` on column 1 moves every column right of it, so column 2 moves while it closes.
            let mover = order[0], victim = order[1]
            let name = title(victim, h.frames())
            let rest = order.filter { $0 != victim }
            var fails: [String] = []
            fails += takeFocus(mover, check: stripCheck(count: n, order: order, focusedColumn: 0)).map { "focus on column 1: \($0)" }
            guard fails.isEmpty else { return (fails, "") }
            guard let before = h.stats() else { return (["striple stats failed before the close"], "") }
            guard let next = nextPresetWidth(mover) else { return (["layout.presetWidths is empty"], "") }
            // Close at once, while the animation of `cycle-width` runs; the focus is checked after the close.
            let sent = Date()
            let r = h.command("cycle-width", focus: mover, repair: false)
            guard r.code == 0 else { return (["cycle-width: \(r.err)"], "") }
            proportions[mover] = next
            guard h.send(.close(title: name)) else { return (["the test app did not close \(name)"], "") }
            let closeMs = Date().timeIntervalSince(sent) * 1000
            expected -= 1
            // The strip check first: `waitForFocus` can give a stolen focus back with `focus-window`, which also
            // scrolls, so it must not run before the check of what Striple did.
            fails += h.settle(stripCheck(count: n - 1, order: rest, focusedColumn: 0)).map { "after closing \(name): \($0)" }
            if fails.isEmpty, !h.waitForFocus(mover, during: "after `cycle-width`") { fails.append("cycle-width: " + focusState(mover)) }
            guard let after = h.stats() else { return (fails + ["striple stats failed after the close"], "") }
            let errors = after.axErrors - before.axErrors
            if errors > 0 { fails.append("\(errors) AX errors while \(name) closed, want 0") }
            // Back to the default width and to n columns, so the later scenarios start as before.
            var restores = 0
            while fails.isEmpty, abs(proportion(mover) - h.layout.defaultWidth) > 0.01, restores < 10 {
                restores += 1
                guard let width = nextPresetWidth(mover) else { break }
                proportions[mover] = width
                fails += commandKeepingFocus("cycle-width", from: mover, to: mover,
                                             check: stripCheck(count: n - 1, order: rest, focusedColumn: 0)).map { "width back: \($0)" }
            }
            if fails.isEmpty {
                if h.send(.open) { expected += 1 } else { fails.append("the test app did not open a window") }
            }
            if fails.isEmpty { fails += h.settle(timeout: 5, stripCheck(count: n)).map { "after opening: \($0)" } }
            let closed = (after.closedWindowWrites ?? 0) - (before.closedWindowWrites ?? 0)
            let what = closed > 0 ? "\(closed) write(s) reached it after it closed, counted as closed-window writes"
                : "no write reached it after it closed"
            return (fails, String(format: "closed %@ %.0f ms after cycle-width started to move it; AX errors %d; ", name, closeMs, errors)
                    + what + "; width back to default, \(n) columns again")
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
        let own = s.frameOwnP50.flatMap { p50 in s.frameOwnP95.map { String(format: "p50 %.2f ms, p95 %.2f ms", p50, $0) } }
        let details = String(format: "animations %@; frame write p50 %.2f ms, p95 %.2f ms; Striple's part %@; "
                             + "command latency p50 %.2f ms, p95 %.2f ms; "
                             + "%d frames, %d window writes, %d skipped, %d coalesced; AX errors %d; "
                             + "CLI round trip p50 %.0f ms, p95 %.0f ms; settle p50 %.0f ms, p95 %.0f ms",
                             h.config.animations.rawValue, s.frameWriteP50, s.frameWriteP95, own ?? "not reported",
                             s.commandLatencyP50, s.commandLatencyP95, s.framesWritten,
                             s.windowWrites, s.skippedWrites, s.coalescedWrites, s.axErrors, cli.p50, cli.p95, settle.p50, settle.p95)
        h.log("stats: \(details)")
        let stats = PerformanceBudget.Stats(frameWriteP95: s.frameWriteP95, frameOwnP95: s.frameOwnP95,
                                            commandLatencyP95: s.commandLatencyP95, axErrors: s.axErrors,
                                            framesWritten: s.framesWritten)
        let v = PerformanceBudget.budget(h.config.animations).verdict(stats, settleP95: h.settleMs.isEmpty ? nil : settle.p95,
                                                                     settleTimeouts: h.settleTimeouts)
        add(.init(scenario: "h. Performance (striple stats)", result: v.result,
                  details: (v.failures.isEmpty ? "" : v.failures.joined(separator: "; ") + ". ") + details
                      + "; \(h.settleMs.count) settles, \(h.settleTimeouts) at the timeout"))
    }

    // MARK: g. Quit

    func quit() {
        record("g. SIGTERM: every test window ends fully on screen") {
            // The windows to check: the same ones before and after the quit, as many as the runner opened.
            let report = h.frames()
            let shown = Set(report?.windows.map(\.number) ?? [])
            var fails: [String] = []
            if shown.count != expected { fails.append("before SIGTERM the test app shows \(shown.count) windows, want \(expected)") }
            // The strip is wider than the display, so a column is parked or hangs over an edge. Without one, the
            // quit has nothing to restore and the check below proves nothing.
            let off = (report?.windows ?? []).filter { !FrameChecks.isFullyOnScreen($0.frame, displays: h.displayFrames()) }
            if off.isEmpty { fails.append("before SIGTERM every test window is fully on screen: the quit has nothing to restore") }
            let pid = h.striple?.processIdentifier ?? 0
            guard h.stopStriple(wait: 5) else { return (fails + ["Striple (pid \(pid)) did not quit within 5 s of SIGTERM"], "") }
            let code = h.striple?.terminationStatus ?? -1
            let displays = h.displayFrames()
            fails += h.settle { f in
                let now = Set(f.windows.map(\.number))
                let changed = now == shown ? [] : ["the test app shows windows \(now.sorted()), want the same as before SIGTERM \(shown.sorted())"]
                return changed + f.windows.filter { !FrameChecks.isFullyOnScreen($0.frame, displays: displays) }
                    .map { "\($0.title) \(FrameChecks.describe($0.frame)) is not fully on screen" }
            }
            if code != 0 { fails.append("Striple exit status \(code), want 0") }
            return (fails, "Striple quit with status \(code); the same \(shown.count) windows, off screen before: \(off.count), after: 0")
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
