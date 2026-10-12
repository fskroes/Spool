import CoreGraphics
import Foundation
import Testing
@testable import StripleE2EKit

/// The pure parts of the live E2E runner. The live run itself is `make e2e`, never `swift test`.
@Suite struct FrameChecksTests {
    /// A 2056x1329 display with a 39 pt menu bar and default gaps (8 inner, 8 outer).
    let g = StripGeometry(display: CGRect(x: 0, y: 0, width: 2056, height: 1329),
                          visible: CGRect(x: 0, y: 39, width: 2056, height: 1290), innerGap: 8,
                          outerTop: 8, outerBottom: 8, outerLeft: 8, outerRight: 8, sliver: 1)

    func col(_ t: String, _ x: Double, _ p: Double, y: Double = 47, h: Double = 1274) -> FrameChecks.Column {
        .init(title: t, frame: CGRect(x: x, y: y, width: g.columnWidth(p), height: h), proportion: p)
    }

    @Test func workAreaAndWidths() {
        #expect(g.work == CGRect(x: 8, y: 47, width: 2040, height: 1274))
        #expect(g.columnWidth(0.5) == 1016)
        #expect(g.columnWidth(1) == 2040)
        // Two half columns and the gap fill the work area exactly.
        #expect(g.totalWidth([0.5, 0.5]) == 2040)
        #expect(g.fits([0.5, 0.5]))
        #expect(!g.fits([0.5, 0.5, 0.5]))
    }

    @Test func twoColumnsThatFitPass() {
        #expect(FrameChecks.checkStrip([col("A", 8, 0.5), col("B", 1032, 0.5)], geometry: g).isEmpty)
    }

    @Test func aWrongGapFails() {
        let f = FrameChecks.checkStrip([col("A", 8, 0.5), col("B", 1040, 0.5)], geometry: g)
        #expect(f.contains { $0.hasPrefix("gap A -> B") })
    }

    @Test func roundingWithinTwoPointsPasses() {
        var b = col("B", 1033, 0.5)
        b.frame.size.width += 1
        #expect(FrameChecks.checkStrip([col("A", 8, 0.5), b], geometry: g).isEmpty)
    }

    @Test func aHoleAtTheLeftFails() {
        // Both fit, but the first starts at 300: the strip did not close up after a window closed.
        let f = FrameChecks.checkStrip([col("A", 300, 0.3), col("B", 300 + g.columnWidth(0.3) + 8, 0.3)], geometry: g)
        #expect(f.contains { $0.hasPrefix("hole") })
    }

    @Test func wrongHeightAndWidthFail() {
        let f = FrameChecks.checkStrip([col("A", 8, 0.5, h: 900)], geometry: g)
        #expect(f.contains { $0.contains("top/height") })
        let w = FrameChecks.checkStrip([.init(title: "A", frame: CGRect(x: 8, y: 47, width: 700, height: 1274), proportion: 0.5)], geometry: g)
        #expect(w.contains { $0.contains("width 700.0, want 1016.0") })
    }

    @Test func parkedColumnsAreAllowedWhenTheStripOverflows() {
        // Three half columns, focus on the last: the first is out of view and parked at the left and bottom.
        let parked = CGRect(x: -1015, y: 1328, width: 1016, height: 1274)
        let cols = [FrameChecks.Column(title: "A", frame: parked, proportion: 0.5), col("B", 8, 0.5), col("C", 1032, 0.5)]
        #expect(FrameChecks.place(parked, geometry: g) == .parkedLeft)
        #expect(FrameChecks.checkStrip(cols, geometry: g).isEmpty)
    }

    @Test func aParkedColumnWhenAllFitFails() {
        let parked = CGRect(x: 2055, y: 1328, width: 1016, height: 1274)
        let f = FrameChecks.checkStrip([col("A", 8, 0.5), .init(title: "B", frame: parked, proportion: 0.5)], geometry: g)
        #expect(f.contains { $0.contains("B is parked") })
    }

    @Test func allColumnsParkedFails() {
        // The strip scrolled out of view: every window keeps only its sliver. Before, this passed.
        let cols = [FrameChecks.Column(title: "A", frame: CGRect(x: -1015, y: 1328, width: 1016, height: 1274), proportion: 0.5),
                    FrameChecks.Column(title: "B", frame: CGRect(x: 2055, y: 1328, width: 1016, height: 1274), proportion: 0.5),
                    FrameChecks.Column(title: "C", frame: CGRect(x: 2055, y: 1328, width: 1016, height: 1274), proportion: 0.5)]
        #expect(FrameChecks.checkStrip(cols, geometry: g).contains("no column is visible: all 3 are parked"))
        #expect(FrameChecks.checkStrip([], geometry: g).isEmpty)
    }

    @Test func aParkedColumnWithoutASliverFails() {
        // Fully past the right edge, or fully below the display: macOS can move it to another display.
        for parked in [CGRect(x: 2056, y: 47, width: 1016, height: 1274), CGRect(x: 2055, y: 1329, width: 1016, height: 1274),
                       CGRect(x: -1016, y: 1328, width: 1016, height: 1274)] {
            let cols = [col("A", 8, 0.5), col("B", 1032, 0.5), .init(title: "C", frame: parked, proportion: 0.5)]
            #expect(FrameChecks.checkStrip(cols, geometry: g).contains { $0.hasPrefix("C is parked off the display") }, "\(parked)")
        }
        // The 1 pt sliver of Layout.physical passes.
        let ok = [col("A", 8, 0.5), col("B", 1032, 0.5), .init(title: "C", frame: CGRect(x: 2055, y: 1328, width: 1016, height: 1274), proportion: 0.5)]
        #expect(FrameChecks.checkStrip(ok, geometry: g).isEmpty)
    }

    @Test func swappedOrderFails() {
        let f = FrameChecks.checkStrip([col("B", 1032, 0.5), col("A", 8, 0.5)], geometry: g)
        #expect(f.contains { $0.hasPrefix("order") })
        let parked = CGRect(x: -1015, y: 1328, width: 1016, height: 1274)
        let g2 = FrameChecks.checkStrip([col("B", 8, 0.5), .init(title: "A", frame: parked, proportion: 0.5)], geometry: g)
        #expect(g2.contains { $0.contains("A is parkedLeft but comes after B") })
    }

    @Test func partlyVisibleColumnsSkipTheGapCheckOnly() {
        // The third column hangs over the right edge: Striple leaves it there when no display is to the right.
        let cols = [col("A", -500, 0.5), col("B", 524, 0.5), col("C", 1548, 0.5)]
        #expect(FrameChecks.checkStrip(cols, geometry: g).isEmpty)
    }

    @Test func inView() {
        #expect(FrameChecks.checkInView("A", CGRect(x: 8, y: 47, width: 1016, height: 1274), geometry: g).isEmpty)
        #expect(!FrameChecks.checkInView("A", CGRect(x: 1200, y: 47, width: 1016, height: 1274), geometry: g).isEmpty)
        #expect(!FrameChecks.checkInView("A", CGRect(x: -20, y: 47, width: 1016, height: 1274), geometry: g).isEmpty)
    }

    @Test func fullyOnScreen() {
        let displays = [CGRect(x: 0, y: 0, width: 2056, height: 1329), CGRect(x: 2056, y: 0, width: 1920, height: 1080)]
        #expect(FrameChecks.isFullyOnScreen(CGRect(x: 100, y: 100, width: 500, height: 400), displays: displays))
        #expect(FrameChecks.isFullyOnScreen(CGRect(x: 2100, y: 100, width: 500, height: 400), displays: displays))
        // Across two displays, parked at the bottom, or hanging off the left edge.
        #expect(!FrameChecks.isFullyOnScreen(CGRect(x: 1900, y: 100, width: 500, height: 400), displays: displays))
        #expect(!FrameChecks.isFullyOnScreen(CGRect(x: 100, y: 1328, width: 500, height: 400), displays: displays))
        #expect(!FrameChecks.isFullyOnScreen(CGRect(x: -1015, y: 47, width: 1016, height: 400), displays: displays))
    }

    @Test func topLeftCoordinates() {
        // An AppKit window 380 high whose bottom is 100 pt above the bottom of a 1329 high main display.
        #expect(Coordinates.topLeft(CGRect(x: 80, y: 100, width: 520, height: 380), primaryHeight: 1329)
                == CGRect(x: 80, y: 849, width: 520, height: 380))
    }
}

@Suite struct SafetyCheckTests {
    func entry(_ n: UInt32, pid: Int32, layer: Int = 0, owner: String? = nil, _ r: CGRect) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: n), kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowLayer as String: NSNumber(value: layer), kCGWindowOwnerName as String: owner ?? "App\(pid)",
         kCGWindowBounds as String: r.dictionaryRepresentation as NSDictionary]
    }

    @Test func snapshotKeepsNormalWindowsOfOtherApps() {
        let list = [entry(1, pid: 10, CGRect(x: 0, y: 0, width: 100, height: 100)),
                    entry(2, pid: 10, layer: 25, CGRect(x: 0, y: 0, width: 30, height: 24)),
                    entry(3, pid: 99, CGRect(x: 5, y: 5, width: 50, height: 50))]
        let s = SafetyCheck.snapshot(list, excluding: [99])
        #expect(s.map(\.number) == [1])
        #expect(s.first?.bounds == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(s.first?.owner == "App10")
    }

    @Test func snapshotComparesAppLayersBelowTheMenuBarAndSkipsSystemOwners() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 100)
        let list = [entry(1, pid: 10, layer: 3, r),     // a floating panel of an app
                    entry(2, pid: 10, layer: 8, r),     // a modal panel
                    entry(3, pid: 10, layer: 23, r),
                    entry(4, pid: 10, layer: 24, r),    // the main menu level and up: not compared
                    entry(5, pid: 10, layer: -1, r),
                    entry(6, pid: 20, owner: "Dock", r),
                    entry(7, pid: 21, owner: "Window Server", r)]
        #expect(SafetyCheck.snapshot(list, excluding: []).map(\.number) == [1, 2, 3])
    }

    @Test func aMovedOrResizedWindowIsAChange() {
        let a = WindowSnapshot(number: 1, pid: 10, owner: "Notes", layer: 0, bounds: CGRect(x: 191, y: 184, width: 1650, height: 998))
        let b = WindowSnapshot(number: 2, pid: 11, owner: "Safari", layer: 0, bounds: CGRect(x: 8, y: 47, width: 1016, height: 1274))
        var moved = a
        moved.bounds.origin.x += 1
        var resized = b
        resized.bounds.size.width -= 1
        #expect(SafetyCheck.changes(before: [a, b], after: [a, b]).isEmpty)
        let changes = SafetyCheck.changes(before: [a, b], after: [moved, resized])
        #expect(changes.map(\.before.number) == [1, 2])
        #expect(changes[0].description.contains("Notes (pid 10, window 1)"))
    }

    @Test func closedAndNewWindowsAreNoChange() {
        let a = WindowSnapshot(number: 1, pid: 10, owner: "Notes", layer: 0, bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        let c = WindowSnapshot(number: 3, pid: 10, owner: "Notes", layer: 0, bounds: CGRect(x: 9, y: 9, width: 10, height: 10))
        #expect(SafetyCheck.changes(before: [a], after: [c]).isEmpty)
    }
}

@Suite struct SafetyVerdictTests {
    func w(_ n: UInt32, x: Double = 0) -> WindowSnapshot {
        WindowSnapshot(number: n, pid: 10, owner: "Notes", layer: 0, bounds: CGRect(x: x, y: 0, width: 100, height: 100))
    }

    @Test func unchangedWindowsPass() {
        let v = SafetyCheck.verdict(before: [w(1), w(2), w(3)], after: [w(1), w(2), w(3), w(4)])
        #expect(v.result == .pass)
        #expect(v.details.hasPrefix("3 of 3 windows"))
    }

    @Test func aMovedWindowFails() {
        let v = SafetyCheck.verdict(before: [w(1), w(2)], after: [w(1), w(2, x: 8)])
        #expect(v.result == .fail)
        #expect(v.details.contains("window 2"))
    }

    @Test func tooFewWindowsLeftIsInconclusive() {
        // The user closed most windows: the compare proves too little, so it does not pass.
        #expect(SafetyCheck.verdict(before: [w(1), w(2), w(3)], after: [w(1)]).result == .skip)
        #expect(SafetyCheck.verdict(before: [w(1), w(2)], after: [w(1)]).result == .pass)
        // A move still fails, even when most windows are gone.
        #expect(SafetyCheck.verdict(before: [w(1), w(2), w(3)], after: [w(1, x: 1)]).result == .fail)
    }

    @Test func noWindowsToCompareIsASkip() {
        // Nothing to compare proves nothing: before, this was a PASS.
        #expect(SafetyCheck.verdict(before: [], after: [w(1)]).result == .skip)
        // Only background windows: also nothing that Striple could have moved.
        #expect(SafetyCheck.verdict(before: [helper(9, y: 0)], after: [helper(9, y: 0)]).result == .skip)
    }

    @Test func noSnapshotBeforeTheRunIsASkip() {
        // The setup failed before the snapshot (for example codesign of the test app): no compare was possible.
        let v = SafetyCheck.verdict(before: nil, after: [w(1)])
        #expect(v.result == .skip)
        #expect(v.details.contains("no snapshot"))
    }

    func helper(_ n: UInt32, y: Double) -> WindowSnapshot {
        WindowSnapshot(number: n, pid: 92849, owner: "AutoFill", layer: 0,
                       bounds: CGRect(x: 0, y: y, width: 312, height: 237), regularApp: false)
    }

    @Test func aBackgroundProcessThatResizesItsOwnWindowIsListedNotFailed() {
        // Seen live: the AutoFill helper of Safari (activation policy prohibited) resized its windows during a run.
        let v = SafetyCheck.verdict(before: [w(1), w(2), helper(9, y: 1092)], after: [w(1), w(2), helper(9, y: 1078)])
        #expect(v.result == .pass)
        #expect(v.details.hasPrefix("2 of 2 windows"))
        #expect(v.details.contains("Not counted, 1 window(s) of background processes changed"))
        #expect(v.details.contains("AutoFill (pid 92849, window 9)"))
    }

    @Test func aRegularAppStillFailsNextToABackgroundChange() {
        let v = SafetyCheck.verdict(before: [w(1), helper(9, y: 1092)], after: [w(1, x: 3), helper(9, y: 1078)])
        #expect(v.result == .fail)
        #expect(v.details.hasPrefix("Notes (pid 10, window 1)"))
        #expect(v.details.contains("AutoFill"))
    }

    // An app can turn regular during the run (for example when it opens its first window). Regular before or
    // after: a change fails.
    @Test func anAppThatTurnedRegularDuringTheRunCounts() {
        var after = helper(9, y: 1078)
        after.regularApp = true
        let v = SafetyCheck.verdict(before: [w(1), helper(9, y: 1092)], after: [w(1), after])
        #expect(v.result == .fail)
        #expect(v.details.hasPrefix("AutoFill (pid 92849, window 9)"))
        var before = helper(9, y: 1092)
        before.regularApp = true
        #expect(SafetyCheck.verdict(before: [w(1), before], after: [w(1), helper(9, y: 1078)]).result == .fail)
    }

    @Test func onlyBackgroundWindowsDoNotCountForTheRatio() {
        // Two background windows closed, the one app window stayed: the compare still proves the app window.
        let v = SafetyCheck.verdict(before: [w(1), helper(8, y: 0), helper(9, y: 0)], after: [w(1)])
        #expect(v.result == .pass)
    }

    @Test func snapshotAsksWhichOwnersAreRegularApps() {
        let list: [[String: Any]] = [10, 92849].map { pid in
            [kCGWindowNumber as String: NSNumber(value: pid), kCGWindowOwnerPID as String: NSNumber(value: pid),
             kCGWindowLayer as String: NSNumber(value: 0), kCGWindowOwnerName as String: "x",
             kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 1, height: 1).dictionaryRepresentation]
        }
        let s = SafetyCheck.snapshot(list, excluding: []) { $0 == 10 }
        #expect(s.map(\.regularApp) == [true, false])
    }
}

@Suite struct ReportTests {
    @Test func markdownTableAndExitCode() {
        let rows = [Report.Row(scenario: "a | b", result: .pass, details: "one\ntwo"),
                    Report.Row(scenario: "c", result: .fail, details: "bad")]
        let md = Report.markdown(title: "T", rows: rows, notes: ["n"])
        #expect(md.contains("| a \\| b | PASS | one<br>two |"))
        #expect(md.contains("Result: **FAIL** (1 of 2 checks did not pass: 1 FAIL, 0 SKIP)"))
        #expect(md.contains("- n"))
        #expect(Report.exitCode(rows) == 1)
        #expect(Report.exitCode([rows[0]]) == 0)
        #expect(Report.exitCode([]) == 1)
        #expect(Report.exitCode([Report.Row(scenario: "s", result: .skip, details: "")]) == 1)
    }

    // The header and the exit code must agree: a SKIP proves nothing, so the header must not say PASS.
    @Test func aSkipMakesTheHeaderFail() {
        let rows = [Report.Row(scenario: "a", result: .pass, details: ""), Report.Row(scenario: "s", result: .skip, details: "")]
        #expect(Report.markdown(title: "T", rows: rows, notes: []).contains("Result: **FAIL** (1 of 2 checks did not pass: 0 FAIL, 1 SKIP)"))
        #expect(Report.markdown(title: "T", rows: [], notes: []).contains("Result: **FAIL** (no checks ran)"))
        #expect(Report.markdown(title: "T", rows: [rows[0]], notes: []).contains("Result: **PASS** (1 checks)"))
        for r in [rows, [], [rows[0]]] {
            #expect(Report.markdown(title: "T", rows: r, notes: []).contains("**PASS**") == (Report.exitCode(r) == 0))
        }
    }
}

@Suite struct WindowCommandTests {
    @Test func linesRoundTrip() {
        for c in [WindowCommand.open, .quit, .close(title: "E2E 2")] { #expect(WindowCommand(line: c.line) == c) }
        #expect(WindowCommand(line: "close ") == nil)
        #expect(WindowCommand(line: "fly") == nil)
    }

    @Test func onlyCompleteLinesRun() {
        #expect(WindowCommand.completeLines("") == [])
        #expect(WindowCommand.completeLines("open\nclose E2E 1") == ["open"])
        #expect(WindowCommand.completeLines("open\nquit\n") == ["open", "quit"])
    }

    @Test func reportDecodes() throws {
        let r = WindowReport(pid: 5, seq: 2, commandsDone: 1, windows: [ReportedWindow(title: "E2E 1", number: 42, x: 8, y: 47, w: 1016, h: 1274)])
        let back = try JSONDecoder().decode(WindowReport.self, from: JSONEncoder().encode(r))
        #expect(back == r)
        #expect(back.window(number: 42)?.frame == CGRect(x: 8, y: 47, width: 1016, height: 1274))
        #expect(back.window(title: "E2E 1")?.number == 42)
        #expect(!back.hasSystemFocus(42))
        let focused = WindowReport(pid: 5, seq: 3, commandsDone: 1, windows: r.windows, active: true, key: 42)
        #expect(focused.hasSystemFocus(42))
        #expect(!focused.hasSystemFocus(7))
        #expect(!WindowReport(pid: 5, seq: 3, commandsDone: 1, windows: r.windows, active: false, key: 42).hasSystemFocus(42))
    }
}

@Suite struct ManagedCheckTests {
    @Test func noStateReadIsASkip() {
        #expect(ManagedCheck.verdict(statesRead: 0, foreign: [:]).result == .skip)
    }

    @Test func statesWithOnlyTestWindowsPass() {
        let v = ManagedCheck.verdict(statesRead: 40, foreign: [:])
        #expect(v.result == .pass)
        #expect(v.details.contains("40"))
    }

    @Test func aForeignWindowFails() {
        let v = ManagedCheck.verdict(statesRead: 3, foreign: ["7": "com.apple.Safari \"Start\""])
        #expect(v.result == .fail)
        #expect(v.details == "7: com.apple.Safari \"Start\"")
        // Also when the state read that saw it is the only one.
        #expect(ManagedCheck.verdict(statesRead: 0, foreign: ["7": "x"]).result == .fail)
    }
}

@Suite struct StripCheckTests {
    let g = StripGeometry(display: CGRect(x: 0, y: 0, width: 2056, height: 1329),
                          visible: CGRect(x: 0, y: 39, width: 2056, height: 1290), innerGap: 8,
                          outerTop: 8, outerBottom: 8, outerLeft: 8, outerRight: 8, sliver: 1)
    /// Windows 1, 2, 3 at half width; 3 is out of view on the right (parked with a 1 pt sliver).
    var report: WindowReport {
        WindowReport(pid: 1, seq: 1, commandsDone: 0, windows: [
            ReportedWindow(title: "E2E 1", number: 1, frame: CGRect(x: 8, y: 47, width: 1016, height: 1274)),
            ReportedWindow(title: "E2E 2", number: 2, frame: CGRect(x: 1032, y: 47, width: 1016, height: 1274)),
            ReportedWindow(title: "E2E 3", number: 3, frame: CGRect(x: 2055, y: 1328, width: 1016, height: 1274)),
        ])
    }
    let strip = StripView(columns: [[1], [2], [3]], focusedColumn: 0)

    func check(_ s: StripView?, _ e: StripExpectation, _ r: WindowReport? = nil) -> [String] {
        StripCheck.failures(s, r ?? report, expect: e, geometry: g, proportion: { _ in 0.5 })
    }

    @Test func theExpectedStripPasses() {
        #expect(check(strip, .init(count: 3, order: [1, 2, 3], focusedColumn: 0)).isEmpty)
    }

    @Test func noStripFails() {
        #expect(check(nil, .init(count: 3)) == ["no strip holds a test window"])
    }

    @Test func aWrongColumnCountFails() {
        #expect(check(strip, .init(count: 2)).contains("strip has 3 columns, want 2"))
    }

    @Test func aWrongOrderFails() {
        // Scenario c: move-left did nothing to the order.
        #expect(check(strip, .init(count: 3, order: [2, 1, 3])).contains { $0.hasPrefix("order [\"E2E 1\", \"E2E 2\"") })
    }

    @Test func aWrongFocusedColumnFails() {
        #expect(check(strip, .init(count: 3, focusedColumn: 1)).contains("focused column 1, want 2"))
    }

    @Test func aColumnWithTwoWindowsFails() {
        let s = StripView(columns: [[1, 3], [2]], focusedColumn: 0)
        #expect(check(s, .init(count: 2)).contains("a column holds 2 windows"))
    }

    @Test func aStripWindowTheAppDoesNotShowFails() {
        let s = StripView(columns: [[1], [2], [9]], focusedColumn: 0)
        #expect(check(s, .init(count: 3)).contains("window 9 is in the strip but the test app does not show it"))
    }

    @Test func aFocusedColumnOutOfViewFails() {
        // Focus on the parked column 3: it must be scrolled into view.
        let s = StripView(columns: [[1], [2], [3]], focusedColumn: 2)
        #expect(check(s, .init(count: 3)).contains { $0.hasPrefix("E2E 3") })
        #expect(check(s, .init(count: 3, focusedInView: false)).isEmpty)
    }

    @Test func aFocusedColumnThatDoesNotExistFails() {
        // Before, the in-view check was skipped without a failure.
        let s = StripView(columns: [[1], [2], [3]], focusedColumn: 5)
        #expect(check(s, .init(count: 3)).contains("focused column 6 does not exist (3 columns)"))
        let empty = StripView(columns: [], focusedColumn: 0)
        #expect(check(empty, .init(count: 0)).contains("focused column 1 does not exist (0 columns)"))
    }

    @Test func focusNeedsStripleAndTheSystem() {
        var r = report
        r.active = true
        r.key = 2
        #expect(StripCheck.hasFocus(2, stripleFocus: 2, report: r))
        #expect(!StripCheck.hasFocus(2, stripleFocus: 1, report: r), "Striple focus elsewhere")
        r.active = false
        #expect(!StripCheck.hasFocus(2, stripleFocus: 2, report: r), "test app not frontmost")
        r.active = true
        r.key = 1
        #expect(!StripCheck.hasFocus(2, stripleFocus: 2, report: r), "another window is key")
        #expect(!StripCheck.hasFocus(2, stripleFocus: 2, report: nil), "no report")
    }
}

@Suite struct SettleTrackerTests {
    /// `#expect` cannot call a mutating method, so the tests feed the tracker through this box.
    final class Feed {
        var tracker = SettleTracker()
        func callAsFunction(_ w: [ReportedWindow], failures: [String], now: Double) -> Bool {
            tracker.observe(w, failures: failures, now: now)
        }
    }

    let a = [ReportedWindow(title: "A", number: 1, x: 0, y: 0, w: 10, h: 10)]
    let b = [ReportedWindow(title: "A", number: 1, x: 5, y: 0, w: 10, h: 10)]

    @Test func settlesAfterTheFramesStayStillFor250ms() {
        let t = Feed()
        #expect(!t(a, failures: [], now: 0))
        #expect(!t(a, failures: [], now: 0.2))
        #expect(t.tracker.last == ["frames did not stay still"])
        #expect(t(a, failures: [], now: 0.25))
        #expect(t.tracker.last.isEmpty)
    }

    @Test func aMoveRestartsTheWait() {
        let t = Feed()
        #expect(!t(a, failures: [], now: 0))
        #expect(!t(b, failures: [], now: 0.2)) // still animating
        #expect(!t(b, failures: [], now: 0.4))
        #expect(t(b, failures: [], now: 0.45))
    }

    @Test func aFailedCheckRestartsTheWaitAndIsReported() {
        let t = Feed()
        #expect(!t(a, failures: [], now: 0))
        #expect(!t(a, failures: ["strip has 2 columns, want 3"], now: 0.2))
        #expect(t.tracker.last == ["strip has 2 columns, want 3"])
        #expect(!t(a, failures: [], now: 0.3))
        #expect(!t(a, failures: [], now: 0.5))
        #expect(t(a, failures: [], now: 0.55))
    }

    @Test func nothingObservedReportsNoFrames() {
        #expect(SettleTracker().last == ["no frame report from the test app"])
    }
}

@Suite struct PerformanceBudgetTests {
    @Test func aRunInTheBudgetPasses() {
        #expect(PerformanceBudget.check(frameWriteP95: 5.76, settleP95: 420, axErrors: 0).isEmpty)
        // No settle samples (every scenario failed before it settled): only the frame writes count.
        #expect(PerformanceBudget.check(frameWriteP95: 11.68, settleP95: nil, axErrors: 0).isEmpty)
    }

    @Test func eachLimitFailsOnItsOwn() {
        #expect(PerformanceBudget.check(frameWriteP95: 16, settleP95: 100, axErrors: 0) == ["frame write p95 16.00 ms, want < 16 ms"])
        #expect(PerformanceBudget.check(frameWriteP95: 1, settleP95: 2000, axErrors: 0) == ["settle p95 2000 ms, want < 2000 ms"])
        #expect(PerformanceBudget.check(frameWriteP95: 1, settleP95: 100, axErrors: 2) == ["AX errors 2, want 0"])
        #expect(PerformanceBudget.check(frameWriteP95: 30, settleP95: 2500, axErrors: 1).count == 3)
    }

    @Test func nothingMeasuredIsASkip() {
        // Tiling failed: no frames, no settles. Zeros must not pass.
        let none = PerformanceBudget.verdict(frameWriteP95: 0, settleP95: nil, axErrors: 0, framesWritten: 0)
        #expect(none.result == .skip)
        #expect(none.failures == ["nothing to measure: Striple wrote no frames, no settle was timed"])
        #expect(PerformanceBudget.verdict(frameWriteP95: 0, settleP95: 300, axErrors: 0, framesWritten: 0).result == .skip)
        #expect(PerformanceBudget.verdict(frameWriteP95: 4, settleP95: nil, axErrors: 0, framesWritten: 50).result == .skip)
    }

    @Test func theVerdictPassesInTheBudgetAndFailsOnATimeout() {
        #expect(PerformanceBudget.verdict(frameWriteP95: 4.75, settleP95: 980, axErrors: 0, framesWritten: 699).result == .pass)
        let slow = PerformanceBudget.verdict(frameWriteP95: 4.75, settleP95: 980, axErrors: 0, framesWritten: 699, settleTimeouts: 1)
        #expect(slow.result == .fail)
        #expect(slow.failures == ["1 settle(s) reached their timeout"])
        #expect(PerformanceBudget.verdict(frameWriteP95: 20, settleP95: 980, axErrors: 0, framesWritten: 699).result == .fail)
    }
}

@Suite struct E2ERunRecordTests {
    let r = E2ERunRecord(home: "/tmp/striple-e2e-AbC123", runnerPID: 100, runnerStart: "1700000000.5",
                         striplePID: 200, stripleStart: "1700000001.25")

    @Test func anOrphanNeedsTheSamePIDAndStartTime() {
        #expect(r.isOrphan(currentStart: "1700000001.25"))
        // The PID now belongs to another process, or no process has it.
        #expect(!r.isOrphan(currentStart: "1700009999.0"))
        #expect(!r.isOrphan(currentStart: nil))
        // Striple never started.
        #expect(!E2ERunRecord(home: r.home, runnerPID: 100, runnerStart: "1").isOrphan(currentStart: "1"))
    }

    @Test func aLiveRunnerKeepsItsRun() {
        #expect(r.runnerIsAlive(currentRunnerStart: "1700000000.5"))
        #expect(!r.runnerIsAlive(currentRunnerStart: nil))
        #expect(!r.runnerIsAlive(currentRunnerStart: "1700000000.6"))
    }

    @Test func onlyAFolderTheRunnerMadeIsDeletable() {
        #expect(r.homeIsDeletable)
        for home in ["/tmp/striple-e2e-", "/tmp/striple-e2e-x/../../Users", "/tmp/striple-e2e-..", "/Users/x",
                     "/tmp/striple-e2e-a/b", "tmp/striple-e2e-a", "/private/tmp/striple-e2e-a"] {
            #expect(!E2ERunRecord(home: home, runnerPID: 1, runnerStart: "1").homeIsDeletable, "\(home)")
        }
    }

    @Test func roundTrip() throws {
        #expect(try JSONDecoder().decode(E2ERunRecord.self, from: JSONEncoder().encode(r)) == r)
    }
}
