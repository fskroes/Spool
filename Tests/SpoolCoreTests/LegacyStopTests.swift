import Foundation
import Testing
@testable import SpoolCore

/// `LegacyMigration.stop` with a real process. Apart from LegacyMigrationTests, so those stay in the quiet lane.
@Suite struct LegacyStopTests {
    // The real signal and check, on a child process that ends at SIGTERM.
    @Test func aRealProcessStops() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        let pid = p.processIdentifier
        #expect(LegacyMigration.isAlive(pid))
        // The child stays a zombie until it is reaped; waitUntilExit reaps it while `stop` waits.
        let reaper = Thread { p.waitUntilExit() }
        reaper.start()
        #expect(LegacyMigration.stop(pids: [pid], timeout: 5))
        #expect(!LegacyMigration.isAlive(pid))
    }
}
