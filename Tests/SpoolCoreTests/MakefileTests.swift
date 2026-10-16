import Foundation
import Testing

/// `make clean` runs on a copy of the Makefile in a temporary folder, so the real dist/ and .build/ do not change.
@Suite struct MakefileTests {
    static let makefile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Makefile")

    static func clean(in dir: URL) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        p.arguments = ["-f", makefile.path, "clean"]
        p.currentDirectoryURL = dir
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // On a managed Mac the endpoint security tool can report the keychain-like calls of SigningScriptTests.
    @Test func makeTestSkipsTheSigningTestsAndMakeTestSigningRunsOnlyThem() throws {
        func plan(_ target: String) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/make")
            p.arguments = ["-n", "-f", Self.makefile.path, target]
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)
            return String(decoding: data, as: UTF8.self)
        }
        let test = try plan("test")
        #expect(test.hasPrefix("swift test ") && test.contains("--skip SigningScriptTests"), "\(test)")
        let signing = try plan("test-signing")
        #expect(signing.hasPrefix("SPOOL_SIGNING_TESTS=1 swift test ") && signing.contains("--filter SigningScriptTests")
                && !signing.contains("--skip"), "\(signing)")
        #expect(!test.contains("SPOOL_SIGNING_TESTS"), "\(test)")
    }

    // The E2E app has the public test key, whatever Packaging/updates.env says, and not a key from the caller's
    // environment. `scripts/verify e2e` runs `make e2e`, so it gets the same build.
    @Test func makeE2EBuildsTheAppWithTheTestLicenseKey() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        p.arguments = ["-n", "-f", Self.makefile.path, "e2e"]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["SPOOL_LICENSE_PUBLIC_KEY"] = "from-the-caller"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let plan = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(plan)")
        let lines = plan.components(separatedBy: "\n")
        #expect(lines.first == "SPOOL_LICENSE_PUBLIC_KEY='\(LicenseKeyTests.vectors.publicKeyA)' ./scripts/build-app.sh", "\(plan)")
        #expect(!plan.contains("from-the-caller"))
        #expect(lines.contains { $0.contains("spool-e2e\" --app dist/Spool.app") })
    }

    // `make publish-finish` needs dist/release/<version>/ after a run that stopped after the publish.
    @Test func cleanKeepsTheFilesOfAReleaseRun() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spool-make-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let kept = ["dist/release/1.2.0/commit.txt", "dist/release/1.2.0/SHA256SUMS.txt", "dist/release/0.9.0/appcast.xml"]
        let deleted = [".build/debug/spool", "dist/Spool.app/Contents/Info.plist", "dist/Spool-1.2.0.dmg",
                       "dist/dmg-stage/Spool.app/x", "dist/release/dry-run/1.2.0/commit.txt", "dist/other.txt"]
        for path in kept + deleted {
            let file = dir.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }
        let r = try Self.clean(in: dir)
        #expect(r.status == 0, "\(r.output)")
        for path in kept { #expect(fm.fileExists(atPath: dir.appendingPathComponent(path).path), "\(path) was deleted") }
        for path in deleted { #expect(!fm.fileExists(atPath: dir.appendingPathComponent(path).path), "\(path) is still there") }
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent(".build").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("dist/Spool.app").path))

        // A second clean, and a clean with no dist/ at all, also succeed.
        #expect(try Self.clean(in: dir).status == 0)
        try fm.removeItem(at: dir.appendingPathComponent("dist"))
        #expect(try Self.clean(in: dir).status == 0)
    }
}
