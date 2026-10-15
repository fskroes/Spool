import Foundation

/// Spool had the name Striple before. At the first start of Spool, the settings, the session, the metrics and
/// the logs of Striple move to the Spool folders, so the rename loses nothing (docs/INSTALL.md, "Upgrade from
/// Striple"). A Striple that still runs is stopped first: two window managers would move the same windows.
public enum LegacyMigration {
    /// The bundle ID of Striple.
    public static let bundleID = "com.fskroes.Striple"
    /// The socket of Striple. Nothing listens on it after the move, so it is removed.
    public static let socketName = "striple.sock"

    /// The folders that Striple used.
    public static func folders(home: URL) -> SpoolPaths.Folders {
        SpoolPaths.Folders(support: home.appendingPathComponent("Library/Application Support/Striple", isDirectory: true),
                           logs: home.appendingPathComponent("Library/Logs/Striple", isDirectory: true), isolated: false)
    }

    public struct Move: Equatable, Sendable {
        public var from: URL
        public var to: URL
    }

    /// A Striple folder moves only when its Spool folder does not exist yet, so Spool never writes over its own
    /// files. A test run (`SPOOL_HOME`) moves nothing.
    public static func plan(current: SpoolPaths.Folders, legacy: SpoolPaths.Folders, exists: (URL) -> Bool) -> [Move] {
        guard !current.isolated else { return [] }
        return [(legacy.support, current.support), (legacy.logs, current.logs)]
            .filter { exists($0.0) && !exists($0.1) }
            .map { Move(from: $0.0, to: $0.1) }
    }

    /// The Striple folders that stay, because their Spool folder exists. Spool does not merge folders: the user
    /// moves what they need by hand (docs/INSTALL.md, "Upgrade from Striple").
    public static func kept(current: SpoolPaths.Folders, legacy: SpoolPaths.Folders, exists: (URL) -> Bool) -> [Move] {
        guard !current.isolated else { return [] }
        return [(legacy.support, current.support), (legacy.logs, current.logs)]
            .filter { exists($0.0) && exists($0.1) }
            .map { Move(from: $0.0, to: $0.1) }
    }

    /// The Striple apps whose login item Spool turns off: the apps that ran, and the installed app. Only when
    /// Striple ran or a Striple folder is still there, so a normal start of Spool runs no Striple. Without this, the
    /// login agent of Striple starts it again at the next login, next to Spool.
    public static func appsToUnregister(running: [URL], installed: URL?, foldersLeft: Bool) -> [URL] {
        guard !running.isEmpty || foldersLeft else { return [] }
        var seen = Set<String>()
        return (running + [installed].compactMap { $0 }).filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// What `run` did.
    public struct Result: Equatable, Sendable {
        /// One line per move, for the engine log.
        public var lines: [String] = []
        /// True when the settings folder moved: the settings of Striple are now the settings of Spool.
        public var movedSettings = false

        public init(lines: [String] = [], movedSettings: Bool = false) {
            self.lines = lines
            self.movedSettings = movedSettings
        }
    }

    /// Does the moves. A move that fails leaves the Striple folder where it is; Spool then starts with new settings.
    /// `settings` is the Spool settings folder, to tell that move from the move of the logs.
    public static func run(_ moves: [Move], settings: URL, fileManager: FileManager = .default) -> Result {
        var result = Result()
        for move in moves {
            do {
                try fileManager.createDirectory(at: move.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: move.from, to: move.to)
                try? fileManager.removeItem(at: move.to.appendingPathComponent(socketName))
                result.lines.append("Striple is now Spool: moved \(move.from.path) to \(move.to.path)")
                if move.to.standardizedFileURL == settings.standardizedFileURL { result.movedSettings = true }
            } catch {
                result.lines.append("Striple is now Spool: could not move \(move.from.path) to \(move.to.path): "
                    + error.localizedDescription)
            }
        }
        return result
    }

    /// True when a Striple folder is still there: it has to move, a move failed, or it is kept.
    public static func foldersLeft(current: SpoolPaths.Folders = SpoolPaths.current,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   fileManager: FileManager = .default) -> Bool {
        guard !current.isolated else { return false }
        let legacy = folders(home: home)
        return [legacy.support, legacy.logs].contains { fileManager.fileExists(atPath: $0.path) }
    }

    /// What `takeOver` needs from the system. The app gives the real functions, tests give fakes.
    public struct System {
        /// The running Striple apps: pid and bundle.
        public var running: () -> [(pid: pid_t, bundle: URL?)]
        /// The installed Striple.app, if any.
        public var installed: () -> URL?
        /// Stops the pids; false when one still runs after the wait (`stop(pids:)`).
        public var stop: ([pid_t]) -> Bool
        /// Runs `Striple --unregister-login` of the app. Returns the log line.
        public var unregister: (URL) -> String
        public var foldersLeft: () -> Bool
        public var migrate: () -> Result

        public init(running: @escaping () -> [(pid: pid_t, bundle: URL?)], installed: @escaping () -> URL?,
                    stop: @escaping ([pid_t]) -> Bool, unregister: @escaping (URL) -> String,
                    foldersLeft: @escaping () -> Bool, migrate: @escaping () -> Result) {
            self.running = running
            self.installed = installed
            self.stop = stop
            self.unregister = unregister
            self.foldersLeft = foldersLeft
            self.migrate = migrate
        }
    }

    public enum TakeOver: Equatable {
        case done(Result)
        /// Striple still runs: Spool must not start (two window managers would move the same windows).
        case stripleStillRuns([pid_t])
    }

    /// Spool replaces Striple, in this order:
    /// 1. A normal quit of Striple, so it saves its layout.
    /// 2. Its login item goes off. A SIGTERM before Striple has its signal handler ends it with an error, and then its
    ///    login agent (KeepAlive) starts it again after 5 seconds. Turning the agent off removes that restart too.
    /// 3. A Striple that its agent started again before step 2 stops too.
    /// 4. The folders move.
    /// A test run (`isolated`) does nothing.
    public static func takeOver(isolated: Bool, _ system: System) -> TakeOver {
        guard !isolated else { return .done(Result()) }
        var lines: [String] = []
        let running = system.running()
        let pids = running.map(\.pid)
        guard system.stop(pids) else { return .stripleStillRuns(pids) }
        if !pids.isEmpty { lines.append("Striple is now Spool: stopped Striple (pid \(list(pids)))") }
        let apps = appsToUnregister(running: running.compactMap(\.bundle), installed: system.installed(),
                                    foldersLeft: system.foldersLeft())
        lines += apps.map(system.unregister)
        if !apps.isEmpty {
            let again = system.running().map(\.pid)
            guard system.stop(again) else { return .stripleStillRuns(again) }
            if !again.isEmpty { lines.append("Striple is now Spool: stopped Striple again (pid \(list(again)))") }
        }
        var result = system.migrate()
        result.lines = lines + result.lines
        return .done(result)
    }

    public static func list(_ pids: [pid_t]) -> String { pids.map(String.init).joined(separator: ", ") }

    /// The moves for the user of this process.
    public static func pendingMoves(current: SpoolPaths.Folders = SpoolPaths.current,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                    fileManager: FileManager = .default) -> [Move] {
        plan(current: current, legacy: folders(home: home)) { fileManager.fileExists(atPath: $0.path) }
    }

    /// Plans and does the moves for the user of this process. A Striple folder that stays gets a log line at each
    /// start, so the user can find the old settings.
    public static func migrate(current: SpoolPaths.Folders = SpoolPaths.current,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               fileManager: FileManager = .default) -> Result {
        var result = run(pendingMoves(current: current, home: home, fileManager: fileManager),
                         settings: current.support, fileManager: fileManager)
        for k in kept(current: current, legacy: folders(home: home), exists: { fileManager.fileExists(atPath: $0.path) }) {
            result.lines.append("Striple is now Spool: kept \(k.from.path), because \(k.to.path) exists. "
                + "Move what you need by hand.")
        }
        return result
    }

    /// Stops the Striple processes `pids` with SIGTERM. Striple then quits the normal way with status 0, so its
    /// LaunchAgent does not start it again. Returns false when one still runs after `timeout` seconds.
    public static func stop(pids: [pid_t], timeout: TimeInterval = 10,
                            signal send: (pid_t) -> Void = { _ = kill($0, SIGTERM) },
                            isAlive: (pid_t) -> Bool = LegacyMigration.isAlive,
                            now: () -> Date = Date.init,
                            sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Bool {
        // NSRunningApplication gives -1 for an app without a pid. kill(-1) and kill(0) signal many processes.
        let pids = pids.filter { $0 > 0 }
        guard !pids.isEmpty else { return true }
        pids.forEach(send)
        let deadline = now().addingTimeInterval(timeout)
        while pids.contains(where: isAlive) {
            guard now() < deadline else { return false }
            sleep(0.1)
        }
        return true
    }

    /// EPERM: the process exists, but belongs to another user.
    public static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}
