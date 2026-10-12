import Foundation
import Testing
@testable import StripleCore

/// Every `Command` value: the bindable ones plus the ones that are not on the Shortcuts page.
let everyCommand: [Command] = Command.bindable + [.start, .stop, .restart, .focusWindow(0), .focusWindow(1234), .focusWindow(UInt32.max)]

@Suite struct LineBufferTests {
    @Test func linesSplitOverChunks() throws {
        var b = LineBuffer()
        #expect(try b.append(Data(#"{"query":"#.utf8)) == [])
        #expect(b.pendingByteCount == 9)
        #expect(try b.append(Data(#""ping"}"#.utf8)) == [])
        #expect(try b.append(Data("\n".utf8)) == [Data(#"{"query":"ping"}"#.utf8)])
        #expect(b.pendingByteCount == 0)
    }

    @Test func manyLinesInOneChunk() throws {
        var b = LineBuffer()
        let lines = try b.append(Data("a\nbb\r\n\nccc".utf8))
        #expect(lines == [Data("a".utf8), Data("bb".utf8), Data()])
        #expect(try b.append(Data("\n".utf8)) == [Data("ccc".utf8)])
    }

    @Test func worksOnDataSlices() throws {
        var b = LineBuffer()
        let whole = Data("xxone\ntwo\n".utf8)
        #expect(try b.append(whole[2...]) == [Data("one".utf8), Data("two".utf8)])
    }

    @Test func lineAtTheLimitIsAccepted() throws {
        var b = LineBuffer(maxLineLength: 4)
        #expect(try b.append(Data("abcd\n".utf8)) == [Data("abcd".utf8)])
    }

    @Test func oversizeLineThrowsAndClears() throws {
        var b = LineBuffer(maxLineLength: 4)
        #expect(throws: LineBuffer.Error.lineTooLong(limit: 4)) { try b.append(Data("abcde".utf8)) }
        #expect(b.pendingByteCount == 0)
        var c = LineBuffer(maxLineLength: 4)
        _ = try c.append(Data("abc".utf8))
        #expect(throws: LineBuffer.Error.lineTooLong(limit: 4)) { try c.append(Data("de\n".utf8)) }
    }

    @Test func defaultLimitIsOneMegabyte() {
        #expect(LineBuffer().maxLineLength == 1_048_576)
    }
}

@Suite struct IPCWireTests {
    static let window = WindowInfo(id: 7, pid: 42, bundleID: "com.apple.Safari", title: "Line one\nline \"two\"")

    static let state = EngineState(
        running: true, accessibilityTrusted: false, focusedWindow: window,
        displays: [.init(id: "1", name: "Built-in", enabled: true, spaceID: 3, focusedColumn: 0, scroll: 12.5, columns: [[window]])],
        floating: [])

    @Test(arguments: [IPCRequest(query: .ping), IPCRequest(query: .state), IPCRequest(query: .stats),
                      IPCRequest(command: .focusLeft), IPCRequest(command: .focusIndex(3)), IPCRequest(command: .focusWindow(99))])
    func requestRoundTrip(_ request: IPCRequest) throws {
        let data = try IPCWire.encode(request)
        #expect(data.last == 0x0A)
        #expect(!data.dropLast().contains(0x0A))
        #expect(try IPCWire.decodeRequest(data.dropLast()) == request)
    }

    @Test func requestJSONIsStable() throws {
        #expect(String(decoding: try IPCWire.encode(IPCRequest(command: .focusIndex(3))), as: UTF8.self) == "{\"command\":\"focus-index-3\"}\n")
        #expect(String(decoding: try IPCWire.encode(IPCRequest(query: .state)), as: UTF8.self) == "{\"query\":\"state\"}\n")
    }

    @Test func responseRoundTripHasNoEmbeddedNewline() throws {
        let response = IPCResponse(ok: true, state: Self.state, stats: EngineStats(uptimeSeconds: 1, frameWriteP95: 2.5))
        let data = try IPCWire.encode(response)
        #expect(data.filter { $0 == 0x0A }.count == 1)
        #expect(data.last == 0x0A)
        #expect(try IPCWire.decodeResponse(data.dropLast()) == response)
    }

    @Test func nonFiniteNumbersDoNotBreakTheWire() throws {
        let response = IPCResponse(ok: true, stats: EngineStats(frameWriteP50: .nan, frameWriteP95: .infinity))
        let back = try IPCWire.decodeResponse(try IPCWire.encode(response).dropLast())
        #expect(back.stats?.frameWriteP50.isNaN == true)
        #expect(back.stats?.frameWriteP95 == .infinity)
    }

    @Test func lineBufferReadsEncodedStream() throws {
        let stream = try IPCWire.encode(IPCRequest(query: .ping)) + IPCWire.encode(IPCRequest(command: .cycleWidth))
        var b = LineBuffer()
        var lines: [Data] = []
        for byte in stream { lines += try b.append(Data([byte])) }
        #expect(try lines.map(IPCWire.decodeRequest) == [IPCRequest(query: .ping), IPCRequest(command: .cycleWidth)])
    }

    @Test func decodeErrorsAreShort() {
        func reason(_ s: String) -> String {
            do { _ = try IPCWire.decodeRequest(Data(s.utf8)); return "ok" } catch { return IPCWire.describe(error) }
        }
        #expect(reason("not json") == "The request is not valid JSON.")
        #expect(reason(#"{"command":"fly-away"}"#) == "Unknown command fly-away")
        #expect(reason("[1]") == "The request must be a JSON object.")
        #expect(reason(#"{"query":5}"#) == "The field query has the wrong type.")
    }

    @Test func socketAddressChecksLength() {
        #expect(IPCSocket.maxPathLength == 103)
        #expect(IPCSocket.address(for: "/" + String(repeating: "a", count: 102)) != nil)
        #expect(IPCSocket.address(for: "/" + String(repeating: "a", count: 103)) == nil)
        #expect(IPCSocket.address(for: "") == nil)
    }

    @Test func clientErrors() {
        let long = "/" + String(repeating: "a", count: 200)
        #expect(throws: IPCClient.Error.pathTooLong(long)) { try IPCClient(socketPath: long).send(IPCRequest(query: .ping)) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("striple-missing-\(UUID().uuidString.prefix(8)).sock").path
        #expect(throws: IPCClient.Error.notRunning) { try IPCClient(socketPath: missing).send(IPCRequest(query: .ping)) }
        #expect(IPCClient.Error.notRunning.description == "Striple is not running. Open Striple.app.")
    }
}

@Suite struct StripleCLIParseTests {
    func action(_ args: String...) -> StripleCLI.Action { StripleCLI.parse(args).action }

    @Test(arguments: everyCommand)
    func everyCommandNameParses(_ command: Command) {
        #expect(StripleCLI.parse([command.name]) == .init(action: .send(IPCRequest(command: command))))
        #expect(action("command", command.name) == .send(IPCRequest(command: command)))
    }

    @Test func everyNameCommandKnowsIsListed() {
        let listed = Set(StripleCLI.commandEntries.map(\.name))
        for name in Command.allNames {
            let base = name.replacingOccurrences(of: "-<1-9>", with: "").replacingOccurrences(of: "-<id>", with: "")
            #expect(listed.contains(base), "missing \(name)")
            if !name.contains("<") { #expect(Command(name: name) != nil) }
        }
        #expect(StripleCLI.commandEntries.count == Set(StripleCLI.commandEntries.map(\.name)).count)
    }

    @Test func argumentForms() {
        for n in 1...9 {
            #expect(action("focus-index", "\(n)") == .send(IPCRequest(command: .focusIndex(n))))
            #expect(action("focus-index-\(n)") == .send(IPCRequest(command: .focusIndex(n))))
            #expect(action("move-to-index", "\(n)") == .send(IPCRequest(command: .moveToIndex(n))))
            #expect(action("move-to-index-\(n)") == .send(IPCRequest(command: .moveToIndex(n))))
        }
        #expect(action("focus-index/3") == .send(IPCRequest(command: .focusIndex(3))))
        #expect(action("focus-window", "4512") == .send(IPCRequest(command: .focusWindow(4512))))
        #expect(action("command", "focus-index", "4") == .send(IPCRequest(command: .focusIndex(4))))
        #expect(action("Focus_Left") == .send(IPCRequest(command: .focusLeft)))
    }

    @Test func queriesAndMeta() {
        #expect(action("ping") == .send(IPCRequest(query: .ping)))
        #expect(action("state") == .send(IPCRequest(query: .state)))
        #expect(action("stats") == .send(IPCRequest(query: .stats)))
        #expect(StripleCLI.parse(["state", "--json"]) == .init(action: .send(IPCRequest(query: .state)), options: .init(json: true)))
        #expect(StripleCLI.parse(["--json", "stats"]).options.json)
        #expect(action("list") == .listCommands)
        #expect(action("commands") == .listCommands)
        #expect(action("--version") == .version)
        #expect(action("-V") == .version)
        #expect(action("version") == .version)
        #expect(action("help") == .help(nil))
        #expect(action("--help") == .help(nil))
        #expect(action("-h") == .help(nil))
        #expect(action("help", "focus-left") == .help("focus-left"))
        #expect(action("help", "focus-index-3") == .help("focus-index"))
        #expect(action("focus-index", "--help") == .help("focus-index"))
        #expect(action("help", "state") == .help("state"))
        #expect(action() == .missingCommand)
    }

    @Test func socketOption() {
        #expect(StripleCLI.parse(["--socket", "/x.sock", "ping"]).options.socketPath == "/x.sock")
        #expect(StripleCLI.parse(["ping", "--socket=/y.sock"]).options.socketPath == "/y.sock")
        #expect(action("ping", "--socket") == .error("--socket needs a path."))
        #expect(action("--socket=") == .error("--socket needs a path."))
        #expect(StripleCLI.socketPath(option: "/a", environment: ["STRIPLE_SOCKET": "/b"]) == "/a")
        #expect(StripleCLI.socketPath(option: nil, environment: ["STRIPLE_SOCKET": "/b"]) == "/b")
        #expect(StripleCLI.socketPath(option: nil, environment: [:]) == StriplePaths.socket.path)
    }

    @Test func usageErrors() {
        #expect(action("focus-lef") == .error("Unknown command 'focus-lef'. Did you mean 'focus-left'?"))
        #expect(action("stat") == .error("Unknown command 'stat'. Did you mean 'state'?"))
        #expect(action("fullscreen-everything") == .error("Unknown command 'fullscreen-everything'."))
        #expect(action("focus-index") == .error("focus-index needs a number from 1 to 9 (9 is the last place). Example: striple focus-index 3"))
        #expect(action("focus-index", "10") == .error("focus-index needs a number from 1 to 9 (9 is the last place). Example: striple focus-index 3"))
        #expect(action("move-to-index-0") == .error("move-to-index needs a number from 1 to 9 (9 is the last place). Example: striple move-to-index 3"))
        #expect(action("focus-window", "abc") == .error("focus-window needs a window ID (a number). Run 'striple state --json' to see window IDs."))
        #expect(action("focus-left", "2") == .error("focus-left takes no argument."))
        #expect(action("focus-index", "2", "3") == .error("Too many arguments for focus-index."))
        #expect(action("state", "x") == .error("state takes no argument."))
        #expect(action("command") == .error("command needs a command name. Example: striple command focus-left"))
        // Round 4 finding: `command ping` failed and suggested 'ping'.
        #expect(action("command", "ping") == .send(IPCRequest(query: .ping)))
        #expect(action("command", "state") == action("state"))
        #expect(action("command", "stats", "x") == .error("stats takes no argument."))
        #expect(action("command", "help") == .error("Unknown command 'help'."))
        #expect(action("--fast") == .error("Unknown option '--fast'."))
        #expect(action("help", "nope") == .error("Unknown help topic 'nope'."))
    }

    @Test func suggestions() {
        #expect(StripleCLI.suggestion(for: "foucs-right") == "focus-right")
        #expect(StripleCLI.suggestion(for: "center") == nil)
        #expect(StripleCLI.suggestion(for: "restat") == "restart")
        #expect(StripleCLI.suggestion(for: "lsit") == "list")
        #expect(StripleCLI.editDistance("kitten", "sitting") == 3)
        #expect(StripleCLI.editDistance("", "abc") == 3)
    }
}

@Suite struct StripleCLIRunTests {
    func run(_ args: [String], _ send: (IPCRequest) throws -> IPCResponse = { _ in IPCResponse(ok: true) }) -> StripleCLI.Output {
        StripleCLI.run(StripleCLI.parse(args), versionLine: "striple 1.0", send: send)
    }

    @Test func exitCodes() {
        #expect(run(["focus-left"]) == .init())
        #expect(run(["ping"]) == .init(stdout: "Striple is running.\n"))
        #expect(run(["focus-left"]) { _ in throw IPCClient.Error.notRunning }
            == .init(stderr: "Striple is not running. Open Striple.app.\n", code: .notRunning))
        #expect(run(["ping"]) { _ in throw IPCClient.Error.timeout } == .init(stderr: "Striple did not answer in time.\n", code: .failed))
        #expect(run(["stop"]) { _ in IPCResponse(ok: false, error: "No windows.") } == .init(stderr: "No windows.\n", code: .failed))
        #expect(run(["stop"]) { _ in IPCResponse(ok: false) } == .init(stderr: "The command failed.\n", code: .failed))
        #expect(run(["state"]) == .init(stderr: "The response has no state.\n", code: .failed))
        #expect(run(["nope"]).code == .usage)
        #expect(run(["nope"]).stderr == "Unknown command 'nope'.\nRun 'striple help' for usage.\n")
        #expect(run([]) == .init(stderr: StripleCLI.usageText(), code: .usage))
        #expect(run(["--version"]) == .init(stdout: "striple 1.0\n"))
        #expect(StripleCLI.ExitCode.notRunning.rawValue == 3)
        #expect(StripleCLI.ExitCode.usage.rawValue == 2)
    }

    @Test func sendsTheParsedRequest() {
        var sent: [IPCRequest] = []
        _ = run(["focus-index", "4"]) { sent.append($0); return IPCResponse(ok: true) }
        #expect(sent == [IPCRequest(command: .focusIndex(4))])
        _ = run(["list"]) { sent.append($0); return IPCResponse(ok: true) }
        #expect(sent.count == 1)
    }

    @Test func jsonPrintsTheWholeResponse() {
        let out = run(["stop", "--json"]) { _ in IPCResponse(ok: false, error: "No.") }
        #expect(out == .init(stdout: "{\n  \"error\" : \"No.\",\n  \"ok\" : false\n}\n", code: .failed))
        let stats = run(["stats", "--json"]) { _ in IPCResponse(ok: true, stats: EngineStats(restarts: 2)) }
        #expect(stats.code == .ok)
        #expect(stats.stdout.contains("\"restarts\" : 2"))
        let list = run(["list", "--json"])
        #expect(list.stdout.contains("\"usage\" : \"focus-index <1-9>\""))
        #expect(list.stdout.contains("\"url\" : \"striple://focus-index/3\""))
    }

    @Test func versionLine() {
        #expect(StripleCLI.versionLine(info: nil) == "striple dev")
        #expect(StripleCLI.versionLine(info: ["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "45"]) == "striple 1.2.0 (45)")
        #expect(StripleCLI.versionLine(info: ["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "1.2.0"]) == "striple 1.2.0")
    }

    @Test func helpTexts() {
        #expect(run(["help", "focus-left"]).stdout == "Usage: striple focus-left\n\nFocus left.\n\nURL: striple://focus-left\n")
        #expect(run(["help", "move-to-index"]).stdout == """
            Usage: striple move-to-index <1-9>

            Move column to place <n> (9 is the last place).
            You can also write move-to-index-3.

            URL: striple://move-to-index/3

            """)
        #expect(run(["help"]).stdout.hasPrefix("Usage: striple <command>"))
        for topic in StripleCLI.knownWords {
            #expect(run(["help", topic]).code == .ok, "help \(topic)")
        }
    }

    @Test func listText() {
        let text = StripleCLI.listText()
        #expect(text.hasPrefix("Commands:\n  focus-left            Focus left\n"))
        #expect(text.contains("\n  focus-index <1-9>     Focus place <n> (9 is the last place)\n"))
        #expect(text.hasSuffix("Queries:\n  ping                  Check that Striple is running\n  state                 Show displays, columns and windows\n  stats                 Show performance counters\n"))
    }
}

@Suite struct StripleCLIFormatTests {
    @Test func stateSnapshot() {
        typealias D = EngineState.DisplayState
        let terminal = WindowInfo(id: 202, pid: 20, bundleID: "com.apple.Terminal", title: "zsh")
        let state = EngineState(
            running: true, accessibilityTrusted: true, focusedWindow: terminal,
            displays: [
                D(id: "1", name: "Built-in Retina Display", enabled: true, spaceID: 5, focusedColumn: 1, scroll: 0, columns: [
                    [WindowInfo(id: 101, pid: 10, bundleID: "com.apple.Safari", title: "Apple")],
                    [terminal, WindowInfo(id: 203, pid: 21, bundleID: "com.apple.Notes", title: "")],
                    [WindowInfo(id: 301, pid: 30, bundleID: "", title: "A very long window title that goes on and on")],
                ]),
                D(id: "2", name: "LG UltraFine", enabled: false, spaceID: 9, focusedColumn: 0, scroll: 0, columns: []),
            ],
            floating: [WindowInfo(id: 400, pid: 40, bundleID: "com.apple.calculator", title: "Calculator")])
        #expect(StripleCLI.format(state: state) == """
            Engine: running. Accessibility: granted.
            Focused: Terminal "zsh" (window 202)
            Display: Built-in Retina Display (on, space 5)
              [1] Safari "Apple" | [2*] Terminal "zsh" + Notes | [3] pid 30 "A very long window title that goes on..."
            Display: LG UltraFine (off, space 9)
              (no windows)
            Floating: calculator "Calculator"

            """)
    }

    @Test func emptyStateSnapshot() {
        let state = EngineState(running: false, accessibilityTrusted: false, focusedWindow: nil, displays: [], floating: [])
        #expect(StripleCLI.format(state: state) == "Engine: stopped. Accessibility: not granted.\nFocused: none\nDisplays: none\n")
    }

    @Test func statsSnapshot() {
        let stats = EngineStats(uptimeSeconds: 3723.9, framesWritten: 1200, windowWrites: 3400, skippedWrites: 12, coalescedWrites: 40,
                                axErrors: 1, frameWriteP50: 1.2, frameWriteP95: 3.456, commandLatencyP50: 4, commandLatencyP95: 9.5,
                                restarts: 2)
        #expect(StripleCLI.format(stats: stats) == """
            Uptime:           1h 02m 03s
            Frames written:   1200
            Window writes:    3400
            Skipped writes:   12
            Coalesced writes: 40
            AX errors:        1
            Frame write:      p50 1.20 ms, p95 3.46 ms
            Command latency:  p50 4.00 ms, p95 9.50 ms
            Restarts:         2

            """)
    }

    @Test func durations() {
        #expect(StripleCLI.duration(0) == "0s")
        #expect(StripleCLI.duration(59.9) == "59s")
        #expect(StripleCLI.duration(61) == "1m 01s")
        #expect(StripleCLI.duration(90_000) == "25h 00m 00s")
        #expect(StripleCLI.duration(-5) == "0s")
        #expect(StripleCLI.duration(.nan) == "0s")
        #expect(StripleCLI.ms(.nan) == "n/a")
    }
}

/// The Raycast scripts and docs/CLI.md must only use names that the CLI knows.
@Suite struct AutomationFilesTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func raycastScriptsUseKnownCommands() throws {
        let dir = Self.root.appendingPathComponent("Integrations/Raycast")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("striple-") && $0.hasSuffix(".sh") }
        #expect(files.count >= 20)
        for file in files {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            let line = text.split(separator: "\n").first { $0.hasPrefix("cmd=") }
            let name = line.map { $0.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } ?? ""
            #expect(name == "state" || Command(name: name)?.name == name, "\(file): \(name)")
            #expect(file == "striple-\(name).sh")
            #expect(text.contains("# @raycast.schemaVersion 1"))
        }
    }

    @Test func listedURLsOpenTheSameCommand() throws {
        for entry in StripleCLI.commandEntries {
            let url = try #require(entry.url.flatMap(URL.init(string:)))
            let command = try #require(StripleURL.command(from: url), "\(url)")
            #expect(StripleCLI.baseName(of: command) == entry.name)
        }
        #expect(StripleURL.command(from: URL(string: "striple://command?name=focus-left")!) == .focusLeft)
        #expect(StripleURL.command(from: URL(string: "striple://focus-index/3")!) == .focusIndex(3))
    }

    @Test func cliDocListsEveryCommand() throws {
        let doc = try String(contentsOf: Self.root.appendingPathComponent("docs/CLI.md"), encoding: .utf8)
        for entry in StripleCLI.commandEntries + StripleCLI.queries {
            #expect(doc.contains("`striple \(entry.usage)`"), "docs/CLI.md misses \(entry.usage)")
        }
    }
}

@Suite struct ClientTimeoutTests {
    @Test func startStopAndRestartWaitLonger() {
        for c: Command in [.start, .stop, .toggleEngine, .restart] {
            #expect(IPCClient.timeout(for: IPCRequest(command: c), base: IPCClient.defaultTimeout) == IPCClient.lifecycleTimeout)
        }
        #expect(IPCClient.timeout(for: IPCRequest(command: .focusLeft), base: IPCClient.defaultTimeout) == IPCClient.defaultTimeout)
        #expect(IPCClient.timeout(for: IPCRequest(query: .state), base: IPCClient.defaultTimeout) == IPCClient.defaultTimeout)
        // A longer timeout from the caller is never made shorter.
        #expect(IPCClient.timeout(for: IPCRequest(command: .stop), base: 30) == 30)
    }
}
