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

    @Test func aNonFiniteBudgetValueIsNoDataAndJSONStillEncodes() throws {
        let d = day("2026-10-13") { d in
            d.activeSeconds = 1e-310
            d.cpuSeconds = 1
        }
        let r = MetricsReport.make(days: [d])
        #expect(budget(r, "cpu-while-active")?.value == nil)
        #expect(budget(r, "cpu-while-active")?.pass == nil)
        #expect(budget(r, "unclean-exits")?.value == 0)
        let json = try JSONEncoder().encode(r)
        #expect(!json.isEmpty)
        let line = r.renderText().split(separator: "\n").first { $0.contains("cpu-while-active") }
        #expect(line?.contains("no data") == true)
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

    @Test func theOutputDoesNotDependOnInsertionOrder() throws {
        func build(reversed: Bool) -> [DayMetrics] {
            func ordered<T>(_ items: [T]) -> [T] { reversed ? items.reversed() : items }
            let days = (1...6).map { n -> DayMetrics in
                var d = DayMetrics(day: "2026-10-0\(n)")
                d.frameWrite.add(Double(n))
                d.ticks = 10 * n
                d.slowTicks = n
                // A different capacity gives a different order inside the dictionary.
                var commands = [String: [String: Int]](minimumCapacity: reversed ? 64 : 1)
                var events = [String: Int](minimumCapacity: reversed ? 64 : 1)
                var apps = [String: AppMetrics](minimumCapacity: reversed ? 64 : 1)
                for (i, name) in ordered(["focus-left", "focus-right", "wider", "narrower", "fling", "mark"]).enumerated() {
                    var sources = [String: Int](minimumCapacity: reversed ? 16 : 1)
                    for source in ordered(["hotkey", "cli", "menu", "gesture"]) { sources[source] = (n + i) % 3 }
                    commands[name] = sources
                }
                for event in ordered(["swipe", "fling", "unclean.exit", "ax.timeout"]) { events[event] = n }
                for bundle in ordered(["com.example.a", "com.example.b", "com.example.c", "com.example.d"]) {
                    var app = AppMetrics()
                    app.axWrite.add(Double(bundle.count % 5 + n))
                    var friction = [String: Int](minimumCapacity: reversed ? 16 : 1)
                    for kind in ordered(["user.drag", "user.resize", "focus.bounce"]) { friction[kind] = 1 }
                    app.friction = friction
                    apps[bundle] = app
                }
                d.commands = commands
                d.events = events
                d.apps = apps
                return d
            }
            return ordered(days)
        }
        let a = MetricsReport.make(days: build(reversed: false)), b = MetricsReport.make(days: build(reversed: true))
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

    @Test func emptySectionsSayNoneOnce() {
        let text = MetricsReport.make(days: [DayMetrics(day: "2026-10-13")]).renderText()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for heading in ["Commands: none", "Friction: none", "Slowest apps (AX write ms): none"] {
            let i = lines.firstIndex(of: heading)
            #expect(i != nil)
            if let i { #expect(lines[i + 1] == "", "\(heading) is followed by \(lines[i + 1])") }
        }
    }

    @Test func makeSortsTheDaysFirst() {
        func day(_ key: String, _ ticks: Int) -> DayMetrics {
            var d = DayMetrics(day: key)
            d.ticks = ticks
            return d
        }
        let sorted = [day("2026-10-12", 1), day("2026-10-13", 2), day("2026-10-14", 3)]
        let shuffled = [sorted[2], sorted[0], sorted[1]]
        let report = MetricsReport.make(days: shuffled)
        #expect(report.firstDay == "2026-10-12")
        #expect(report.lastDay == "2026-10-14")
        #expect(report.total.day == "2026-10-14")
        #expect(report == MetricsReport.make(days: sorted))
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
        // The last line is before this window: the log is in time order, so the scan stops there.
        #expect(MetricsMark.logTail(log, now: now, window: 0.5) == [])
        #expect(MetricsMark.logTail(log, now: now.addingTimeInterval(-9.5), window: 0.5) == ["2026-10-13T09:59:50.000Z back in the window"])
        #expect(MetricsMark.logTail("", now: now).isEmpty)
        #expect(MetricsMark.logTail("2026-10-13T11:59:59.000+02:00 local offset\r\nnext\r\n", now: now) == ["2026-10-13T11:59:59.000+02:00 local offset", "next"])
    }

    /// The simple forward read: each line with a time decides for itself and for the lines without a time after it.
    static func forwardTail(_ log: String, now: Date, window: TimeInterval) -> [String] {
        let fractional = ISO8601DateFormatter.fractional
        let whole = ISO8601DateFormatter()
        var lines = log.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last?.isEmpty == true { lines.removeLast() }
        var tail: [String] = []
        var keep = false
        for line in lines {
            if line.first?.isNumber == true {
                let token = String(line.prefix { $0 != " " && $0 != "\t" })
                if let time = fractional.date(from: token) ?? whole.date(from: token) {
                    keep = time >= now.addingTimeInterval(-window) && time <= now
                }
            }
            if keep { tail.append(String(line)) }
        }
        return tail
    }

    @Test func logTailGivesTheSameLinesAsAForwardReadOfAnOrderedLog() {
        let base = ISO8601DateFormatter.fractional.date(from: "2026-10-13T09:00:00.000Z")!
        var log = "orphan before the first time\n1 digit garbage\n"
        for i in 0..<400 {
            let t = base.addingTimeInterval(Double(i) * 10.25)
            let stamp = i % 3 == 0 ? ISO8601DateFormatter().string(from: t) : ISO8601DateFormatter.fractional.string(from: t)
            log += "\(stamp) line \(i)" + (i % 4 == 0 ? "\r\n" : "\n")
            if i % 5 == 0 { log += "  detail of \(i)\n" }
            if i % 7 == 0 { log += "\n2026-13-45T99:99:99Z digit garbage\r" }
        }
        let first = base.addingTimeInterval(-1)
        let last = base.addingTimeInterval(400 * 10.25)
        for now in [first, base, base.addingTimeInterval(1000), base.addingTimeInterval(2000.5), last, last.addingTimeInterval(30)] {
            for window in [0.5, 10.25, 60, 600, 100_000] {
                let tail = MetricsMark.logTail(log, now: now, window: window)
                #expect(tail == Self.forwardTail(log, now: now, window: window), "now \(now) window \(window)")
            }
        }
        #expect(MetricsMark.logTail(log, now: last, window: 60).count > 5)
    }

    @Test func logTailDoesNotReadLinesBeforeTheWindow() {
        let now = ISO8601DateFormatter.fractional.date(from: "2026-10-13T10:00:00.000Z")!
        // The first lines are out of order on purpose: a forward read would keep the first one.
        let log = """
        2026-10-13T09:59:30.000Z before the stop line, never read
        123 garbage that starts with a digit
        2026-10-13T09:00:00.000Z older than the window: the scan stops here
        2026-10-13T09:59:40.000Z kept
        detail
        """
        #expect(MetricsMark.logTail(log, now: now) == ["2026-10-13T09:59:40.000Z kept", "detail"])
    }

    @Test func logTailReadsTimesWithoutFractionsAndEveryLineEnd() {
        let now = ISO8601DateFormatter.fractional.date(from: "2026-10-13T10:00:00.000Z")!
        let log = "2026-10-13T09:58:00Z too old\r\nold detail\n2026-10-13T09:59:10Z whole seconds\r\n  detail\r"
            + "2026-10-13T09:59:20.500Z fraction\rmore\n"
        #expect(MetricsMark.logTail(log, now: now) == [
            "2026-10-13T09:59:10Z whole seconds",
            "  detail",
            "2026-10-13T09:59:20.500Z fraction",
            "more",
        ])
    }

    @Test func writeKeepsNaNAndInfinityAsText() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let marks = dir.appendingPathComponent("marks", isDirectory: true)
        let stats = EngineStats(uptimeSeconds: .nan, frameWriteP95: .infinity, commandLatencyP50: -.infinity)
        var day = DayMetrics(day: "2026-10-13")
        day.cpuSeconds = .nan
        let folder = try MetricsMark.write(note: "nan", state: state(), stats: stats, day: day, logLines: ["a"],
                                           marksDirectory: marks, now: F.date(2026, 10, 13, 9), calendar: F.calendar())
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(names == ["note.txt", "state.json", "stats.json", "day.json", "engine.log"])
        let text = try String(contentsOf: folder.appendingPathComponent("stats.json"), encoding: .utf8)
        #expect(text.contains(#""uptimeSeconds" : "nan""#))
        #expect(text.contains(#""frameWriteP95" : "inf""#))
        #expect(text.contains(#""commandLatencyP50" : "-inf""#))
        // The day file reads back leniently: the text value becomes 0.
        let saved = try JSONDecoder().decode(DayMetrics.self, from: Data(contentsOf: folder.appendingPathComponent("day.json")))
        #expect(saved.cpuSeconds == 0)
    }

    @Test func aFailedWriteRemovesOnlyItsNewFolder() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let fm = FileManager.default
        let marks = dir.appendingPathComponent("marks", isDirectory: true)
        let older = marks.appendingPathComponent("2026-10-13T09-00-00", isDirectory: true)
        try fm.createDirectory(at: older, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: older.appendingPathComponent("note.txt"))
        // The second file cannot be written: its folder does not exist.
        let files: [(name: String, data: Data)] = [("note.txt", Data("x".utf8)), ("missing/engine.log", Data())]
        #expect(throws: (any Error).self) {
            _ = try MetricsMark.writeFolder(files, marksDirectory: marks, name: "2026-10-13T09-00-00")
        }
        #expect(try fm.contentsOfDirectory(atPath: marks.path) == ["2026-10-13T09-00-00"])
        #expect(try String(contentsOf: older.appendingPathComponent("note.txt"), encoding: .utf8) == "keep")
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
