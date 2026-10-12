import Foundation
import Testing

/// Tests for scripts/release-lib.sh (used by release.sh and build-app.sh). Each test calls one shell
/// function. No network, no keychain, no build.
@Suite struct ReleaseScriptTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let lib = root.appendingPathComponent("scripts/release-lib.sh")

    struct Result { var output: String; var error: String; var status: Int32 }

    /// Runs `<function> <args...>` after it sources release-lib.sh.
    static func call(_ function: String, _ args: String...) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "set -u; source \"$0\"; \"$@\"", lib.path, function] + args
        p.currentDirectoryURL = root
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(output: String(decoding: o, as: UTF8.self).trimmingCharacters(in: .newlines),
                      error: String(decoding: e, as: UTF8.self), status: p.terminationStatus)
    }

    static func temp(_ name: String, _ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: updates.env

    @Test func updatesValueReadsKeysAndIgnoresCommentsQuotesAndLongerNames() throws {
        let f = try Self.temp("updates.env", """
        # STRIPLE_FEED_URL=https://comment.example/appcast.xml
        STRIPLE_FEED_URL_OLD=https://old.example/appcast.xml
        STRIPLE_FEED_URL="https://feed.example/appcast.xml"
        STRIPLE_ED_PUBLIC_KEY=abc+/=  
        STRIPLE_ED_KEY_ACCOUNT='com.example'
        """)
        #expect(try Self.call("striple_updates_value", f.path, "STRIPLE_FEED_URL").output == "https://feed.example/appcast.xml")
        #expect(try Self.call("striple_updates_value", f.path, "STRIPLE_ED_PUBLIC_KEY").output == "abc+/=")
        #expect(try Self.call("striple_updates_value", f.path, "STRIPLE_ED_KEY_ACCOUNT").output == "com.example")
        let missing = try Self.call("striple_updates_value", f.path, "STRIPLE_RELEASES_REPO")
        #expect(missing.status == 0 && missing.output.isEmpty)
        let noFile = try Self.call("striple_updates_value", "/nonexistent/updates.env", "STRIPLE_FEED_URL")
        #expect(noFile.status == 0 && noFile.output.isEmpty)
    }

    /// Every build reads Packaging/updates.env, so a typo there ships a dead update feed.
    @Test func theCommittedUpdateSettingsAreConsistent() throws {
        let env = Self.root.appendingPathComponent("Packaging/updates.env").path
        let repo = try Self.call("striple_updates_value", env, "STRIPLE_RELEASES_REPO").output
        let feed = try Self.call("striple_updates_value", env, "STRIPLE_FEED_URL").output
        let key = try Self.call("striple_updates_value", env, "STRIPLE_ED_PUBLIC_KEY").output
        let account = try Self.call("striple_updates_value", env, "STRIPLE_ED_KEY_ACCOUNT").output
        let cert = try Self.call("striple_updates_value", env, "STRIPLE_SIGNING_CERT_SHA1").output
        #expect(try Self.call("striple_sha1_equal", cert, cert).status == 0, "a 40 digit SHA-1, got '\(cert)'")
        #expect(repo.split(separator: "/").count == 2)
        #expect(feed == (try Self.call("striple_feed_url_for_repo", repo).output))
        #expect(feed.hasPrefix("https://"))
        #expect(Data(base64Encoded: key)?.count == 32, "an Ed25519 public key is 32 bytes")
        #expect(!account.isEmpty)
    }

    // MARK: versions

    @Test(arguments: [
        ("0.1.1", "0.1.0", Int32(0)), ("0.10.0", "0.9.9", 0), ("1.0.0", "0.99.99", 0), ("2.0.0", "1.10.10", 0),
        ("0.1.0", "0.1.0", 1), ("0.1.0", "0.1.1", 1), ("0.9.9", "0.10.0", 1),
        ("1.2", "1.1.0", 2), ("01.2.3", "1.0.0", 2), ("1.2.3-beta", "1.0.0", 2), ("1.0.0", "", 2),
    ])
    func versionComparison(_ a: String, _ b: String, _ status: Int32) throws {
        #expect(try Self.call("striple_version_gt", a, b).status == status)
    }

    /// The current VERSION must have release notes; release.sh refuses to publish without them.
    @Test func theCurrentVersionHasAChangelogSection() throws {
        let version = try String(contentsOf: Self.root.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try Self.call("striple_version_valid", version).status == 0)
        let notes = try Self.call("striple_changelog_section", Self.root.appendingPathComponent("CHANGELOG.md").path, version)
        #expect(notes.status == 0)
        #expect(!notes.output.isEmpty)
    }

    // MARK: changelog

    @Test func changelogSectionTakesOnlyItsOwnTextWithoutEdgeBlankLines() throws {
        let f = try Self.temp("CHANGELOG.md", """
        # Changelog

        ## 0.1.01

        Not this one.

        ## 0.1.1 (2026-10-12)


        - Fix A.

        - Fix B.


        ## 0.1.0

        - First.

        ## 0.0.9

        """)
        #expect(try Self.call("striple_changelog_section", f.path, "0.1.1").output == "- Fix A.\n\n- Fix B.")
        #expect(try Self.call("striple_changelog_section", f.path, "0.1.0").output == "- First.")
        #expect(try Self.call("striple_changelog_section", f.path, "0.1.01").output == "Not this one.")
        #expect(try Self.call("striple_changelog_section", f.path, "0.0.9").status == 1, "an empty section")
        #expect(try Self.call("striple_changelog_section", f.path, "0.2.0").status == 1, "no section")
        #expect(try Self.call("striple_changelog_section", "/nonexistent", "0.1.0").status == 1)
    }

    // MARK: appcast

    static let url = "https://github.com/o/r/releases/download/v0.1.0/Striple-0.1.0.zip"

    static func appcast(items: [(short: String, build: String, url: String, length: String, signature: String)]) -> String {
        let body = items.map { i in
            """
            <item><title>\(i.short)</title>
              <sparkle:version>\(i.build)</sparkle:version>
              <sparkle:shortVersionString>\(i.short)</sparkle:shortVersionString>
              <enclosure url="\(i.url)" length="\(i.length)" type="application/octet-stream"\(i.signature.isEmpty ? "" : " sparkle:edSignature=\"\(i.signature)\"")/>
            </item>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" standalone="yes"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>Striple</title>
        \(body)
        </channel></rss>
        """
    }

    @Test func appcastCheckAcceptsTheExpectedItemAndPrintsItsSignature() throws {
        let f = try Self.temp("appcast.xml", Self.appcast(items: [("0.1.0", "36", Self.url, "4257428", "c2ln")]))
        let r = try Self.call("striple_appcast_check", f.path, "0.1.0", "36", Self.url, "4257428")
        #expect(r.status == 0)
        #expect(r.output == "c2ln")
    }

    @Test(arguments: [
        ("0.1.1", "36", url, "4257428", "c2ln", "shortVersionString"),
        ("0.1.0", "35", url, "4257428", "c2ln", "version (build)"),
        ("0.1.0", "36", "https://example.com/Striple-0.1.0.zip", "4257428", "c2ln", "enclosure url"),
        ("0.1.0", "36", url, "1", "c2ln", "enclosure length"),
        ("0.1.0", "36", url, "4257428", "", "no EdDSA signature"),
    ])
    func appcastCheckRejectsAWrongValue(_ short: String, _ build: String, _ url: String, _ length: String,
                                        _ signature: String, _ message: String) throws {
        let f = try Self.temp("appcast.xml", Self.appcast(items: [(short, build, url, length, signature)]))
        let r = try Self.call("striple_appcast_check", f.path, "0.1.0", "36", Self.url, "4257428")
        #expect(r.status == 1)
        #expect(r.error.contains(message), "\(r.error)")
    }

    @Test func appcastCheckRejectsMoreThanOneItemAndBadXML() throws {
        let two = try Self.temp("appcast.xml", Self.appcast(items: [
            ("0.1.0", "36", Self.url, "4257428", "c2ln"), ("0.0.9", "30", Self.url, "1", "c2ln"),
        ]))
        let r = try Self.call("striple_appcast_check", two.path, "0.1.0", "36", Self.url, "4257428")
        #expect(r.status == 1 && r.error.contains("expected 1 item, found 2"))
        let bad = try Self.temp("appcast.xml", "<rss><channel>")
        #expect(try Self.call("striple_appcast_check", bad.path, "0.1.0", "36", Self.url, "4257428").status == 1)
    }

    @Test func appcastLatestPicksTheHighestBuild() throws {
        let f = try Self.temp("appcast.xml", Self.appcast(items: [
            ("0.1.0", "36", Self.url, "1", "c2ln"), ("0.2.0", "52", Self.url, "1", "c2ln"), ("0.1.5", "40", Self.url, "1", "c2ln"),
        ]))
        #expect(try Self.call("striple_appcast_latest", f.path).output == "0.2.0 52")
        let empty = try Self.temp("appcast.xml", Self.appcast(items: []))
        #expect(try Self.call("striple_appcast_latest", empty.path).status == 1)
    }

    // MARK: signature

    @Test func designatedRequirementMustPinTheBundleAndTheLocalCertificate() throws {
        let hash = "B608FA4F3D9A1FC14CDBAB47421A660E429053DC"
        let local = "designated => identifier \"com.fskroes.Striple\" and certificate leaf = H\"b608fa4f3d9a1fc14cdbab47421a660e429053dc\""
        #expect(try Self.call("striple_dr_is_local", local, "com.fskroes.Striple", hash).status == 0)
        let adHoc = "designated => cdhash H\"2d50fa83aa\""
        #expect(try Self.call("striple_dr_is_local", adHoc, "com.fskroes.Striple", hash).status == 1)
        #expect(try Self.call("striple_dr_is_local", local, "com.fskroes.Other", hash).status == 1)
        #expect(try Self.call("striple_dr_is_local", local, "com.fskroes.Striple", "0000").status == 1)
        #expect(try Self.call("striple_dr_is_local", local, "com.fskroes.Striple", "").status == 1)
    }

    @Test func sha1ComparisonIgnoresCaseColonsAndSpaces() throws {
        let hash = "B608FA4F3D9A1FC14CDBAB47421A660E429053DC"
        #expect(try Self.call("striple_sha1_equal", hash, hash.lowercased()).status == 0)
        #expect(try Self.call("striple_sha1_equal", hash, "B6:08:FA:4F:3D:9A:1F:C1:4C:DB:AB:47:42:1A:66:0E:42:90:53:DC").status == 0)
        #expect(try Self.call("striple_sha1_equal", hash, "C" + hash.dropFirst()).status == 1)
        #expect(try Self.call("striple_sha1_equal", "", "").status == 1)
        #expect(try Self.call("striple_sha1_equal", "ABCD", "ABCD").status == 1)
    }

    @Test func appcastLatestURLIsTheEnclosureOfTheHighestBuild() throws {
        let f = try Self.temp("appcast.xml", Self.appcast(items: [
            ("0.1.0", "36", "https://x/a.zip", "1", "c2ln"), ("0.2.0", "52", "https://x/b.zip", "1", "c2ln"),
        ]))
        #expect(try Self.call("striple_appcast_latest_url", f.path).output == "https://x/b.zip")
        let empty = try Self.temp("appcast.xml", Self.appcast(items: []))
        #expect(try Self.call("striple_appcast_latest_url", empty.path).status == 1)
    }

    @Test func privateStringsAreFoundInAnyFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-private-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("Striple.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([0, 1, 2] + Array("/Users/someone/dev/x.o".utf8) + [0]).write(to: nested.appendingPathComponent("Striple"))
        try Data("clean".utf8).write(to: dir.appendingPathComponent("README"))
        let hit = try Self.call("striple_private_strings", dir.path, "/Users/someone", "")
        #expect(hit.status == 1)
        #expect(hit.output.hasSuffix("Striple.app/Contents/MacOS/Striple"))
        #expect(try Self.call("striple_private_strings", dir.path, "nobody", "").status == 0)
        #expect(try Self.call("striple_private_strings", dir.path, "", "").status == 0)
    }

    // A failed check must never read as "clean": the release would publish without the check.
    @Test func privateStringsFailClosedWhenAFileCannotBeRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-private-\(UUID().uuidString)")
        let locked = dir.appendingPathComponent("locked")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("clean".utf8).write(to: dir.appendingPathComponent("README"))
        try Data("/Users/someone".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let r = try Self.call("striple_private_strings", dir.path, "/Users/someone")
        #expect(r.status == 2)
        #expect(r.error.contains("Permission denied"), "grep must tell why: \(r.error)")
        let missing = try Self.call("striple_private_strings", dir.appendingPathComponent("nope").path, "x")
        #expect(missing.status == 2)
        #expect(missing.error.contains("no such folder"))
    }

    @Test func finishNeedsTheCommitTheReleaseWasBuiltFrom() throws {
        let head = try Self.git("rev-parse", "HEAD")
        let dir = try Self.temp("commit.txt", head + "\n").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try Self.call("striple_release_commit_check", dir.path).status == 0)

        let other = String(repeating: "0", count: 40)
        try Data((other + "\n").utf8).write(to: dir.appendingPathComponent("commit.txt"))
        let wrong = try Self.call("striple_release_commit_check", dir.path)
        #expect(wrong.status == 1)
        #expect(wrong.error.contains("built from commit \(other), HEAD is \(head)"))

        try FileManager.default.removeItem(at: dir.appendingPathComponent("commit.txt"))
        let none = try Self.call("striple_release_commit_check", dir.path)
        #expect(none.status == 1)
        #expect(none.error.contains("commit.txt is missing"))
    }

    // release.sh mounts Striple.dmg at $TMP/dmg. A failure while it is mounted must not leave it mounted,
    // and rm -rf must not run into the mounted volume.
    @Test func cleanupDetachesAMountedDMGAndDeletesTheFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-cleanup-\(UUID().uuidString)")
        let mountPoint = dir.appendingPathComponent("dmg")
        defer {
            _ = try? Self.run("/usr/bin/hdiutil", "detach", "-force", mountPoint.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = dir.appendingPathComponent("t.dmg")
        #expect(try Self.run("/usr/bin/hdiutil", "create", "-quiet", "-size", "1m", "-fs", "HFS+",
                             "-volname", "StripleCleanupTest", image.path) == 0)
        #expect(try Self.run("/usr/bin/hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-noautoopen",
                             "-mountpoint", mountPoint.path, image.path) == 0)
        #expect(try Self.mounted(mountPoint))

        let r = try Self.call("striple_release_cleanup", dir.path)
        #expect(r.status == 0, "\(r.error)")
        #expect(try !Self.mounted(mountPoint))
        #expect(!FileManager.default.fileExists(atPath: dir.path))

        // No DMG: the folder is deleted. An empty or missing path does nothing.
        let plain = try Self.temp("x", "x").deletingLastPathComponent()
        #expect(try Self.call("striple_release_cleanup", plain.path).status == 0)
        #expect(!FileManager.default.fileExists(atPath: plain.path))
        #expect(try Self.call("striple_release_cleanup", "").status == 0)
    }

    static func run(_ tool: String, _ args: String...) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func git(_ args: String...) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = root
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func mounted(_ mountPoint: URL) throws -> Bool {
        // Not resolvingSymlinksInPath: it drops "/private", and mount lists /private/var/...
        guard let c = realpath(mountPoint.path, nil) else { return false }
        defer { free(c) }
        let real = String(cString: c)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains(" on \(real) (")
    }

    @Test func downloadPrefixIsPerTag() throws {
        #expect(try Self.call("striple_download_prefix", "o/r", "1.2.3").output == "https://github.com/o/r/releases/download/v1.2.3/")
    }
}
