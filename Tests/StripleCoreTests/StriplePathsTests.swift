import Foundation
import Testing
@testable import StripleCore

/// `STRIPLE_HOME` moves every file of a test run out of the user's folders (docs/E2E.md).
@Suite struct StriplePathsTests {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test func withoutStripleHomeTheUserFoldersAreUsed() {
        for env in [[:], ["STRIPLE_HOME": ""], ["STRIPLE_HOME": "  "]] {
            let f = StriplePaths.resolve(environment: env, home: home)
            #expect(f.support.path == "/Users/someone/Library/Application Support/Striple")
            #expect(f.logs.path == "/Users/someone/Library/Logs/Striple")
            #expect(!f.isolated)
        }
    }

    @Test func stripleHomeHoldsSupportFilesAndLogs() {
        let f = StriplePaths.resolve(environment: ["STRIPLE_HOME": "/tmp/striple-e2e-abc/"], home: home)
        #expect(f.support.path == "/tmp/striple-e2e-abc")
        #expect(f.logs.path == "/tmp/striple-e2e-abc/Logs")
        #expect(f.isolated)
    }

    @Test func aTildeIsExpanded() {
        let f = StriplePaths.resolve(environment: ["STRIPLE_HOME": "~/e2e"], home: home)
        #expect(f.support.path == (NSString(string: "~/e2e").expandingTildeInPath as String))
        #expect(f.isolated)
    }

    @Test func theTestProcessUsesTheRealFolders() {
        // `swift test` does not set STRIPLE_HOME; the file names stay the same in both modes.
        #expect(StriplePaths.configFile.lastPathComponent == "config.json")
        #expect(StriplePaths.socket.deletingLastPathComponent() == StriplePaths.supportDirectory)
        #expect(StriplePaths.logFile.deletingLastPathComponent() == StriplePaths.logDirectory)
    }
}
