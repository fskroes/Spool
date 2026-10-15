import Foundation
import Testing
@testable import SpoolCore

/// Spool had the name Striple. Its files move to the Spool folders at the first start.
@Suite struct LegacyMigrationTests {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    var spool: SpoolPaths.Folders { SpoolPaths.resolve(environment: [:], home: home) }
    var striple: SpoolPaths.Folders { LegacyMigration.folders(home: home) }

    @Test func theStripleFoldersAreTheOldPaths() {
        #expect(striple.support.path == "/Users/someone/Library/Application Support/Striple")
        #expect(striple.logs.path == "/Users/someone/Library/Logs/Striple")
        #expect(LegacyMigration.bundleID == "com.fskroes.Striple")
    }

    @Test func bothFoldersMoveWhenSpoolHasNone() {
        let moves = LegacyMigration.plan(current: spool, legacy: striple) { $0 == striple.support || $0 == striple.logs }
        #expect(moves == [LegacyMigration.Move(from: striple.support, to: spool.support),
                          LegacyMigration.Move(from: striple.logs, to: spool.logs)])
    }

    @Test func anExistingSpoolFolderIsNeverReplaced() {
        let existing: Set<URL> = [striple.support, striple.logs, spool.support]
        let moves = LegacyMigration.plan(current: spool, legacy: striple) { existing.contains($0) }
        #expect(moves == [LegacyMigration.Move(from: striple.logs, to: spool.logs)])
    }

    @Test func withoutStripleNothingMoves() {
        #expect(LegacyMigration.plan(current: spool, legacy: striple) { _ in false }.isEmpty)
    }

    // A test run must never take the settings of the user.
    @Test func aTestRunMovesNothing() {
        let isolated = SpoolPaths.resolve(environment: ["SPOOL_HOME": "/tmp/spool-e2e-a"], home: home)
        #expect(LegacyMigration.plan(current: isolated, legacy: striple) { _ in true }.isEmpty)
    }

    @Test func aStripleFolderNextToASpoolFolderIsKept() {
        let existing: Set<URL> = [striple.support, striple.logs, spool.support]
        #expect(LegacyMigration.kept(current: spool, legacy: striple) { existing.contains($0) }
                == [LegacyMigration.Move(from: striple.support, to: spool.support)])
        #expect(LegacyMigration.kept(current: spool, legacy: striple) { $0 == striple.support }.isEmpty)
        let isolated = SpoolPaths.resolve(environment: ["SPOOL_HOME": "/tmp/spool-e2e-a"], home: home)
        #expect(LegacyMigration.kept(current: isolated, legacy: striple) { _ in true }.isEmpty)
    }

    @Test func aKeptFolderGetsALogLineAtEachStart() throws {
        let fm = FileManager.default
        let home = try Self.stripleHome()
        defer { try? fm.removeItem(at: home) }
        let current = SpoolPaths.resolve(environment: [:], home: home)
        try fm.createDirectory(at: current.support, withIntermediateDirectories: true)
        try Data(#"{"gaps":{"inner":4}}"#.utf8).write(to: current.support.appendingPathComponent("config.json"))

        for _ in 0..<2 {
            let result = LegacyMigration.migrate(current: current, home: home)
            #expect(!result.movedSettings)
            #expect(result.lines.contains("Striple is now Spool: kept \(striple(home).support.path), because "
                                          + "\(current.support.path) exists. Move what you need by hand."))
        }
        // Spool's own settings stay, and so do the settings of Striple.
        #expect(try String(contentsOf: current.support.appendingPathComponent("config.json"), encoding: .utf8)
                == #"{"gaps":{"inner":4}}"#)
        #expect(fm.fileExists(atPath: striple(home).support.appendingPathComponent("config.json").path))
    }

    func striple(_ home: URL) -> SpoolPaths.Folders { LegacyMigration.folders(home: home) }

    @Test func theLoginItemOfStripleIsTurnedOffOnlyWhenStripleRanOrAFolderIsLeft() {
        let a = URL(fileURLWithPath: "/Applications/Striple.app")
        let b = URL(fileURLWithPath: "/Users/someone/dev/dist/Striple.app")
        // A normal start of Spool runs no Striple.
        #expect(LegacyMigration.appsToUnregister(running: [], installed: a, foldersLeft: false).isEmpty)
        #expect(LegacyMigration.appsToUnregister(running: [], installed: a, foldersLeft: true) == [a])
        #expect(LegacyMigration.appsToUnregister(running: [], installed: nil, foldersLeft: true).isEmpty)
        #expect(LegacyMigration.appsToUnregister(running: [b], installed: a, foldersLeft: false) == [b, a])
        // One app once, also with another spelling of the same path.
        #expect(LegacyMigration.appsToUnregister(running: [a, URL(fileURLWithPath: "/Applications/./Striple.app")],
                                                 installed: a, foldersLeft: false) == [a])
    }

    /// A Striple home with settings, session, metrics, the old socket and a log, in a temporary folder.
    static func stripleHome() throws -> URL {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("spool-migration-\(UUID().uuidString)")
        let support = LegacyMigration.folders(home: home).support
        try fm.createDirectory(at: support.appendingPathComponent("metrics"), withIntermediateDirectories: true)
        try Data(#"{"gaps":{"inner":12}}"#.utf8).write(to: support.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: support.appendingPathComponent("session.json"))
        try Data("m".utf8).write(to: support.appendingPathComponent("metrics/2026-10-15.json"))
        try Data().write(to: support.appendingPathComponent("striple.sock"))
        let logs = LegacyMigration.folders(home: home).logs
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("old line\n".utf8).write(to: logs.appendingPathComponent("engine.log"))
        return home
    }

    @Test func theFilesMoveAndTheOldSocketGoes() throws {
        let fm = FileManager.default
        let home = try Self.stripleHome()
        defer { try? fm.removeItem(at: home) }
        let current = SpoolPaths.resolve(environment: [:], home: home)

        let result = LegacyMigration.migrate(current: current, home: home)

        #expect(result.movedSettings)
        #expect(result.lines.count == 2)
        #expect(result.lines.allSatisfy { $0.hasPrefix("Striple is now Spool: moved ") })
        #expect(try String(contentsOf: current.support.appendingPathComponent("config.json"), encoding: .utf8)
                == #"{"gaps":{"inner":12}}"#)
        #expect(fm.fileExists(atPath: current.support.appendingPathComponent("session.json").path))
        #expect(fm.fileExists(atPath: current.support.appendingPathComponent("metrics/2026-10-15.json").path))
        #expect(fm.fileExists(atPath: current.logs.appendingPathComponent("engine.log").path))
        #expect(!fm.fileExists(atPath: current.support.appendingPathComponent("striple.sock").path))
        #expect(!fm.fileExists(atPath: LegacyMigration.folders(home: home).support.path))
        #expect(!fm.fileExists(atPath: LegacyMigration.folders(home: home).logs.path))

        // The second start finds the Spool folders and moves nothing.
        #expect(LegacyMigration.migrate(current: current, home: home) == LegacyMigration.Result())
    }

    @Test func onlyTheLogsMovingIsNotASettingsMove() throws {
        let fm = FileManager.default
        let home = try Self.stripleHome()
        defer { try? fm.removeItem(at: home) }
        let current = SpoolPaths.resolve(environment: [:], home: home)
        try fm.createDirectory(at: current.support, withIntermediateDirectories: true)

        let result = LegacyMigration.migrate(current: current, home: home)

        #expect(!result.movedSettings)
        #expect(result.lines == [
            "Striple is now Spool: moved \(LegacyMigration.folders(home: home).logs.path) to \(current.logs.path)",
            "Striple is now Spool: kept \(LegacyMigration.folders(home: home).support.path), because \(current.support.path) exists. "
                + "Move what you need by hand.",
        ])
        // Spool's own folder stays as it was, and the Striple settings stay where they are.
        #expect(!fm.fileExists(atPath: current.support.appendingPathComponent("config.json").path))
        #expect(fm.fileExists(atPath: LegacyMigration.folders(home: home).support.appendingPathComponent("config.json").path))
    }

    @Test func aFailedMoveIsReportedAndKeepsTheFiles() throws {
        let fm = FileManager.default
        let home = try Self.stripleHome()
        defer { try? fm.removeItem(at: home) }
        let from = LegacyMigration.folders(home: home).support
        // The parent of the target is a file, so the move cannot happen.
        let blocker = home.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let to = blocker.appendingPathComponent("Spool")

        let result = LegacyMigration.run([LegacyMigration.Move(from: from, to: to)], settings: to)

        #expect(!result.movedSettings)
        #expect(result.lines.count == 1)
        #expect(result.lines[0].hasPrefix("Striple is now Spool: could not move \(from.path) to \(to.path): "))
        #expect(fm.fileExists(atPath: from.appendingPathComponent("config.json").path))
    }

    // MARK: stopping a running Striple

    @Test func noStripleSendsNothing() {
        var sent: [pid_t] = []
        #expect(LegacyMigration.stop(pids: [], signal: { sent.append($0) }, isAlive: { _ in true }))
        #expect(sent.isEmpty)
    }

    // kill(-1) signals every process of the user, kill(0) the own process group.
    @Test func aPidThatIsNotAProcessGetsNoSignal() {
        var sent: [pid_t] = []
        #expect(LegacyMigration.stop(pids: [-1, 0], signal: { sent.append($0) }, isAlive: { _ in true }))
        #expect(sent.isEmpty)
        #expect(LegacyMigration.stop(pids: [-1, 12], signal: { sent.append($0) }, isAlive: { _ in false }))
        #expect(sent == [12])
    }

    @Test func everyStripleGetsSIGTERMAndTheWaitEndsWhenAllQuit() {
        var sent: [pid_t] = []
        var alive: Set<pid_t> = [10, 11]
        var sleeps = 0
        let ok = LegacyMigration.stop(pids: [10, 11], signal: { sent.append($0) }, isAlive: { alive.contains($0) },
                                      sleep: { _ in
                                          sleeps += 1
                                          if sleeps == 2 { alive.remove(10) }
                                          if sleeps == 3 { alive.remove(11) }
                                      })
        #expect(ok)
        #expect(sent == [10, 11])
        #expect(sleeps == 3)
    }

    @Test func aStripleThatDoesNotQuitStopsTheWaitAtTheTimeout() {
        var clock = Date(timeIntervalSince1970: 0)
        let ok = LegacyMigration.stop(pids: [10], timeout: 10, signal: { _ in }, isAlive: { _ in true },
                                      now: { clock }, sleep: { clock = clock.addingTimeInterval($0) })
        #expect(!ok)
        #expect(clock.timeIntervalSince1970 >= 10)
        #expect(clock.timeIntervalSince1970 < 10.2)
    }

    @Test func foldersLeftSeesEachStripleFolder() throws {
        let fm = FileManager.default
        let home = try Self.stripleHome()
        defer { try? fm.removeItem(at: home) }
        let current = SpoolPaths.resolve(environment: [:], home: home)
        #expect(LegacyMigration.foldersLeft(current: current, home: home))
        try fm.removeItem(at: striple(home).support)
        #expect(LegacyMigration.foldersLeft(current: current, home: home))
        let isolated = SpoolPaths.resolve(environment: ["SPOOL_HOME": home.path + "/e2e"], home: home)
        #expect(!LegacyMigration.foldersLeft(current: isolated, home: home))
        try fm.removeItem(at: striple(home).logs)
        #expect(!LegacyMigration.foldersLeft(current: current, home: home))
    }
}

/// The order of `LegacyMigration.takeOver`, with a fake system that records each call.
@Suite struct LegacyTakeOverTests {
    final class FakeSystem {
        var calls: [String] = []
        var running: [[(pid: pid_t, bundle: URL?)]]
        var installed: URL?
        var stops: [Bool]
        var foldersLeft: Bool
        let moved = LegacyMigration.Result(lines: ["Striple is now Spool: moved a to b"], movedSettings: true)

        init(running: [[(pid: pid_t, bundle: URL?)]], installed: URL? = nil, stops: [Bool] = [true, true],
             foldersLeft: Bool = true) {
            self.running = running
            self.installed = installed
            self.stops = stops
            self.foldersLeft = foldersLeft
        }

        var system: LegacyMigration.System {
            LegacyMigration.System(
                running: { self.calls.append("running"); return self.running.isEmpty ? [] : self.running.removeFirst() },
                installed: { self.installed },
                stop: { self.calls.append("stop \($0)"); return self.stops.isEmpty ? true : self.stops.removeFirst() },
                unregister: { self.calls.append("unregister \($0.path)"); return "unregistered \($0.path)" },
                foldersLeft: { self.foldersLeft },
                migrate: { self.calls.append("migrate"); return self.moved })
        }
    }

    let app = URL(fileURLWithPath: "/Applications/Striple.app")

    @Test func aTestRunDoesNothing() {
        let fake = FakeSystem(running: [[(pid: 10, bundle: app)]])
        #expect(LegacyMigration.takeOver(isolated: true, fake.system) == .done(LegacyMigration.Result()))
        #expect(fake.calls.isEmpty)
    }

    @Test func stripleQuitsThenItsLoginItemGoesOffThenARestartedStripleStopsThenTheFoldersMove() {
        let fake = FakeSystem(running: [[(pid: 10, bundle: app)], [(pid: 20, bundle: app)]])
        let outcome = LegacyMigration.takeOver(isolated: false, fake.system)
        #expect(fake.calls == ["running", "stop [10]", "unregister /Applications/Striple.app", "running", "stop [20]", "migrate"])
        #expect(outcome == .done(LegacyMigration.Result(lines: [
            "Striple is now Spool: stopped Striple (pid 10)",
            "unregistered /Applications/Striple.app",
            "Striple is now Spool: stopped Striple again (pid 20)",
            "Striple is now Spool: moved a to b",
        ], movedSettings: true)))
    }

    @Test func aStripleThatDoesNotQuitStopsEverything() {
        let fake = FakeSystem(running: [[(pid: 10, bundle: app)]], stops: [false])
        #expect(LegacyMigration.takeOver(isolated: false, fake.system) == .stripleStillRuns([10]))
        #expect(fake.calls == ["running", "stop [10]"])
    }

    @Test func aRestartedStripleThatDoesNotQuitStopsEverything() {
        let fake = FakeSystem(running: [[], [(pid: 20, bundle: app)]], installed: app, stops: [true, false])
        #expect(LegacyMigration.takeOver(isolated: false, fake.system) == .stripleStillRuns([20]))
        #expect(!fake.calls.contains("migrate"))
    }

    // Striple does not run, but its folders are there: the installed Striple's login item goes off.
    @Test func anInstalledStripleLosesItsLoginItemWhileAFolderIsLeft() {
        let fake = FakeSystem(running: [], installed: app, foldersLeft: true)
        _ = LegacyMigration.takeOver(isolated: false, fake.system)
        #expect(fake.calls == ["running", "stop []", "unregister /Applications/Striple.app", "running", "stop []", "migrate"])
    }

    // A normal start of Spool, after the move: no Striple runs.
    @Test func aNormalStartRunsNoStriple() {
        let fake = FakeSystem(running: [], installed: app, foldersLeft: false)
        #expect(LegacyMigration.takeOver(isolated: false, fake.system) == .done(fake.moved))
        #expect(fake.calls == ["running", "stop []", "migrate"])
    }
}
