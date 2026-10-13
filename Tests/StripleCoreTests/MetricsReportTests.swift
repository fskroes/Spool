import Foundation
import Testing
@testable import StripleCore

@Suite struct MetricsReportTests {
    func budget(_ r: MetricsReport, _ name: String) -> MetricsReport.BudgetResult? { r.budgets.first { $0.budget.name == name } }

    func day(_ key: String, _ edit: (inout DayMetrics) -> Void) -> DayMetrics {
        var d = DayMetrics(day: key)
        edit(&d)
        return d
    }

    @Test func noDaysGiveNoDataForEveryBudget() {
        let r = MetricsReport.make(days: [])
        #expect(r.firstDay == nil && r.lastDay == nil && r.dayCount == 0)
        #expect(r.total == DayMetrics(day: ""))
        #expect(r.budgets.map(\.budget) == MetricsBudget.live)
        #expect(r.budgets.allSatisfy { $0.value == nil && $0.pass == nil })
        #expect(r.commands.isEmpty && r.friction.isEmpty && r.slowApps.isEmpty)
    }

    @Test func budgetsUseTheMergedDays() {
        let a = day("2026-10-12") { d in
            for _ in 0..<95 { d.frameWrite.add(3) }
            d.ticks = 150
            d.slowTicks = 1
            d.activeSeconds = 100
            d.cpuSeconds = 0.5
        }
        let b = day("2026-10-13") { d in
            for _ in 0..<5 { d.frameWrite.add(30) }
            d.commandLatency.add(20)
            d.ticks = 50
            d.slowTicks = 1
            d.activeSeconds = 100
            d.cpuSeconds = 3.5
            d.events = ["unclean.exit": 1]
        }
        let r = MetricsReport.make(days: [a, b])
        #expect(r.firstDay == "2026-10-12" && r.lastDay == "2026-10-13" && r.dayCount == 2)
        #expect(r.total.day == "2026-10-13")
        #expect(r.total.frameWrite.count == 100)
        // Rank 95 of 100 is the last 3 ms sample.
        #expect(budget(r, "frame-write-p95")?.value == 3)
        #expect(budget(r, "frame-write-p95")?.pass == true)
        #expect(budget(r, "command-latency-p95")?.value == 20)
        #expect(budget(r, "command-latency-p95")?.pass == false)
        #expect(budget(r, "command-settle-p95")?.value == nil)
        #expect(budget(r, "command-settle-p95")?.pass == nil)
        #expect(budget(r, "slow-tick-ratio")?.value == 1)
        #expect(budget(r, "slow-tick-ratio")?.pass == true)
        #expect(budget(r, "cpu-while-active")?.value == 2)
        #expect(budget(r, "cpu-while-active")?.pass == false)
        #expect(budget(r, "unclean-exits")?.value == 1)
        #expect(budget(r, "unclean-exits")?.pass == false)
    }

    @Test func budgetsWithoutDataHaveNoValue() {
        let r = MetricsReport.make(days: [DayMetrics(day: "2026-10-13")])
        for name in ["frame-write-p95", "command-latency-p95", "command-settle-p95", "slow-tick-ratio", "cpu-while-active"] {
            #expect(budget(r, name)?.value == nil)
            #expect(budget(r, name)?.pass == nil)
        }
        // A day file without the event means zero unclean exits.
        #expect(budget(r, "unclean-exits")?.value == 0)
        #expect(budget(r, "unclean-exits")?.pass == true)
    }

    @Test func anUnknownBudgetHasNoValue() {
        let d = day("2026-10-13") { $0.frameWrite.add(1) }
        let r = MetricsReport.make(days: [d], budgets: [MetricsBudget(name: "nope", limit: 1, unit: "ms")])
        #expect(r.budgets.count == 1)
        #expect(r.budgets[0].value == nil && r.budgets[0].pass == nil)
    }

    @Test func rowsAreSortedWithTies() {
        let d = day("2026-10-13") { d in
            d.commands = ["wider": ["cli": 2], "focus-left": ["hotkey": 3, "cli": 2], "center-column": ["menu": 2],
                          "narrower": ["cli": 0]]
            var a = AppMetrics(), b = AppMetrics(), c = AppMetrics(), idle = AppMetrics()
            a.friction = ["user.drag": 2, "app.correction": 2]
            b.friction = ["user.resize": 2, "focus.bounce": 5]
            c.friction = ["early.resize": 0]
            for _ in 0..<4 { a.axWrite.add(4) }
            b.axWrite.add(4)
            c.axWrite.add(100)
            idle.axErrors = 3
            d.apps = ["com.example.b": b, "com.example.a": a, "com.example.c": c, "com.example.idle": idle]
        }
        let r = MetricsReport.make(days: [d])
        #expect(r.commands.map(\.name) == ["focus-left", "center-column", "wider"])
        #expect(r.commands[0].total == 5 && r.commands[0].bySource == ["hotkey": 3, "cli": 2])
        #expect(r.friction.map { "\($0.bundleID) \($0.kind) \($0.count)" } == [
            "com.example.b focus.bounce 5",
            "com.example.a app.correction 2",
            "com.example.a user.drag 2",
            "com.example.b user.resize 2",
        ])
        #expect(r.slowApps.map(\.bundleID) == ["com.example.c", "com.example.a", "com.example.b"])
        #expect(r.slowApps[1].writes == 4 && r.slowApps[1].axP50 == 4 && r.slowApps[1].axP95 == 4)
    }

    @Test func theSameInputGivesTheSameOutput() throws {
        let days = (10...13).map { n in
            day("2026-10-\(n)") { d in
                d.frameWrite.add(Double(n))
                d.commands = ["focus-left": ["hotkey": n], "wider": ["cli": n], "narrower": ["menu": n]]
                var app = AppMetrics()
                app.axWrite.add(Double(n))
                app.friction = ["user.drag": n % 2, "user.resize": n % 2]
                d.apps = ["com.example.\(n % 3)": app, "com.example.x\(n)": app]
            }
        }
        let a = MetricsReport.make(days: days), b = MetricsReport.make(days: days)
        #expect(a == b)
        #expect(a.renderText() == b.renderText())
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        #expect(try e.encode(a) == e.encode(b))
    }

    @Test func renderTextShowsPassFailAndNoData() {
        let d = day("2026-10-13") { d in
            d.frameWrite.add(2)
            d.commandLatency.add(40)
            d.activeSeconds = 3725
            d.appVersions = ["1.0"]
            d.events = ["swipe": 4, "observer.repair": 2]
            d.columnsPerStrip = ["2": 3, "10+": 1]
            for i in 0..<12 { d.commands["cmd-\(i)"] = ["hotkey": i + 1, "cli": 1] }
            var app = AppMetrics()
            app.axWrite.add(3)
            app.axErrors = 1
            app.friction = ["user.drag": 2]
            d.apps = ["com.example.a": app]
        }
        let text = MetricsReport.make(days: [d], skipped: ["2026-10-09.json"]).renderText()
        let lines = text.components(separatedBy: "\n")
        func line(_ prefix: String) -> String? { lines.first { $0.hasPrefix(prefix) } }
        #expect(line("  frame-write-p95")?.hasSuffix("PASS") == true)
        #expect(line("  command-latency-p95")?.hasSuffix("FAIL") == true)
        #expect(line("  command-settle-p95")?.hasSuffix("no data") == true)
        #expect(line("  frame-write-p95")?.contains("2.00 ms") == true)
        #expect(line("  frame-write-p95")?.contains("limit 8 ms") == true)
        #expect(line("  command-latency-p95")?.contains("limit 16.7 ms") == true)
        #expect(text.hasPrefix("Striple metrics: 2026-10-13 (1 day with data)\n"))
        #expect(text.contains("Active time: 1h 02m"))
        #expect(text.contains("Commands (top 10 of 12)"))
        #expect(line("  cmd-11")?.contains("hotkey 12, cli 1") == true)
        #expect(line("  cmd-1 ") == nil)
        #expect(text.contains("Columns per strip: 2: 3, 10+: 1"))
        #expect(line("  observer.repair")?.hasSuffix(" 2") == true)
        #expect(line("  ax.errors")?.hasSuffix(" 1") == true)
        #expect(text.contains("  2026-10-09.json"))
        #expect(text.contains("Friction\n  com.example.a  user.drag  2"))
        // Plain text for any terminal: no colors, no emoji, no em dash, no trailing spaces, short lines.
        #expect(!text.contains("\u{1B}") && !text.contains("\u{2014}"))
        #expect(text.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(lines.allSatisfy { !$0.hasSuffix(" ") && $0.count <= 80 })
        // Budget values line up.
        let budgetLines = lines.filter { $0.contains("limit ") }
        #expect(Set(budgetLines.map { $0.range(of: "limit")!.lowerBound.utf16Offset(in: $0) }).count == 1)
    }

    @Test func renderTextWithoutDataSaysSo() {
        let text = MetricsReport.make(days: []).renderText()
        #expect(text.hasPrefix("Striple metrics: no data yet\n"))
        #expect(text.components(separatedBy: "no data").count - 1 >= MetricsBudget.live.count + 1)
        #expect(!text.contains("PASS") && !text.contains("FAIL"))
        #expect(text.contains("Commands: none"))
    }
}

@Suite struct MetricsMarkTests {
    typealias F = MetricsFixtures

    func state() -> EngineState {
        let w = { (id: WindowID, title: String) in WindowInfo(id: id, pid: 42, bundleID: "com.example.a", title: title) }
        return EngineState(
            running: true, accessibilityTrusted: true, focusedWindow: w(1, "Secret plan.pages"),
            displays: [
                .init(id: "d1", name: "Built-in", enabled: true, spaceID: 7, focusedColumn: 0, scroll: 0,
                      columns: [[w(1, "Secret plan.pages"), w(2, "Inbox (3)")], [w(3, "Bank")]]),
                .init(id: "d2", name: "External", enabled: false, spaceID: 8, focusedColumn: 0, scroll: 12,
                      columns: [[w(4, "Chat with Ann")]]),
            ],
            floating: [w(5, "Password manager"), w(6, "")])
    }

    /// Every string value under a "title" key, anywhere in the JSON.
    func titles(_ json: Any) -> [String] {
        if let d = json as? [String: Any] {
            return d.flatMap { k, v in (k == "title" ? [v as? String ?? "?"] : []) + titles(v) }
        }
        if let a = json as? [Any] { return a.flatMap(titles) }
        return []
    }

    @Test func redactionRemovesEveryTitle() throws {
        let original = state()
        let r = MetricsMark.redacted(original)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r))
        let found = titles(json)
        #expect(found.count == 7)
        #expect(found.allSatisfy { $0.isEmpty })
        // Nothing else changes.
        var expected = original
        expected.focusedWindow?.title = ""
        expected.displays[0].columns = [[WindowInfo(id: 1, pid: 42, bundleID: "com.example.a"), WindowInfo(id: 2, pid: 42, bundleID: "com.example.a")],
                                        [WindowInfo(id: 3, pid: 42, bundleID: "com.example.a")]]
        expected.displays[1].columns = [[WindowInfo(id: 4, pid: 42, bundleID: "com.example.a")]]
        expected.floating = [WindowInfo(id: 5, pid: 42, bundleID: "com.example.a"), WindowInfo(id: 6, pid: 42, bundleID: "com.example.a")]
        #expect(r == expected)
    }

    @Test func logTailKeepsTheWindowAndContinuationLines() {
        let now = ISO8601DateFormatter.fractional.date(from: "2026-10-13T10:00:00.000Z")!
        let log = """
        orphan line from before a rotation
        2026-10-13T09:58:00.000Z too old
        old continuation
        2026-10-13T09:59:00.000Z at the window start
        2026-10-13T09:59:30.500Z error: something
          detail line 1

        detail line 3
        2026-10-13 09:59:40 not an ISO time, so a continuation
        2026-10-13T09:59:59.999Z last before now
        2026-10-13T10:00:00.001Z after now
        after-now continuation
        2026-10-13T09:59:50.000Z back in the window

        """
        let tail = MetricsMark.logTail(log, now: now)
        #expect(tail == [
            "2026-10-13T09:59:00.000Z at the window start",
            "2026-10-13T09:59:30.500Z error: something",
            "  detail line 1",
            "",
            "detail line 3",
            "2026-10-13 09:59:40 not an ISO time, so a continuation",
            "2026-10-13T09:59:59.999Z last before now",
            "2026-10-13T09:59:50.000Z back in the window",
        ])
        #expect(MetricsMark.logTail(log, now: now, window: 0.5) == ["2026-10-13T09:59:59.999Z last before now"])
        #expect(MetricsMark.logTail("", now: now).isEmpty)
        #expect(MetricsMark.logTail("2026-10-13T11:59:59.000+02:00 local offset\r\nnext\r\n", now: now) == ["2026-10-13T11:59:59.000+02:00 local offset", "next"])
    }

    @Test func writeSavesEveryFileInAUniqueFolder() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let marks = dir.appendingPathComponent("marks", isDirectory: true)
        let cal = F.calendar()
        let now = F.date(2026, 10, 13, 9, 5, 7)
        var day = DayMetrics(day: "2026-10-13")
        day.events = ["mark": 1]
        let stats = EngineStats(uptimeSeconds: 12, framesWritten: 3)
        let first = try MetricsMark.write(note: "jumped left", state: state(), stats: stats, day: day,
                                          logLines: ["2026-10-13T07:05:00.000Z a", "  b"], marksDirectory: marks,
                                          now: now, calendar: cal)
        #expect(first.lastPathComponent == "2026-10-13T09-05-07")
        let fm = FileManager.default
        #expect(Set(try fm.contentsOfDirectory(atPath: first.path)) == ["note.txt", "state.json", "stats.json", "day.json", "engine.log"])
        #expect(try String(contentsOf: first.appendingPathComponent("note.txt"), encoding: .utf8) == "jumped left")
        #expect(try String(contentsOf: first.appendingPathComponent("engine.log"), encoding: .utf8) == "2026-10-13T07:05:00.000Z a\n  b\n")
        let savedState = try JSONDecoder().decode(EngineState.self, from: Data(contentsOf: first.appendingPathComponent("state.json")))
        #expect(savedState == MetricsMark.redacted(state()))
        let stateText = try String(contentsOf: first.appendingPathComponent("state.json"), encoding: .utf8)
        #expect(!stateText.contains("Secret") && !stateText.contains("Bank") && !stateText.contains("Password"))
        #expect(try JSONDecoder().decode(EngineStats.self, from: Data(contentsOf: first.appendingPathComponent("stats.json"))) == stats)
        #expect(try JSONDecoder().decode(DayMetrics.self, from: Data(contentsOf: first.appendingPathComponent("day.json"))) == day)

        let second = try MetricsMark.write(note: "", state: nil, stats: nil, day: nil, logLines: [], marksDirectory: marks,
                                           now: now, calendar: cal)
        let third = try MetricsMark.write(note: "", state: nil, stats: nil, day: nil, logLines: [], marksDirectory: marks,
                                          now: now, calendar: cal)
        #expect(second.lastPathComponent == "2026-10-13T09-05-07-2")
        #expect(third.lastPathComponent == "2026-10-13T09-05-07-3")
        #expect(Set(try fm.contentsOfDirectory(atPath: second.path)) == ["note.txt", "engine.log"])
        #expect(try Data(contentsOf: second.appendingPathComponent("note.txt")).isEmpty)
        #expect(try Data(contentsOf: second.appendingPathComponent("engine.log")).isEmpty)
        // The folder name follows the calendar's time zone.
        let utc = try MetricsMark.write(note: "", state: nil, stats: nil, day: nil, logLines: [], marksDirectory: marks,
                                        now: now, calendar: F.calendar("UTC"))
        #expect(utc.lastPathComponent == "2026-10-13T07-05-07")
    }
}

extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}
