import Darwin
import Foundation

// MARK: - Wire format

/// The IPC wire format: one compact JSON object per line, UTF-8, ended by `\n`.
public enum IPCWire {
    /// Longest line (without the `\n`) that a reader accepts.
    public static let maxLineLength = 1 << 20

    /// Compact JSON plus `\n`. The JSON never contains a raw newline, because strings escape it.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try makeEncoder(pretty: false).encode(value)
        data.append(0x0A)
        return data
    }

    /// Pretty JSON with sorted keys, for `--json` output. No trailing newline.
    public static func prettyJSON<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try makeEncoder(pretty: true).encode(value), as: UTF8.self)
    }

    public static func decodeRequest(_ line: Data) throws -> IPCRequest {
        try makeDecoder().decode(IPCRequest.self, from: line)
    }

    public static func decodeResponse(_ line: Data) throws -> IPCResponse {
        try makeDecoder().decode(IPCResponse.self, from: line)
    }

    /// A short reason for a decode failure, for an error response.
    public static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return "\(error)" }
        switch error {
        case .dataCorrupted(let c) where c.codingPath.isEmpty: return "The request is not valid JSON."
        case .dataCorrupted(let c): return c.debugDescription
        case .keyNotFound(let key, _): return "The field \(key.stringValue) is missing."
        case .typeMismatch(_, let c), .valueNotFound(_, let c):
            let path = c.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "The request must be a JSON object." : "The field \(path) has the wrong type."
        @unknown default: return "The request is not valid."
        }
    }

    // Non-finite numbers are sent as strings, so a NaN in a stat can never break the wire.
    private static func makeEncoder(pretty: Bool) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return d
    }
}

/// Collects bytes from a stream and returns complete lines.
/// The `\n` and an optional `\r` before it are removed. Empty lines are returned as empty `Data`.
/// `maxLineLength` counts the bytes before the `\n`.
public struct LineBuffer {
    public enum Error: Swift.Error, Equatable {
        /// A line is longer than `maxLineLength`. The buffer is cleared; close the stream.
        case lineTooLong(limit: Int)
    }

    public let maxLineLength: Int
    private var pending: [UInt8] = []

    public init(maxLineLength: Int = IPCWire.maxLineLength) {
        self.maxLineLength = maxLineLength
    }

    /// Bytes of an incomplete line that are kept until its `\n` comes.
    public var pendingByteCount: Int { pending.count }

    public mutating func append(_ chunk: Data) throws -> [Data] {
        var lines: [Data] = []
        var start = chunk.startIndex
        var i = chunk.startIndex
        while i < chunk.endIndex {
            if chunk[i] == 0x0A {
                pending.append(contentsOf: chunk[start..<i])
                try checkLength()
                if pending.last == 0x0D { pending.removeLast() }
                lines.append(Data(pending))
                pending.removeAll(keepingCapacity: true)
                start = chunk.index(after: i)
            }
            i = chunk.index(after: i)
        }
        pending.append(contentsOf: chunk[start..<chunk.endIndex])
        try checkLength()
        return lines
    }

    private mutating func checkLength() throws {
        guard pending.count > maxLineLength else { return }
        pending = []
        throw Error.lineTooLong(limit: maxLineLength)
    }
}

// MARK: - Sockets

/// Small POSIX helpers for the Unix domain socket that the CLI and the app share.
public enum IPCSocket {
    /// Longest socket path in bytes. `sun_path` is 104 bytes on macOS, including the closing NUL.
    public static let maxPathLength: Int = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// The socket address for a path, or nil if the path is empty or too long.
    public static func address(for path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxPathLength, !bytes.contains(0) else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return addr
    }

    /// Calls `body` with the address as a `sockaddr` pointer, for `bind` and `connect`.
    public static func withSockaddr<T>(_ addr: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var addr = addr
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// A write to a closed peer returns EPIPE instead of killing the process with SIGPIPE.
    public static func setNoSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func setTimeouts(_ fd: Int32, seconds: TimeInterval) {
        let s = max(seconds, 0.001)
        var tv = timeval(tv_sec: Int(s), tv_usec: Int32((s - Double(Int(s))) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    public static func setCloseOnExec(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    /// Text for an errno value, for example "Connection refused (61)".
    public static func errorText(_ code: Int32) -> String {
        "\(String(cString: strerror(code))) (\(code))"
    }
}

// MARK: - Client

/// One open connection to the Spool socket. It can send many requests, one at a time.
/// Calls block for at most `timeout` per read or write.
public final class IPCConnection {
    public let socketPath: String
    private var fd: Int32
    private var buffer = LineBuffer()
    private var readyLines: [Data] = []

    public init(socketPath: String, timeout: TimeInterval = IPCClient.defaultTimeout) throws {
        guard let addr = IPCSocket.address(for: socketPath) else { throw IPCClient.Error.pathTooLong(socketPath) }
        self.socketPath = socketPath
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCClient.Error.io("socket: \(IPCSocket.errorText(errno))") }
        IPCSocket.setCloseOnExec(fd)
        IPCSocket.setNoSigPipe(fd)
        IPCSocket.setTimeouts(fd, seconds: timeout)
        var result: Int32
        repeat {
            result = IPCSocket.withSockaddr(addr) { connect(fd, $0, $1) }
        } while result != 0 && errno == EINTR
        if result != 0 {
            let code = errno
            Darwin.close(fd)
            fd = -1
            switch code {
            case ENOENT, ECONNREFUSED, ENOTSOCK: throw IPCClient.Error.notRunning
            case ETIMEDOUT, EAGAIN: throw IPCClient.Error.timeout
            default: throw IPCClient.Error.io("connect to \(socketPath): \(IPCSocket.errorText(code))")
            }
        }
    }

    deinit { close() }

    public func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    /// Sends one request and waits for its response.
    public func send(_ request: IPCRequest) throws -> IPCResponse {
        let data: Data
        do { data = try IPCWire.encode(request) } catch { throw IPCClient.Error.protocolError("Cannot encode the request: \(error)") }
        try writeAll(data)
        let line = try readLine()
        do { return try IPCWire.decodeResponse(line) } catch {
            throw IPCClient.Error.protocolError("The response is not valid: \(IPCWire.describe(error))")
        }
    }

    /// Writes raw bytes. For tests and tools that speak the wire format directly.
    public func writeAll(_ data: Data) throws {
        guard fd >= 0 else { throw IPCClient.Error.protocolError("The connection is closed.") }
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { raw in
                Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
            }
            if n > 0 { offset += n; continue }
            let code = errno
            if n < 0 && code == EINTR { continue }
            if n < 0 && (code == EAGAIN || code == EWOULDBLOCK) { throw IPCClient.Error.timeout }
            throw IPCClient.Error.protocolError("Spool closed the connection (\(IPCSocket.errorText(code))).")
        }
    }

    /// Reads the next line (without `\n`).
    public func readLine() throws -> Data {
        guard fd >= 0 else { throw IPCClient.Error.protocolError("The connection is closed.") }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while readyLines.isEmpty {
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n > 0 {
                do { readyLines += try buffer.append(Data(chunk[0..<n])) } catch {
                    throw IPCClient.Error.protocolError("The response is longer than \(IPCWire.maxLineLength) bytes.")
                }
                continue
            }
            let code = errno
            if n < 0 && code == EINTR { continue }
            if n < 0 && (code == EAGAIN || code == EWOULDBLOCK) { throw IPCClient.Error.timeout }
            if n == 0 { throw IPCClient.Error.protocolError("Spool closed the connection before it answered.") }
            throw IPCClient.Error.protocolError("Cannot read the response (\(IPCSocket.errorText(code))).")
        }
        return readyLines.removeFirst()
    }

    /// Closes the write side, so the server sees end of input. Reads still work.
    public func shutdownWrite() {
        if fd >= 0 { _ = shutdown(fd, SHUT_WR) }
    }
}

/// Sends one request to the running app and returns its response.
public struct IPCClient: Sendable {
    public static let defaultTimeout: TimeInterval = 2

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// No app listens on the socket.
        case notRunning
        /// The app did not answer in time.
        case timeout
        /// The socket path is longer than macOS allows.
        case pathTooLong(String)
        /// The app sent something that is not a valid response, or closed the connection.
        case protocolError(String)
        /// Another socket error, for example no permission.
        case io(String)

        public var description: String {
            switch self {
            case .notRunning: return "Spool is not running. Open Spool.app."
            case .timeout: return "Spool did not answer in time."
            case .pathTooLong(let p): return "The socket path is too long (more than \(IPCSocket.maxPathLength) bytes): \(p)"
            case .protocolError(let m): return m
            case .io(let m): return "Cannot connect to Spool: \(m)"
            }
        }
    }

    public var socketPath: String
    public var timeout: TimeInterval

    public init(socketPath: String = SpoolPaths.socket.path, timeout: TimeInterval = IPCClient.defaultTimeout) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public func send(_ request: IPCRequest) throws -> IPCResponse {
        try IPCConnection(socketPath: socketPath, timeout: Self.timeout(for: request, base: timeout)).send(request)
    }

    /// Start, stop and restart answer only after the engine moved every parked window back and the apps
    /// confirmed it. One slow app can make that take seconds, so these commands wait longer.
    public static let lifecycleTimeout: TimeInterval = 10

    public static func timeout(for request: IPCRequest, base: TimeInterval) -> TimeInterval {
        // A license key starts the engine, which can take as long as `start`.
        if request.licenseKey != nil { return max(base, lifecycleTimeout) }
        switch request.command {
        case .start?, .stop?, .toggleEngine?, .restart?: return max(base, lifecycleTimeout)
        default: return base
        }
    }
}

// MARK: - CLI

/// The `spool` command-line tool as pure functions: parse, run and format.
/// `Sources/spool-cli/main.swift` only does the I/O.
public enum SpoolCLI {
    public enum ExitCode: Int32, Sendable {
        case ok = 0
        /// The command failed, or the engine sent an error.
        case failed = 1
        /// The arguments are wrong.
        case usage = 2
        /// Spool is not running.
        case notRunning = 3
    }

    public struct Options: Equatable, Sendable {
        public var json = false
        public var socketPath: String?
        /// `--days` of `spool report`. Nil when not given.
        public var days: Int?
        public init(json: Bool = false, socketPath: String? = nil, days: Int? = nil) {
            self.json = json
            self.socketPath = socketPath
            self.days = days
        }
    }

    public enum Action: Equatable, Sendable {
        case send(IPCRequest)
        /// Help for a topic, or the general help when nil.
        case help(String?)
        case listCommands
        case version
        /// `spool report`: read the local metrics files of the last `days` days.
        case report(days: Int)
        /// No arguments: print the usage to stderr.
        case missingCommand
        case error(String)
    }

    public struct Invocation: Equatable, Sendable {
        public var action: Action
        public var options: Options
        public init(action: Action, options: Options = Options()) {
            self.action = action
            self.options = options
        }
    }

    public struct Output: Equatable, Sendable {
        public var stdout: String
        public var stderr: String
        public var code: ExitCode
        public init(stdout: String = "", stderr: String = "", code: ExitCode = .ok) {
            self.stdout = stdout
            self.stderr = stderr
            self.code = code
        }
    }

    /// One line of `spool list`.
    public struct Entry: Equatable, Sendable, Codable {
        /// The name, for example `focus-left`, or the base name of a command with a number, for example `focus-index`.
        public var name: String
        /// How to type it, for example `focus-index <1-9>`.
        public var usage: String
        public var title: String
        /// URL example, for example `spool://focus-index/3`. Nil for queries.
        public var url: String?
    }

    public static let socketEnvironmentKey = "SPOOL_SOCKET"

    // MARK: Catalog

    /// Commands that take a number, with the text for their argument.
    static let parametrized: [(name: String, argument: String, title: String, example: String)] = [
        ("focus-index", "<1-9>", "Focus place <n> (9 is the last place)", "3"),
        ("move-to-index", "<1-9>", "Move column to place <n> (9 is the last place)", "3"),
        ("focus-window", "<id>", "Focus the window with this ID (see spool state --json)", "1234"),
    ]

    public static let queries: [Entry] = [
        Entry(name: "ping", usage: "ping", title: "Check that Spool is running", url: nil),
        Entry(name: "state", usage: "state", title: "Show displays, columns and windows", url: nil),
        Entry(name: "stats", usage: "stats", title: "Show performance counters", url: nil),
    ]

    static let metaWords = ["help", "list", "commands", "version", "command", "report", "license"]

    /// `spool report` runs in the CLI: it reads the metrics files, so it also works when Spool is not running.
    /// Spool writes the mark after it answers (off the main thread), so the CLI cannot name the folder.
    public static let markReply = "Saving a mark (see engine.log for the folder)\n"
    public static let reportEntry = Entry(name: "report", usage: "report [--days <n>]", title: "Show the local metrics report", url: nil)

    /// `spool license` shows the license of the running app. `spool license <key>` activates a key.
    public static let licenseEntry = Entry(name: "license", usage: "license [<key>]", title: "Show the license, or activate a license key", url: "spool://license?key=<key>")

    /// Days in a report: `--days` must be in this range.
    public static let reportDays = 1...90
    public static let defaultReportDays = 7

    /// Every command the CLI accepts, in the order of the Shortcuts page. Commands with a number are one entry.
    public static let commandEntries: [Entry] = {
        var entries: [Entry] = []
        var seen = Set<String>()
        let extra: [Command] = [.focusWindow(0), .start, .stop, .restart]
        for command in Command.bindable + extra {
            let name = baseName(of: command)
            guard seen.insert(name).inserted else { continue }
            if let p = parametrized.first(where: { $0.name == name }) {
                entries.append(Entry(name: name, usage: "\(name) \(p.argument)", title: p.title, url: "spool://\(name)/\(p.example)"))
            } else if command == .mark {
                entries.append(Entry(name: name, usage: "mark [<note>]", title: command.title, url: "spool://mark"))
            } else {
                entries.append(Entry(name: name, usage: name, title: command.title, url: "spool://\(name)"))
            }
        }
        return entries
    }()

    static func baseName(of command: Command) -> String {
        switch command {
        case .focusIndex: return "focus-index"
        case .moveToIndex: return "move-to-index"
        case .focusWindow: return "focus-window"
        default: return command.name
        }
    }

    /// Same normalization as `Command(name:)`.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }

    // MARK: Parse

    public static func parse(_ args: [String]) -> Invocation {
        var options = Options()
        var words: [String] = []
        var wantsHelp = false
        var wantsVersion = false
        var i = 0
        func fail(_ message: String) -> Invocation { Invocation(action: .error(message), options: options) }
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--json": options.json = true
            case "--socket":
                guard i + 1 < args.count, !args[i + 1].isEmpty else { return fail("--socket needs a path.") }
                options.socketPath = args[i + 1]
                i += 1
            case "--days":
                guard i + 1 < args.count, let n = Int(args[i + 1]) else { return fail(daysError) }
                options.days = n
                i += 1
            case "-h", "--help": wantsHelp = true
            case "-V", "-v", "--version": wantsVersion = true
            case "--": words.append(contentsOf: args[(i + 1)...]); i = args.count; continue
            default:
                if arg.hasPrefix("--socket=") {
                    let path = String(arg.dropFirst("--socket=".count))
                    guard !path.isEmpty else { return fail("--socket needs a path.") }
                    options.socketPath = path
                } else if arg.hasPrefix("--days=") {
                    guard let n = Int(arg.dropFirst("--days=".count)) else { return fail(daysError) }
                    options.days = n
                } else if arg.hasPrefix("-"), arg.count > 1 {
                    return fail("Unknown option '\(arg)'.")
                } else {
                    words.append(arg)
                }
            }
            i += 1
        }

        if wantsVersion { return Invocation(action: .version, options: options) }
        if wantsHelp {
            guard words.count <= 1 else { return fail("help takes one topic.") }
            return Invocation(action: helpAction(words.first), options: options)
        }
        guard let first = words.first else { return Invocation(action: .missingCommand, options: options) }
        let rest = Array(words.dropFirst())
        let word = normalize(first)
        if options.days != nil, word != "report" { return fail("--days works only with report.") }
        let action: Action
        switch word {
        case "help":
            action = rest.count <= 1 ? helpAction(rest.first) : .error("help takes one topic.")
        case "list", "commands":
            action = rest.isEmpty ? .listCommands : .error("\(word) takes no argument.")
        case "version":
            action = rest.isEmpty ? .version : .error("version takes no argument.")
        case "ping", "state", "stats":
            action = rest.isEmpty ? .send(IPCRequest(query: IPCRequest.Query(rawValue: word)!)) : .error("\(word) takes no argument.")
        case "report":
            let days = options.days ?? defaultReportDays
            if !rest.isEmpty {
                action = .error("report takes no argument. Use --days <n>.")
            } else {
                action = reportDays.contains(days) ? .report(days: days) : .error(daysError)
            }
        case "mark":
            action = markAction(rest)
        case "license":
            action = licenseAction(rest)
        case "command":
            if rest.isEmpty {
                action = .error("command needs a command name. Example: spool command focus-left")
            } else if normalize(rest[0]) == "mark" {
                action = markAction(Array(rest.dropFirst()))
            } else if let q = IPCRequest.Query(rawValue: normalize(rest[0])), q != .flushMetrics {
                action = rest.count == 1 ? .send(IPCRequest(query: q)) : .error("\(q.rawValue) takes no argument.")
            } else {
                action = parseCommand(rest)
            }
        default:
            action = parseCommand(words)
        }
        return Invocation(action: action, options: options)
    }

    static let daysError = "--days needs a number from 1 to 90. Example: spool report --days 30"

    /// `spool mark [<note>...]`: the words after `mark` are the note.
    static func markAction(_ noteWords: [String]) -> Action {
        let note = noteWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return .send(IPCRequest(command: .mark, note: note.isEmpty ? nil : note))
    }

    /// `spool license [<key>...]`: the words after `license` are the key. An email client can wrap the key, and a
    /// shell then splits it into several words, so they join without white space.
    static func licenseAction(_ keyWords: [String]) -> Action {
        let key = LicenseKey.normalized(keyWords.joined())
        return .send(key.isEmpty ? IPCRequest(query: .license) : IPCRequest(licenseKey: key))
    }

    static func parseCommand(_ words: [String]) -> Action {
        let raw = words[0]
        let name = normalize(raw)
        let param = parametrized.first { $0.name == name || name.hasPrefix($0.name + "-") }
        switch words.count {
        case 1:
            if let c = Command(name: raw) { return .send(IPCRequest(command: c)) }
            if let p = param { return .error(argumentError(p.name)) }
            return .error(unknownMessage(raw))
        case 2:
            if let p = param, p.name == name {
                if let c = Command(name: "\(name)-\(words[1])") { return .send(IPCRequest(command: c)) }
                return .error(argumentError(p.name))
            }
            if Command(name: raw) != nil { return .error("\(name) takes no argument.") }
            return .error(unknownMessage(raw))
        default:
            return .error("Too many arguments for \(name).")
        }
    }

    static func argumentError(_ name: String) -> String {
        if name == "focus-window" {
            return "focus-window needs a window ID (a number). Run 'spool state --json' to see window IDs."
        }
        return "\(name) needs a number from 1 to 9 (9 is the last place). Example: spool \(name) 3"
    }

    static func helpAction(_ topic: String?) -> Action {
        guard let topic else { return .help(nil) }
        guard let resolved = resolveTopic(topic) else { return .error(unknownMessage(topic, what: "help topic")) }
        return .help(resolved)
    }

    /// Maps a help topic to a known name, for example `focus-index-3` to `focus-index`.
    static func resolveTopic(_ topic: String) -> String? {
        let t = normalize(topic)
        if metaWords.contains(t) || queries.contains(where: { $0.name == t }) { return t == "commands" ? "list" : t }
        if let c = Command(name: t) { return baseName(of: c) }
        if let p = parametrized.first(where: { $0.name == t }) { return p.name }
        return nil
    }

    // MARK: Suggestions

    /// Every word that can start a command line.
    public static var knownWords: [String] {
        commandEntries.map(\.name) + queries.map(\.name) + metaWords
    }

    static func unknownMessage(_ raw: String, what: String = "command") -> String {
        var message = "Unknown \(what) '\(raw)'."
        // A word that is known but not allowed here (for example `spool command help`) gets no suggestion of itself.
        if let s = suggestion(for: raw), s != normalize(raw) { message += " Did you mean '\(s)'?" }
        return message
    }

    /// The closest known word, if it is near enough to be a typo.
    public static func suggestion(for raw: String) -> String? {
        let word = normalize(raw)
        guard !word.isEmpty else { return nil }
        let limit = max(2, word.count / 3)
        // On a tie, a word that starts with the typed text wins ("stat" is "state", not "start").
        var best: (word: String, score: Int)?
        for candidate in knownWords {
            let d = editDistance(word, candidate)
            guard d <= limit else { continue }
            let score = d * 2 + (candidate.hasPrefix(word) ? 0 : 1)
            if score < (best?.score ?? .max) { best = (candidate, score) }
        }
        return best?.word
    }

    /// Levenshtein distance.
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = previous
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: Run

    /// The socket to use: `--socket`, then `$SPOOL_SOCKET`, then the default path.
    public static func socketPath(option: String?, environment: [String: String]) -> String {
        if let option, !option.isEmpty { return option }
        if let env = environment[socketEnvironmentKey], !env.isEmpty { return env }
        return SpoolPaths.socket.path
    }

    /// The version line for an app `Info.plist` dictionary, for example `spool 1.2.0 (45)`.
    public static func versionLine(info: [String: Any]?) -> String {
        guard let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty else { return "spool dev" }
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty, build != short { return "spool \(short) (\(build))" }
        return "spool \(short)"
    }

    /// Reads the metrics files for `spool report`.
    public typealias MetricsLoader = (_ days: Int) -> (days: [DayMetrics], skipped: [String])

    /// The files in `SpoolPaths.metricsDirectory`.
    public static func readMetricsFiles(days: Int) -> (days: [DayMetrics], skipped: [String]) {
        MetricsStore.load(directory: SpoolPaths.metricsDirectory, days: days)
    }

    /// Runs a parsed invocation. `send` talks to the app; it is only called for `.send` and `.report`.
    /// `loadMetrics` reads the metrics files for `.report`; tests give their own.
    public static func run(_ invocation: Invocation, versionLine: String, send: (IPCRequest) throws -> IPCResponse,
                           loadMetrics: MetricsLoader = { SpoolCLI.readMetricsFiles(days: $0) }) -> Output {
        let json = invocation.options.json
        switch invocation.action {
        case .report(let days):
            // A running app keeps the last minute in memory. Not running is fine: the files are all there is.
            _ = try? send(IPCRequest(query: .flushMetrics))
            let loaded = loadMetrics(days)
            let report = MetricsReport.make(days: loaded.days, skipped: loaded.skipped)
            if json {
                guard let text = try? IPCWire.prettyJSON(report) else { return Output(stderr: "Cannot encode the report.\n", code: .failed) }
                return Output(stdout: text + "\n")
            }
            let text = report.renderText()
            return Output(stdout: text.hasSuffix("\n") ? text : text + "\n")
        case .help(let topic):
            return Output(stdout: helpText(topic: topic))
        case .listCommands:
            if json {
                return Output(stdout: ((try? IPCWire.prettyJSON(commandEntries + queries + [reportEntry, licenseEntry])) ?? "[]") + "\n")
            }
            return Output(stdout: listText())
        case .version:
            return Output(stdout: versionLine + "\n")
        case .missingCommand:
            return Output(stderr: usageText(), code: .usage)
        case .error(let message):
            return Output(stderr: message + "\nRun 'spool help' for usage.\n", code: .usage)
        case .send(let request):
            let response: IPCResponse
            do {
                response = try send(request)
            } catch let error as IPCClient.Error {
                return Output(stderr: error.description + "\n", code: error == .notRunning ? .notRunning : .failed)
            } catch {
                return Output(stderr: "\(error)\n", code: .failed)
            }
            return output(for: request, response: response, json: json)
        }
    }

    static func output(for request: IPCRequest, response: IPCResponse, json: Bool) -> Output {
        if json {
            guard let text = try? IPCWire.prettyJSON(response) else { return Output(stderr: "Cannot encode the response.\n", code: .failed) }
            return Output(stdout: text + "\n", code: response.ok ? .ok : .failed)
        }
        guard response.ok else {
            return Output(stderr: (response.error ?? "The command failed.") + "\n", code: .failed)
        }
        switch request.query {
        case .ping:
            return Output(stdout: "Spool is running.\n")
        case .state:
            guard let state = response.state else { return Output(stderr: "The response has no state.\n", code: .failed) }
            return Output(stdout: format(state: state))
        case .stats:
            guard let stats = response.stats else { return Output(stderr: "The response has no stats.\n", code: .failed) }
            return Output(stdout: format(stats: stats))
        case .flushMetrics:
            return Output()
        case .license:
            return Output(stdout: (response.license?.text ?? LicenseReport.notLicensedText) + "\n")
        case nil:
            if request.licenseKey != nil { return Output(stdout: (response.license?.text ?? "Licensed.") + "\n") }
            if request.command == .mark { return Output(stdout: markReply) }
            return Output()
        }
    }

    // MARK: Text

    public static func usageText() -> String {
        """
        Usage: spool <command> [<n>] [--json] [--socket <path>]

        Control Spool, the scrolling window manager, from the terminal.

        Examples:
          spool focus-left
          spool focus-index 3
          spool state
          spool stats   --json

        Main commands:
          spool list                Show all commands.
          spool help <command>      Show help for one command.
          spool ping                Check that Spool is running.
          spool state               Show displays, columns and windows.
          spool stats               Show performance counters.
          spool report              Show speed, use and problems of the last 7 days.
          spool mark [<note>]       Save the state of this moment, with a note.
          spool license [<key>]     Show the license, or activate a license key.
          spool command <name>      Run a command by name (same as spool <name>).
          spool --version           Show the version.

        Options:
          --json                    Print the full response as JSON.
          --days <n>                Days in the report, 1 to 90 (default 7).
          --socket <path>           Use this socket. You can also set SPOOL_SOCKET.
                                    Default: ~/Library/Application Support/Spool/spool.sock

        Exit codes: 0 OK, 1 command failed, 2 usage error, 3 Spool is not running.

        """
    }

    public static func helpText(topic: String?) -> String {
        guard let topic else { return usageText() }
        if let p = parametrized.first(where: { $0.name == topic }) {
            return """
            Usage: spool \(p.name) \(p.argument)

            \(p.title).
            You can also write \(p.name)-\(p.example).

            URL: spool://\(p.name)/\(p.example)

            """
        }
        if topic == "license" {
            return """
            Usage: spool license [<key>] [--json]

            Without a key: show who the license of this copy of Spool is for. Prints "Not licensed." and
            exits with 1 when there is no valid license.
            With a key: send the key to the running Spool, which checks it, stores it in:
              \(SpoolPaths.supportDirectory.appendingPathComponent("license.key").path)
            and starts the window manager. A key that is not valid prints "\(LicenseKey.invalidMessage)" and exits with 1.
            A build from swift build needs no license.

            URL: spool://license?key=<key>

            """
        }
        if topic == "mark" {
            return """
            Usage: spool mark [<note>]

            Save the state of this moment, for example when something went wrong. Spool writes the
            state (without window titles), the stats, the metrics of today, the last minute of the
            engine log and your note to a new folder in:
              \(SpoolPaths.marksDirectory.path)
            Spool writes the folder after it answers. The engine log names it:
              \(SpoolPaths.logFile.path)
            Shortcut: ⌃⌥⇧M. Needs metrics on (Settings > General).

            URL: spool://mark

            """
        }
        if let entry = commandEntries.first(where: { $0.name == topic }) {
            return "Usage: spool \(entry.usage)\n\n\(entry.title).\n\nURL: \(entry.url ?? "")\n"
        }
        if let q = queries.first(where: { $0.name == topic }) {
            let usage = q.name == "ping" ? "spool ping" : "spool \(q.name) [--json]"
            return "Usage: \(usage)\n\n\(q.title).\n--json prints the full response as JSON.\n"
        }
        switch topic {
        case "list": return "Usage: spool list [--json]\n\nShow all commands with a short description.\n"
        case "help": return "Usage: spool help [<command>]\n\nShow the general help, or help for one command.\n"
        case "version": return "Usage: spool --version\n\nShow the version of Spool.\n"
        case "command": return "Usage: spool command <name> [<n>]\n\nRun a command by name. Same as spool <name>.\n"
        case "report":
            return """
            Usage: spool report [--days <n>] [--json]

            Show the local metrics of the last <n> days (1 to 90, default 7): live budgets (PASS or FAIL),
            speed, cost, problems, the most used commands, friction per app and the slowest apps.
            It reads the files in \(SpoolPaths.metricsDirectory.path),
            so it also works when Spool is not running. See docs/METRICS.md.
            --json prints the full report as JSON.

            """
        default: return usageText()
        }
    }

    public static func listText() -> String {
        let width = (commandEntries + queries).map(\.usage.count).max()! + 2
        func line(_ e: Entry) -> String { "  " + e.usage.padding(toLength: width, withPad: " ", startingAt: 0) + e.title }
        return (["Commands:"] + commandEntries.map(line) + ["", "Queries:"] + (queries + [reportEntry, licenseEntry]).map(line))
            .joined(separator: "\n") + "\n"
    }

    // MARK: Format

    /// Human text for `spool state`.
    public static func format(state s: EngineState) -> String {
        var lines: [String] = []
        lines.append("Engine: \(s.running ? "running" : "stopped"). Accessibility: \(s.accessibilityTrusted ? "granted" : "not granted").")
        if let f = s.focusedWindow {
            lines.append("Focused: \(label(f)) (window \(f.id))")
        } else {
            lines.append("Focused: none")
        }
        if s.displays.isEmpty { lines.append("Displays: none") }
        for d in s.displays {
            lines.append("Display: \(d.name) (\(d.enabled ? "on" : "off"), space \(d.spaceID))")
            if d.columns.isEmpty {
                lines.append("  (no windows)")
            } else {
                let columns = d.columns.enumerated().map { i, column in
                    "[\(i + 1)\(i == d.focusedColumn ? "*" : "")] " + column.map(label).joined(separator: " + ")
                }
                lines.append("  " + columns.joined(separator: " | "))
            }
        }
        if !s.floating.isEmpty { lines.append("Floating: " + s.floating.map(label).joined(separator: ", ")) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Human text for `spool stats`.
    public static func format(stats s: EngineStats) -> String {
        let rows: [(String, String)] = [
            ("Uptime", duration(s.uptimeSeconds)),
            ("Frames written", "\(s.framesWritten)"),
            ("Window writes", "\(s.windowWrites)"),
            ("Skipped writes", "\(s.skippedWrites)"),
            ("Coalesced writes", "\(s.coalescedWrites)"),
            ("AX errors", "\(s.axErrors)"),
        ] + (s.closedWindowWrites.map { [("Closed-window writes", "\($0) (the window closed first; not errors)")] } ?? []) + [
            ("Frame write", "p50 \(ms(s.frameWriteP50)), p95 \(ms(s.frameWriteP95))"),
        ] + (s.frameOwnP50.flatMap { p50 in s.frameOwnP95.map { p95 in
            [("Spool's part", "p50 \(ms(p50)), p95 \(ms(p95)) (frame write without the AX calls)")] } } ?? []) + [
            ("Command latency", "p50 \(ms(s.commandLatencyP50)), p95 \(ms(s.commandLatencyP95))"),
            ("Restarts", "\(s.restarts)"),
        ]
        let width = rows.map(\.0.count).max()! + 2
        var lines = rows.map { ($0.0 + ":").padding(toLength: width, withPad: " ", startingAt: 0) + $0.1 }
        if let apps = s.slowestApps, !apps.isEmpty {
            let names = apps.map { (app($0.bundleID, pid: $0.pid)) + " (\($0.pid))" }
            let nameWidth = names.map(\.count).max()! + 2
            lines.append("Slowest apps (AX write per window):")
            for (a, name) in zip(apps, names) {
                lines.append("  " + name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                             + "p50 \(ms(a.axP50)), p95 \(ms(a.axP95)), latency p95 \(ms(a.latencyP95)), \(a.writes) writes")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `Safari "Apple"`: the last part of the bundle ID and the title (shortened to 40 characters).
    static func label(_ w: WindowInfo) -> String {
        let app = app(w.bundleID, pid: w.pid)
        var title = w.title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        if title.count > 40 { title = String(title.prefix(37)) + "..." }
        return title.isEmpty ? app : "\(app) \"\(title)\""
    }

    /// The last part of the bundle ID, else `pid 123`.
    static func app(_ bundleID: String, pid: Int32) -> String {
        bundleID.split(separator: ".").last.map(String.init) ?? "pid \(pid)"
    }

    static func ms(_ v: Double) -> String { v.isFinite ? String(format: "%.2f ms", v) : "n/a" }

    static func duration(_ seconds: Double) -> String {
        let total = seconds.isFinite && seconds > 0 ? Int(seconds) : 0
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }
}
