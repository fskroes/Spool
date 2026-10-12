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

    // MARK: Fakes on PATH, a temporary repository

    /// Like `call`, but in the folder `cwd`, with `bin` first on PATH and with the extra `env`.
    static func call(in cwd: URL, bin: URL? = nil, env: [String: String] = [:],
                     _ function: String, _ args: String...) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "set -u; source \"$0\"; \"$@\"", lib.path, function] + args
        p.currentDirectoryURL = cwd
        var e = ProcessInfo.processInfo.environment
        if let bin { e["PATH"] = bin.path + ":" + (e["PATH"] ?? "/usr/bin:/bin") }
        e.merge(env) { $1 }
        p.environment = e
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let er = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(output: String(decoding: o, as: UTF8.self).trimmingCharacters(in: .newlines),
                      error: String(decoding: er, as: UTF8.self), status: p.terminationStatus)
    }

    static func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes an executable /bin/sh script `name` into `bin`.
    static func tool(_ bin: URL, _ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A fake gh. FAKE_GH picks the answer; every call is logged to bin/gh.log.
    static func fakeGh() throws -> URL {
        let bin = try tempDir("gh")
        try tool(bin, "gh", """
        printf '%s\\n' "$*" >> '\(bin.path)/gh.log'
        case "$FAKE_GH" in
          notfound) echo "release not found" >&2; exit 1 ;;
          draft) echo true ;;
          published) echo false ;;
          network) echo "error connecting to api.github.com" >&2; exit 1 ;;
          notice) echo "A new release of gh is available: 2.102.0 -> 2.103.0" >&2; echo false ;;
          odd) echo maybe ;;
          norepo) echo "GraphQL: Could not resolve to a Repository with the name 'o/r'. (repository)" >&2; exit 1 ;;
          zero) echo 0 ;;
          one) echo 1 ;;
        esac
        """)
        return bin
    }

    // A feed that returns 404: only a missing repository or an empty release list lets the run go on.
    @Test func noPublishedReleaseOnlyWhenGhSaysSo() throws {
        let bin = try Self.fakeGh()
        defer { try? FileManager.default.removeItem(at: bin) }
        func ask(_ mode: String) throws -> Result {
            try Self.call(in: Self.root, bin: bin, env: ["FAKE_GH": mode], "striple_release_none_published", "o/r", "https://f/appcast.xml")
        }
        for mode in ["norepo", "zero"] {
            let r = try ask(mode)
            #expect(r.status == 0 && r.output.isEmpty, "\(mode): \(r)")
        }
        let one = try ask("one")
        #expect(one.status == 1)
        #expect(one.output == "o/r has published releases but no feed at https://f/appcast.xml. Fix the latest release first.")
        let net = try ask("network")
        #expect(net.status == 2)
        #expect(net.output == "cannot list the releases of o/r: error connecting to api.github.com")
        for mode in ["odd", "notice"] {
            let r = try ask(mode)
            #expect(r.status == 2, "\(mode)")
            #expect(r.output.hasPrefix("unexpected answer from gh release list --repo o/r: "), "\(mode): \(r.output)")
        }
        let log = try String(contentsOf: bin.appendingPathComponent("gh.log"), encoding: .utf8)
        #expect(log.hasPrefix("release list --repo o/r --exclude-drafts --limit 1 --json tagName --jq length\n"))
    }

    @Test func noReleaseAndNoRepositoryAreBothFree() throws {
        let bin = try Self.fakeGh()
        defer { try? FileManager.default.removeItem(at: bin) }
        let r = try Self.call(in: Self.root, bin: bin, env: ["FAKE_GH": "notfound"], "striple_release_existing", "v1.2.3", "o/r")
        #expect(r.status == 0 && r.output.isEmpty, "\(r)")
        let log = try String(contentsOf: bin.appendingPathComponent("gh.log"), encoding: .utf8)
        #expect(log == "release view v1.2.3 --repo o/r --json isDraft --jq .isDraft\n")
    }

    @Test func aDraftReleaseStopsTheRunWithTheDeleteCommand() throws {
        let bin = try Self.fakeGh()
        defer { try? FileManager.default.removeItem(at: bin) }
        let r = try Self.call(in: Self.root, bin: bin, env: ["FAKE_GH": "draft"], "striple_release_existing", "v1.2.3", "o/r")
        #expect(r.status == 1)
        #expect(r.output.contains("a draft release v1.2.3 exists in o/r"))
        #expect(r.output.contains("gh release delete v1.2.3 --repo o/r --yes"))
    }

    // Users already download a published release: never advise to delete it.
    @Test func aPublishedReleaseStopsTheRunAndIsNeverDeleted() throws {
        let bin = try Self.fakeGh()
        defer { try? FileManager.default.removeItem(at: bin) }
        for mode in ["published", "notice"] {
            let r = try Self.call(in: Self.root, bin: bin, env: ["FAKE_GH": mode], "striple_release_existing", "v1.2.3", "o/r")
            #expect(r.status == 1, "\(mode)")
            #expect(r.output.contains("v1.2.3 is published in o/r. Do not delete it."), "\(mode): \(r.output)")
            #expect(r.output.contains("make publish-finish"))
            #expect(!r.output.contains("gh release delete"))
        }
    }

    // "Cannot tell" is never "free": the run must stop, not build and publish over a release.
    @Test func aReleaseCheckThatCannotTellStopsTheRun() throws {
        let bin = try Self.fakeGh()
        defer { try? FileManager.default.removeItem(at: bin) }
        let net = try Self.call(in: Self.root, bin: bin, env: ["FAKE_GH": "network"], "striple_release_existing", "v1.2.3", "o/r")
        #expect(net.status == 2)
        #expect(net.output.contains("cannot check for the release v1.2.3 in o/r: error connecting to api.github.com"))
        let odd = try Self.call(in: Self.root, bin: bin, env: ["FAKE_GH": "odd"], "striple_release_existing", "v1.2.3", "o/r")
        #expect(odd.status == 2)
        #expect(odd.output.contains("unexpected answer from gh release view v1.2.3: maybe"))
    }

    static let gitEnv = ["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
                         "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
                         "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]

    /// A repository with two commits; returns the folder and both commit IDs.
    static func repo() throws -> (dir: URL, first: String, second: String) {
        let dir = try tempDir("repo")
        func sh(_ cmd: String) throws -> String {
            try call(in: dir, env: gitEnv, "eval", cmd).output
        }
        _ = try sh("git init -q && echo a > f && git add f && git commit -qm one")
        let first = try sh("git rev-parse HEAD")
        _ = try sh("echo b > f && git commit -qam two")
        let second = try sh("git rev-parse HEAD")
        return (dir, first, second)
    }

    @Test func headCheckFindsAMovedHeadAndAChangedTree() throws {
        let (dir, first, second) = try Self.repo()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try Self.call(in: dir, env: Self.gitEnv, "striple_release_head_is", second).status == 0)
        #expect(try Self.call(in: dir, env: Self.gitEnv, "striple_release_head_is", second, "clean").status == 0)

        let moved = try Self.call(in: dir, env: Self.gitEnv, "striple_release_head_is", first)
        #expect(moved.status == 1)
        #expect(moved.error.contains("HEAD moved from \(first) to \(second)"))

        try Data("c".utf8).write(to: dir.appendingPathComponent("f"))
        #expect(try Self.call(in: dir, env: Self.gitEnv, "striple_release_head_is", second).status == 0)
        let dirty = try Self.call(in: dir, env: Self.gitEnv, "striple_release_head_is", second, "clean")
        #expect(dirty.status == 1)
        #expect(dirty.error.contains("the working tree changed"))
    }

    // The tag names the commit the release was built from, also when HEAD is somewhere else.
    @Test func theTagGoesOnTheBuiltCommitNotOnHead() throws {
        let (dir, first, _) = try Self.repo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try Self.call(in: dir, env: Self.gitEnv, "striple_release_tag", "v1.0.0", first, "Striple 1.0.0")
        #expect(r.status == 0, "\(r.error)")
        #expect(try Self.call(in: dir, env: Self.gitEnv, "git", "rev-parse", "v1.0.0^{commit}").output == first)
        #expect(try Self.call(in: dir, env: Self.gitEnv, "git", "cat-file", "-t", "v1.0.0").output == "tag")
        #expect(try Self.call(in: dir, env: Self.gitEnv, "git", "tag", "-l", "--format=%(contents:subject)", "v1.0.0").output == "Striple 1.0.0")
        // An existing tag is not moved.
        #expect(try Self.call(in: dir, env: Self.gitEnv, "striple_release_tag", "v1.0.0", "HEAD", "x").status != 0)
        #expect(try Self.call(in: dir, env: Self.gitEnv, "git", "rev-parse", "v1.0.0^{commit}").output == first)
    }

    @Test func privateCheckVerdictIsCleanLeakOrCannotCheck() throws {
        let dir = try Self.tempDir("private")
        let locked = dir.appendingPathComponent("locked")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try Data("/Users/someone/x".utf8).write(to: dir.appendingPathComponent("Info.plist"))
        let clean = try Self.call("striple_release_private_check", dir.path, "the app", "/Users/nobody", "")
        #expect(clean.status == 0 && clean.output.isEmpty)

        let leak = try Self.call("striple_release_private_check", dir.path, "the app", "/Users/someone")
        #expect(leak.status == 1)
        #expect(leak.output.contains("files in the app contain your home path"))
        #expect(leak.output.hasSuffix("/Info.plist"))

        try Data("x".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let cannot = try Self.call("striple_release_private_check", dir.path, "the app", "/Users/nobody")
        #expect(cannot.status == 1)
        #expect(cannot.output.contains("cannot check the app"))
        let missing = try Self.call("striple_release_private_check", dir.appendingPathComponent("nope").path, "the DMG", "x")
        #expect(missing.status == 1)
        #expect(missing.output.contains("cannot check the DMG"))
    }

    // A DMG that does not detach keeps the folder: rm -rf into a mounted volume deletes its files.
    @Test func cleanupKeepsTheFolderWhenTheDMGDoesNotDetach() throws {
        let dir = try Self.tempDir("cleanup")
        let bin = try Self.tempDir("bin")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: bin)
        }
        guard let c = realpath(dir.path, nil) else { Issue.record("realpath"); return }
        let real = String(cString: c)
        free(c)
        try Self.tool(bin, "mount", "echo '/dev/disk9s1 on \(real)/dmg (hfs, local, nodev, nosuid, read-only)'")
        try Self.tool(bin, "hdiutil", "printf '%s\\n' \"$*\" > '\(bin.path)/hdiutil.log'; exit 1")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("dmg"), withIntermediateDirectories: true)

        let r = try Self.call(in: Self.root, bin: bin, "striple_release_cleanup", dir.path)
        #expect(r.status == 1)
        #expect(r.error.contains("cannot detach \(dir.path)/dmg"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("dmg").path))
        let log = try String(contentsOf: bin.appendingPathComponent("hdiutil.log"), encoding: .utf8)
        #expect(log == "detach -force \(dir.path)/dmg -quiet\n")
    }

    // A real run of release.sh needs a build, keys and GitHub. This test pins the order of its checks
    // in the text: a check after the step it guards does not guard it.
    @Test func releaseScriptRunsItsChecksBeforeTheStepsTheyGuard() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent("scripts/release.sh"), encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        func line(_ needle: String, after start: Int = 0) -> Int? {
            lines.indices.first { $0 >= start && lines[$0].contains(needle) }
        }
        let commit = try #require(line("COMMIT=$(git rev-parse HEAD)"))
        let build = try #require(line("BUILD=$(git rev-list --count HEAD)"))
        #expect(commit == build + 2, "COMMIT is read with BUILD, before anything can move HEAD")

        let runBuild = try #require(line("\"$ROOT/scripts/build-app.sh\""))
        let existing = try #require(line("EXISTING=$(striple_release_existing \"$TAG\" \"$REPO\") || die"))
        #expect(existing < runBuild, "a draft or published release stops the run before the build")
        #expect(lines[existing - 1].contains("if [[ $DRY -eq 0 ]]; then"))
        let upload = try #require(line("gh release create \"$TAG\""))
        let again = try #require(line("EXISTING=$(striple_release_existing \"$TAG\" \"$REPO\") || die", after: existing + 1))
        #expect(again < upload)

        let head = try #require(line("striple_release_head_is \"$COMMIT\" ||", after: runBuild))
        let clean = try #require(line("striple_release_head_is \"$COMMIT\" clean ||", after: runBuild))
        let wipe = try #require(line("rm -rf \"$OUT\""))
        #expect(head < wipe && clean < wipe, "the files of a run are kept until the new build is known good")
        #expect(line("rm -rf \"$OUT\"", after: wipe + 1) == nil)

        #expect(line("printf '%s\\n' \"$COMMIT\" > \"$OUT/commit.txt\"") != nil)
        #expect(line("striple_release_tag \"$TAG\" \"$COMMIT\"") != nil)
        #expect(line("git tag") == nil, "only striple_release_tag makes the tag")
        #expect(line("git rev-parse HEAD", after: commit + 1) == nil, "HEAD is read once")
        #expect(line("OUT=\"$ROOT/dist/release/dry-run/$VERSION\"") != nil, "a dry run does not replace a real run")
    }

    @Test func downloadPrefixIsPerTag() throws {
        #expect(try Self.call("striple_download_prefix", "o/r", "1.2.3").output == "https://github.com/o/r/releases/download/v1.2.3/")
    }
}
