import Foundation
import Testing
@testable import SpoolCore

/// `SPOOL_HOME` moves every file of a test run out of the user's folders (docs/E2E.md).
@Suite struct SpoolPathsTests {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test func withoutSpoolHomeTheUserFoldersAreUsed() {
        for env in [[:], ["SPOOL_HOME": ""], ["SPOOL_HOME": "  "]] {
            let f = SpoolPaths.resolve(environment: env, home: home)
            #expect(f.support.path == "/Users/someone/Library/Application Support/Spool")
            #expect(f.logs.path == "/Users/someone/Library/Logs/Spool")
            #expect(!f.isolated)
        }
    }

    @Test func spoolHomeHoldsSupportFilesAndLogs() {
        let f = SpoolPaths.resolve(environment: ["SPOOL_HOME": "/tmp/spool-e2e-abc/"], home: home)
        #expect(f.support.path == "/tmp/spool-e2e-abc")
        #expect(f.logs.path == "/tmp/spool-e2e-abc/Logs")
        #expect(f.isolated)
    }

    @Test func aTildeIsExpanded() {
        let f = SpoolPaths.resolve(environment: ["SPOOL_HOME": "~/e2e"], home: home)
        #expect(f.support.path == (NSString(string: "~/e2e").expandingTildeInPath as String))
        #expect(f.isolated)
    }

    @Test func theTestProcessUsesTheRealFolders() {
        // `swift test` does not set SPOOL_HOME; the file names stay the same in both modes.
        #expect(SpoolPaths.configFile.lastPathComponent == "config.json")
        #expect(SpoolPaths.socket.deletingLastPathComponent() == SpoolPaths.supportDirectory)
        #expect(SpoolPaths.logFile.deletingLastPathComponent() == SpoolPaths.logDirectory)
    }
}
