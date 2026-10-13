import Foundation

/// Files Striple uses. All paths are per user.
///
/// Test only: when `STRIPLE_HOME` is set and not empty, all files go in that folder and the logs in
/// `$STRIPLE_HOME/Logs`. The E2E runner uses it, so a test run never reads or writes the user's settings.
public enum StriplePaths {
    public static let homeEnvironmentKey = "STRIPLE_HOME"

    /// The two folders Striple writes to.
    public struct Folders: Equatable, Sendable {
        public var support: URL
        public var logs: URL
        /// True when `STRIPLE_HOME` chose the folders (a test run).
        public var isolated: Bool
    }

    /// The folders for an environment. `home` is the user's home folder.
    public static func resolve(environment: [String: String], home: URL) -> Folders {
        if let custom = environment[homeEnvironmentKey], !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            let root = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            return Folders(support: root, logs: root.appendingPathComponent("Logs", isDirectory: true), isolated: true)
        }
        return Folders(support: home.appendingPathComponent("Library/Application Support/Striple", isDirectory: true),
                       logs: home.appendingPathComponent("Library/Logs/Striple", isDirectory: true), isolated: false)
    }

    /// Read once: the environment of a process does not change.
    public static let current = resolve(environment: ProcessInfo.processInfo.environment,
                                        home: FileManager.default.homeDirectoryForCurrentUser)

    /// True when `STRIPLE_HOME` is set: a test run that must not touch the user's login item or settings.
    public static var isIsolated: Bool { current.isolated }

    public static var supportDirectory: URL { current.support }

    public static var configFile: URL { supportDirectory.appendingPathComponent("config.json") }
    public static var sessionFile: URL { supportDirectory.appendingPathComponent("session.json") }
    public static var socket: URL { supportDirectory.appendingPathComponent("striple.sock") }

    public static var logDirectory: URL { current.logs }

    public static var logFile: URL { logDirectory.appendingPathComponent("engine.log") }
}

/// A request from the CLI (or another tool) to the running app. One JSON object per line.
public struct IPCRequest: Codable, Equatable, Sendable {
    public enum Query: String, Codable, Sendable {
        case ping, state, stats
        /// Internal: `striple report` asks the app to write its metrics to disk first. Not a user command.
        case flushMetrics = "flush-metrics"
    }

    public var command: Command?
    public var query: Query?
    /// The note of a `mark` command. Nil for other requests, and not in the JSON then.
    public var note: String?

    public init(command: Command, note: String? = nil) { self.command = command; self.query = nil; self.note = note }
    public init(query: Query) { self.command = nil; self.query = query; self.note = nil }
}

public struct IPCResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var state: EngineState?
    public var stats: EngineStats?

    public init(ok: Bool, error: String? = nil, state: EngineState? = nil, stats: EngineStats? = nil) {
        self.ok = ok
        self.error = error
        self.state = state
        self.stats = stats
    }
}

/// Snapshot of the engine for `striple state`.
public struct EngineState: Codable, Equatable, Sendable {
    public struct DisplayState: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var enabled: Bool
        public var spaceID: UInt64
        public var focusedColumn: Int
        public var scroll: Double
        public var columns: [[WindowInfo]]

        public init(id: String, name: String, enabled: Bool, spaceID: UInt64, focusedColumn: Int, scroll: Double, columns: [[WindowInfo]]) {
            self.id = id
            self.name = name
            self.enabled = enabled
            self.spaceID = spaceID
            self.focusedColumn = focusedColumn
            self.scroll = scroll
            self.columns = columns
        }
    }

    public var running: Bool
    public var accessibilityTrusted: Bool
    public var focusedWindow: WindowInfo?
    public var displays: [DisplayState]
    public var floating: [WindowInfo]

    public init(running: Bool, accessibilityTrusted: Bool, focusedWindow: WindowInfo?, displays: [DisplayState], floating: [WindowInfo]) {
        self.running = running
        self.accessibilityTrusted = accessibilityTrusted
        self.focusedWindow = focusedWindow
        self.displays = displays
        self.floating = floating
    }
}

/// Performance counters for `striple stats`. Times are in milliseconds.
public struct EngineStats: Codable, Equatable, Sendable {
    public var uptimeSeconds: Double
    public var framesWritten: Int
    public var windowWrites: Int
    public var skippedWrites: Int
    public var coalescedWrites: Int
    public var axErrors: Int
    public var frameWriteP50: Double
    public var frameWriteP95: Double
    public var commandLatencyP50: Double
    public var commandLatencyP95: Double
    public var restarts: Int
    /// The apps with the slowest AX writes, slowest first. Nil from an app that does not report it.
    public var slowestApps: [AppWriteStats]?

    public init(uptimeSeconds: Double = 0, framesWritten: Int = 0, windowWrites: Int = 0, skippedWrites: Int = 0, coalescedWrites: Int = 0,
                axErrors: Int = 0, frameWriteP50: Double = 0, frameWriteP95: Double = 0, commandLatencyP50: Double = 0,
                commandLatencyP95: Double = 0, restarts: Int = 0, slowestApps: [AppWriteStats]? = nil) {
        self.uptimeSeconds = uptimeSeconds
        self.framesWritten = framesWritten
        self.windowWrites = windowWrites
        self.skippedWrites = skippedWrites
        self.coalescedWrites = coalescedWrites
        self.axErrors = axErrors
        self.frameWriteP50 = frameWriteP50
        self.frameWriteP95 = frameWriteP95
        self.commandLatencyP50 = commandLatencyP50
        self.commandLatencyP95 = commandLatencyP95
        self.restarts = restarts
        self.slowestApps = slowestApps
    }
}

/// AX write times of one app, in milliseconds.
public struct AppWriteStats: Codable, Equatable, Sendable {
    public var bundleID: String
    public var pid: Int32
    /// Window writes measured (the newest 128 give the percentiles).
    public var writes: Int
    /// The AX calls of one window write.
    public var axP50: Double
    public var axP95: Double
    /// From the layout tick that queued a frame until it was written. It includes the wait for earlier writes.
    public var latencyP95: Double

    public init(bundleID: String, pid: Int32, writes: Int, axP50: Double, axP95: Double, latencyP95: Double) {
        self.bundleID = bundleID
        self.pid = pid
        self.writes = writes
        self.axP50 = axP50
        self.axP95 = axP95
        self.latencyP95 = latencyP95
    }
}

/// A fixed-size ring of samples with percentiles. Used for the timing stats.
public struct SampleWindow: Sendable {
    private var samples: [Double]
    private var next = 0
    private var filled = false

    public init(capacity: Int = 512) { samples = Array(repeating: 0, count: max(capacity, 1)) }

    public mutating func add(_ v: Double) {
        samples[next] = v
        next = (next + 1) % samples.count
        if next == 0 { filled = true }
    }

    public var count: Int { filled ? samples.count : next }

    /// Nearest-rank percentile, `p` in 0...100. 0 when there are no samples.
    public func percentile(_ p: Double) -> Double {
        let n = count
        guard n > 0 else { return 0 }
        let sorted = samples[0..<n].sorted()
        let rank = Int((p / 100 * Double(n)).rounded(.up))
        return sorted[min(max(rank - 1, 0), n - 1)]
    }
}

/// Parses `striple://` URLs. Accepts `striple://focus-left`, `striple://focus-index/3`
/// and `striple://command?name=focus-left`.
public enum StripleURL {
    public static let scheme = "striple"

    public static func command(from url: URL) -> Command? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let host = url.host ?? ""
        if host == "command" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return items.first { $0.name == "name" }?.value.flatMap(Command.init(name:))
        }
        let path = url.path.split(separator: "/").joined(separator: "-")
        return Command(name: path.isEmpty ? host : "\(host)-\(path)")
    }

    public static func url(for command: Command) -> URL {
        URL(string: "\(scheme)://\(command.name)")!
    }
}
