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
    func entry(_ n: UInt32, pid: Int32, layer: Int = 0, _ r: CGRect) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: n), kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowLayer as String: NSNumber(value: layer), kCGWindowOwnerName as String: "App\(pid)",
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

    @Test func noWindowsPass() {
        #expect(SafetyCheck.verdict(before: [], after: [w(1)]).result == .pass)
    }
}

@Suite struct ReportTests {
    @Test func markdownTableAndExitCode() {
        let rows = [Report.Row(scenario: "a | b", result: .pass, details: "one\ntwo"),
                    Report.Row(scenario: "c", result: .fail, details: "bad")]
        let md = Report.markdown(title: "T", rows: rows, notes: ["n"])
        #expect(md.contains("| a \\| b | PASS | one<br>two |"))
        #expect(md.contains("Result: **FAIL** (1 of 2 checks failed)"))
        #expect(md.contains("- n"))
        #expect(Report.exitCode(rows) == 1)
        #expect(Report.exitCode([rows[0]]) == 0)
        #expect(Report.exitCode([]) == 1)
        #expect(Report.exitCode([Report.Row(scenario: "s", result: .skip, details: "")]) == 1)
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
