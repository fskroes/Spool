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

    @Test func downloadPrefixIsPerTag() throws {
        #expect(try Self.call("striple_download_prefix", "o/r", "1.2.3").output == "https://github.com/o/r/releases/download/v1.2.3/")
    }
}
