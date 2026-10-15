import Foundation
import Testing
@testable import SpoolCore

// The wiring of the local metrics (F24, docs/METRICS.md) in Core: the mark command, the config, the IPC
// request and the CLI. Pure: no process, no socket. Report runs use an injected loader.

@Suite struct MarkCommandTests {
    @Test func nameTitleAndURLRoundTrip() throws {
        #expect(Command.mark.name == "mark")
        #expect(Command(name: "mark") == .mark)
        #expect(Command(name: "Mark") == .mark)
        #expect(Command.mark.title == "Mark this moment")
        #expect(SpoolURL.command(from: SpoolURL.url(for: .mark)) == .mark)
        #expect(SpoolURL.command(from: try #require(URL(string: "spool://command?name=mark"))) == .mark)
    }

    @Test func bindableAfterToggleEngine() {
        #expect(Command.bindable.last == .mark)
        #expect(Command.bindable.dropLast().last == .toggleEngine)
        #expect(Command.bindable.filter { $0 == .mark }.count == 1)
    }

    @Test func defaultBindingIsControlOptionShiftMAndUnique() throws {
        let combos = try #require(DefaultBindings.make()[.mark])
        #expect(combos == [KeyCombo(KeyCode.m, [.control, .option, .shift])])
        #expect(combos.first?.usLabel == "⌃⌥⇧M")
        for (command, other) in DefaultBindings.make() where command != .mark {
            #expect(Set(other).isDisjoint(with: combos), "\(command.name) uses the mark shortcut")
        }
    }

    @Test func aConfigWithoutMarkGetsTheDefault() throws {
        var old = Config()
        old.bindings[.mark] = nil
        let c = try Config.decode(old.encoded(), arrowsTaken: true)
        #expect(c.bindings[.mark] == DefaultBindings.make()[.mark])
        // The user already has ⌃⌥⇧M on another command: it stays there, and mark gets no shortcut.
        let mine = KeyCombo(KeyCode.m, [.control, .option, .shift])
        old.bindings[.centerColumn] = [mine]
        let taken = try Config.decode(old.encoded(), arrowsTaken: true)
        #expect(taken.bindings[.centerColumn] == [mine])
        #expect(taken.bindings[.mark] == [])
    }
}

@Suite struct MetricsConfigTests {
    func decode(_ json: String) throws -> Config { try Config.decode(Data(json.utf8), arrowsTaken: true) }

    @Test func missingKeyMeansOn() throws {
        #expect(Config().metrics.enabled)
        #expect(try decode("{}").metrics.enabled)
        #expect(try decode(#"{"version": 2, "behavior": {"autoStart": false}}"#).metrics.enabled)
    }

    @Test func offRoundTrips() throws {
        let c = try decode(#"{"metrics": {"enabled": false}}"#)
        #expect(!c.metrics.enabled)
        #expect(try Config.decode(c.encoded(), arrowsTaken: true).metrics == c.metrics)
        #expect(String(decoding: try c.encoded(), as: UTF8.self).contains("\"metrics\""))
    }

    @Test func aWrongValueKeepsTheDefault() throws {
        #expect(try decode(#"{"metrics": {"enabled": "no"}}"#).metrics.enabled)
        #expect(try decode(#"{"metrics": 3}"#).metrics.enabled)
        #expect(try decode(#"{"metrics": {}}"#).metrics.enabled)
    }
}

@Suite struct MetricsIPCRequestTests {
    @Test func oldJSONStillDecodes() throws {
        let command = try JSONDecoder().decode(IPCRequest.self, from: Data(#"{"command":"focus-index-3"}"#.utf8))
        #expect(command == IPCRequest(command: .focusIndex(3)))
        #expect(command.note == nil)
        let query = try JSONDecoder().decode(IPCRequest.self, from: Data(#"{"query":"stats"}"#.utf8))
        #expect(query == IPCRequest(query: .stats))
        #expect(query.note == nil)
    }

    @Test func noteAndFlushRoundTrip() throws {
        for request in [IPCRequest(command: .mark, note: "Safari jumped"), IPCRequest(command: .mark),
                        IPCRequest(query: .flushMetrics)] {
            let line = try IPCWire.encode(request)
            #expect(try IPCWire.decodeRequest(line.dropLast()) == request)
        }
        #expect(String(decoding: try IPCWire.encode(IPCRequest(query: .flushMetrics)), as: UTF8.self) == "{\"query\":\"flush-metrics\"}\n")
    }

    @Test func noNoteKeepsTheOldLine() throws {
        #expect(String(decoding: try IPCWire.encode(IPCRequest(command: .focusLeft)), as: UTF8.self) == "{\"command\":\"focus-left\"}\n")
        #expect(String(decoding: try IPCWire.encode(IPCRequest(command: .mark, note: "x")), as: UTF8.self)
            == "{\"command\":\"mark\",\"note\":\"x\"}\n")
    }
}

@Suite struct MetricsCLIParseTests {
    func action(_ args: String...) -> SpoolCLI.Action { SpoolCLI.parse(args).action }

    @Test func reportDays() {
        #expect(action("report") == .report(days: 7))
        #expect(action("report", "--days", "30") == .report(days: 30))
        #expect(action("--days", "1", "report") == .report(days: 1))
        #expect(action("report", "--days=90") == .report(days: 90))
        #expect(action("Report") == .report(days: 7))
        #expect(SpoolCLI.parse(["report", "--json"]) == .init(action: .report(days: 7), options: .init(json: true)))
    }

    @Test func badDaysAreUsageErrors() {
        let error = SpoolCLI.Action.error(SpoolCLI.daysError)
        #expect(action("report", "--days", "0") == error)
        #expect(action("report", "--days", "91") == error)
        #expect(action("report", "--days", "-3") == error)
        #expect(action("report", "--days", "week") == error)
        #expect(action("report", "--days") == error)
        #expect(action("report", "--days=") == error)
        #expect(action("report", "7") == .error("report takes no argument. Use --days <n>."))
        #expect(action("state", "--days", "3") == .error("--days works only with report."))
        #expect(SpoolCLI.run(SpoolCLI.parse(["report", "--days", "0"]), versionLine: "", send: { _ in IPCResponse(ok: true) },
                             loadMetrics: { _ in Issue.record("loaded"); return ([], []) }).code == .usage)
    }

    @Test func markNote() {
        #expect(action("mark") == .send(IPCRequest(command: .mark)))
        #expect(action("mark", "Safari", "jumped", "left") == .send(IPCRequest(command: .mark, note: "Safari jumped left")))
        #expect(action("mark", "  slow  ") == .send(IPCRequest(command: .mark, note: "slow")))
        #expect(action("mark", " ") == .send(IPCRequest(command: .mark)))
        #expect(action("command", "mark", "a", "b") == .send(IPCRequest(command: .mark, note: "a b")))
        #expect(action("mark", "--json") == .send(IPCRequest(command: .mark)))
    }

    @Test func flushIsNotAUserCommand() {
        #expect(action("flush-metrics") == .error("Unknown command 'flush-metrics'."))
        #expect(action("command", "flush-metrics") == .error("Unknown command 'flush-metrics'."))
        #expect(!SpoolCLI.listText().contains("flush"))
        #expect(!SpoolCLI.usageText().contains("flush"))
    }

    @Test func helpAndList() {
        #expect(action("help", "report") == .help("report"))
        #expect(action("help", "mark") == .help("mark"))
        #expect(SpoolCLI.usageText().contains("spool report"))
        #expect(SpoolCLI.usageText().contains("spool mark [<note>]"))
        #expect(SpoolCLI.usageText().contains("--days <n>"))
        #expect(SpoolCLI.listText().contains("\n  mark [<note>]         Mark this moment\n"))
        #expect(SpoolCLI.listText().contains("\n  report [--days <n>]   Show the local metrics report\n"))
        #expect(SpoolCLI.commandEntries.contains { $0.name == "mark" && $0.url == "spool://mark" })
    }
}

@Suite struct MarkRunTests {
    func run(_ args: [String], _ send: (IPCRequest) throws -> IPCResponse) -> SpoolCLI.Output {
        SpoolCLI.run(SpoolCLI.parse(args), versionLine: "spool 1.0", send: send)
    }

    @Test func sendsTheNote() {
        var sent: [IPCRequest] = []
        let out = run(["mark", "focus", "went", "to", "Teams"]) { sent.append($0); return IPCResponse(ok: true) }
        #expect(sent == [IPCRequest(command: .mark, note: "focus went to Teams")])
        #expect(out == .init(stdout: "Saving a mark (see engine.log for the folder)\n"))
    }

    @Test func notRunningIsExit3() {
        let out = run(["mark", "x"]) { _ in throw IPCClient.Error.notRunning }
        #expect(out == .init(stderr: "Spool is not running. Open Spool.app.\n", code: .notRunning))
        #expect(out.code.rawValue == 3)
    }

    @Test func metricsOffIsAnError() {
        let out = run(["mark"]) { _ in IPCResponse(ok: false, error: "Metrics are off.") }
        #expect(out == .init(stderr: "Metrics are off.\n", code: .failed))
    }

    @Test func helpTexts() {
        let mark = run(["help", "mark"]) { _ in IPCResponse(ok: true) }
        #expect(mark.stdout.hasPrefix("Usage: spool mark [<note>]\n"))
        #expect(mark.stdout.contains("URL: spool://mark"))
        let report = run(["help", "report"]) { _ in IPCResponse(ok: true) }
        #expect(report.stdout.hasPrefix("Usage: spool report [--days <n>] [--json]\n"))
    }

    @Test func listJSONHasReport() {
        let list = run(["list", "--json"]) { _ in IPCResponse(ok: true) }
        #expect(list.stdout.contains("\"usage\" : \"report [--days <n>]\""))
        #expect(list.stdout.contains("\"usage\" : \"mark [<note>]\""))
    }
}

/// Calls `MetricsReport`: needs the Core metrics types.
@Suite struct MetricsReportRunTests {
    final class Calls {
        var sent: [IPCRequest] = []
        var loaded: [Int] = []
    }

    func run(_ args: [String], _ calls: Calls, send: @escaping (IPCRequest) throws -> IPCResponse,
             days: [DayMetrics] = [], skipped: [String] = []) -> SpoolCLI.Output {
        SpoolCLI.run(SpoolCLI.parse(args), versionLine: "spool 1.0",
                     send: { calls.sent.append($0); return try send($0) },
                     loadMetrics: { calls.loaded.append($0); return (days, skipped) })
    }

    static func day() -> DayMetrics {
        var d = DayMetrics(day: "2026-10-14")
        d.activeSeconds = 3600
        d.commands = ["focus-right": ["hotkey": 4]]
        return d
    }

    @Test func printsWhenSpoolIsNotRunning() {
        let calls = Calls()
        let out = run(["report", "--days", "30"], calls, send: { _ in throw IPCClient.Error.notRunning }, days: [Self.day()])
        #expect(calls.sent == [IPCRequest(query: .flushMetrics)])
        #expect(calls.loaded == [30])
        #expect(out.code == .ok)
        #expect(out.stderr.isEmpty)
        let text = MetricsReport.make(days: [Self.day()]).renderText()
        #expect(out.stdout == (text.hasSuffix("\n") ? text : text + "\n"))
    }

    @Test func flushesFirstWhenRunning() {
        let calls = Calls()
        let out = run(["report"], calls, send: { _ in IPCResponse(ok: true) })
        #expect(calls.sent == [IPCRequest(query: .flushMetrics)])
        #expect(calls.loaded == [7])
        #expect(out.code == .ok)
        #expect(!out.stdout.isEmpty)
        // An app that answers with an error or too late does not stop the report.
        #expect(run(["report"], Calls(), send: { _ in IPCResponse(ok: false, error: "x") }).code == .ok)
        #expect(run(["report"], Calls(), send: { _ in throw IPCClient.Error.timeout }).code == .ok)
    }

    @Test func withoutFilesEveryBudgetHasNoData() throws {
        let out = run(["report", "--json"], Calls(), send: { _ in throw IPCClient.Error.notRunning })
        #expect(out.code == .ok)
        let report = try JSONDecoder().decode(MetricsReport.self, from: Data(out.stdout.utf8))
        #expect(report.dayCount == 0)
        let unclean = try #require(report.budgets.first { $0.budget.name == "unclean-exits" })
        #expect(unclean.value == nil)
        #expect(unclean.pass == nil)
        #expect(report.budgets.allSatisfy { $0.value == nil && $0.pass == nil })
        let text = run(["report"], Calls(), send: { _ in throw IPCClient.Error.notRunning }).stdout
        #expect(text.hasPrefix("Spool metrics: no data yet\n"))
        #expect(!text.contains("PASS") && !text.contains("FAIL"))
    }

    @Test func json() throws {
        let calls = Calls()
        let out = run(["report", "--json"], calls, send: { _ in throw IPCClient.Error.notRunning },
                      days: [Self.day()], skipped: ["2026-10-13.json"])
        #expect(out.code == .ok)
        #expect(out.stdout.hasSuffix("}\n"))
        let back = try JSONDecoder().decode(MetricsReport.self, from: Data(out.stdout.utf8))
        #expect(back == MetricsReport.make(days: [Self.day()], skipped: ["2026-10-13.json"]))
    }
}

@Suite struct CostSampleTests {
    @Test func deltas() {
        let a = CostSample(cpuSeconds: 1.5, wakeups: 100, peakMB: 40)
        let b = CostSample(cpuSeconds: 2.0, wakeups: 160, peakMB: 42.5)
        let d = b.delta(since: a)
        #expect(d.cpuSeconds == 0.5)
        #expect(d.wakeups == 60)
        #expect(d.peakMB == 42.5)
    }

    @Test func aCounterThatGoesBackGivesZero() {
        let a = CostSample(cpuSeconds: 5, wakeups: 500, peakMB: 40)
        let b = CostSample(cpuSeconds: 4, wakeups: 10, peakMB: 30)
        let d = b.delta(since: a)
        #expect(d.cpuSeconds == 0)
        #expect(d.wakeups == 0)
        #expect(d.peakMB == 30)
    }

    @Test func badNumbersGiveZero() {
        let d = CostSample(cpuSeconds: .nan, wakeups: 1, peakMB: .infinity).delta(since: CostSample(cpuSeconds: 1, wakeups: 0, peakMB: 1))
        #expect(d.cpuSeconds == 0)
        #expect(d.wakeups == 1)
        #expect(d.peakMB == 0)
        #expect(CostSample(cpuSeconds: 0, wakeups: .max, peakMB: 0).delta(since: CostSample(cpuSeconds: 0, wakeups: 0, peakMB: 0)).wakeups == .max)
    }

    @Test func readsTheOwnCounters() throws {
        let first = try #require(CostSample.current())
        var x = 0.0
        for i in 0..<200_000 { x += Double(i).squareRoot() }
        #expect(x > 0)
        let second = try #require(CostSample.current())
        #expect(first.cpuSeconds > 0)
        #expect(first.peakMB > 1)
        #expect(second.cpuSeconds >= first.cpuSeconds)
        #expect(second.wakeups >= first.wakeups)
        // A lifetime peak: it never goes down.
        #expect(second.peakMB >= first.peakMB)
    }
}

/// docs/SPEC.md "Live budget" and docs/METRICS.md must match the code.
@Suite struct MetricsDocsTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func specBudgetTableMatchesTheCode() throws {
        let spec = try Self.text("docs/SPEC.md")
        let section = try #require(spec.components(separatedBy: "## Live budget").dropFirst().first)
        let rows = section.split(separator: "\n").filter { $0.hasPrefix("| ") && !$0.hasPrefix("| Name") }
        let table = rows.map { row -> [String] in
            row.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        #expect(table.map { $0[0] } == MetricsBudget.live.map(\.name))
        for (cells, budget) in zip(table, MetricsBudget.live) {
            #expect(Double(cells[1]) == budget.limit, "\(budget.name)")
            #expect(cells[2] == budget.unit, "\(budget.name)")
        }
    }

    @Test func metricsDocNamesEveryKind() throws {
        let doc = try Self.text("docs/METRICS.md")
        for kind in FrictionKind.allCases { #expect(doc.contains("`\(kind.rawValue)`"), "\(kind.rawValue)") }
        for source in CommandSource.allCases { #expect(doc.contains("`\(source.rawValue)`"), "\(source.rawValue)") }
        #expect(doc.contains("90 days"))
        #expect(doc.contains("\"metrics\": { \"enabled\": false }"))
    }

    @Test func cliDocListsReportAndMark() throws {
        let doc = try Self.text("docs/CLI.md")
        #expect(doc.contains("`spool \(SpoolCLI.reportEntry.usage)`"))
        #expect(doc.contains("`spool mark [<note>]`"))
    }
}
