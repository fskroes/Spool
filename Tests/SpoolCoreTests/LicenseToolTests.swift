import Foundation
import Testing
@testable import SpoolCore

/// `spool-license` (Sources/spool-license, logic in LicenseTool). Every test works in a temporary folder and
/// gives each path as an argument: no test touches ~/.config/spool.
@Suite struct LicenseToolTests {
    /// The test key pair of docs/license-test-vectors.json.
    static var seedA: Data { Data(base64Encoded: LicenseKeyTests.vectors.seedA)! }
    static var publicA: String { LicenseKeyTests.vectors.publicKeyA }

    final class Folder {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("spool-license-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        func path(_ name: String) -> String { url.appendingPathComponent(name).path }
        /// Writes the test seed A as a key file, mode 600.
        func keyFile(_ name: String = "signing.key", seed: Data = LicenseToolTests.seedA) throws -> String {
            let file = url.appendingPathComponent(name)
            try Data((seed.base64EncodedString() + "\n").utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file.path
        }
        var environment: LicenseTool.Environment {
            LicenseTool.Environment(
                home: url.appendingPathComponent("home"), currentDirectory: url,
                now: { Date(timeIntervalSince1970: 1_792_150_000) },  // 2026-10-16 11:26 UTC
                randomBytes: { count in Data((0..<count).map { UInt8(truncatingIfNeeded: 0xA0 + $0) }) })
        }
        func run(_ args: String...) -> LicenseTool.Output { LicenseTool.run(args, environment: environment) }
    }

    // MARK: keygen

    @Test func keygenWritesTheSeedWithMode600AndPrintsThePublicKey() throws {
        let f = try Folder()
        let path = f.path("new/folder/signing.key")
        let r = f.run("keygen", "--out", path)
        #expect(r.code == 0, "\(r.stderr)")
        // The injected bytes 0xA0, 0xA1 ... are the seed.
        let seed = Data((0..<32).map { UInt8(0xA0 + $0) })
        let publicKey = try LicenseKey.publicKey(seed: seed).base64EncodedString()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == seed.base64EncodedString() + "\n")
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: f.path("new/folder"))[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
        #expect(r.stdout.contains("SPOOL_LICENSE_PUBLIC_KEY=\(publicKey)\n"))
        #expect(r.stdout.contains(path))
        #expect(r.stdout.contains("Packaging/updates.env"))
        #expect(!r.stdout.contains(seed.base64EncodedString()), "keygen must not print the seed")
        #expect(!r.stderr.contains(seed.base64EncodedString()))
    }

    @Test func keygenRefusesAnExistingFileAndKeepsIt() throws {
        let f = try Folder()
        let path = try f.keyFile()
        let before = try String(contentsOfFile: path, encoding: .utf8)
        let r = f.run("keygen", "--out", path)
        #expect(r.code == 1)
        #expect(r.stdout.isEmpty)
        #expect(r.stderr.contains("exists"))
        #expect(r.stderr.contains("every sold license key invalid"))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == before)
    }

    @Test func keygenRefusesASymlinkToo() throws {
        let f = try Folder()
        let target = f.path("elsewhere.key")
        try FileManager.default.createSymbolicLink(atPath: f.path("link.key"), withDestinationPath: target)
        let r = f.run("keygen", "--out", f.path("link.key"))
        #expect(r.code == 1)
        #expect(!FileManager.default.fileExists(atPath: target), "O_EXCL must not follow a symlink")
    }

    @Test func keygenWithTheSystemGeneratorMakesADifferentKeyEachTime() throws {
        let f = try Folder()
        var env = LicenseTool.Environment(home: f.url.appendingPathComponent("home"), currentDirectory: f.url)
        let a = LicenseTool.run(["keygen", "--out", f.path("a.key")], environment: env)
        env = LicenseTool.Environment(home: f.url.appendingPathComponent("home"), currentDirectory: f.url)
        let b = LicenseTool.run(["keygen", "--out", f.path("b.key")], environment: env)
        #expect(a.code == 0 && b.code == 0)
        #expect(try String(contentsOfFile: f.path("a.key"), encoding: .utf8) != String(contentsOfFile: f.path("b.key"), encoding: .utf8))
    }

    @Test func theDefaultKeyPathIsInTheHomeFolder() throws {
        let f = try Folder()
        let r = f.run("keygen")
        #expect(r.code == 0, "\(r.stderr)")
        #expect(FileManager.default.fileExists(atPath: f.path("home/.config/spool/license-signing.key")))
        #expect(LicenseTool.defaultKeyURL(home: URL(fileURLWithPath: "/h")).path == "/h/.config/spool/license-signing.key")
    }

    // MARK: env-line

    @Test func envLinePrintsTheSeed() throws {
        let f = try Folder()
        let r = f.run("env-line", "--key", try f.keyFile())
        #expect(r.code == 0)
        #expect(r.stdout == "SPOOL_LICENSE_SIGNING_KEY=\(Self.seedA.base64EncodedString())\n")
        #expect(r.stderr.isEmpty)
    }

    @Test func envLineWarnsWhenOthersCanReadTheFile() throws {
        let f = try Folder()
        let path = try f.keyFile()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        let r = f.run("env-line", "--key", path)
        #expect(r.code == 0)
        #expect(r.stderr.contains("chmod 600"))
    }

    @Test func aMissingOrBrokenKeyFileFails() throws {
        let f = try Folder()
        let missing = f.run("env-line", "--key", f.path("none.key"))
        #expect(missing.code == 1 && missing.stderr.contains("spool-license keygen"))
        for (name, text) in [("empty.key", ""), ("text.key", "hello"), ("short.key", Data(repeating: 1, count: 16).base64EncodedString())] {
            try Data(text.utf8).write(to: f.url.appendingPathComponent(name))
            let r = f.run("issue", "--email", "a@b.nl", "--key", f.path(name))
            #expect(r.code == 1, Comment(rawValue: name))
            #expect(r.stderr.contains("does not hold a private key"), Comment(rawValue: name))
            #expect(r.stdout.isEmpty, Comment(rawValue: name))
        }
    }

    // MARK: issue

    @Test func issueMakesAKeyThatVerifiesWithThePublicKey() throws {
        let f = try Folder()
        let r = f.run("issue", "--email", "friend@example.com", "--id", "comp-test-1", "--key", try f.keyFile())
        #expect(r.code == 0, "\(r.stderr)")
        let key = r.stdout.trimmingCharacters(in: .newlines)
        let license = LicenseKey.verify(key, publicKey: LicenseKey.publicKey(base64: Self.publicA)!)
        #expect(license?.id == "comp-test-1")
        #expect(license?.email == "friend@example.com")
        #expect(license?.issued == "2026-10-16")
        #expect(r.stdout.hasSuffix("\n") && r.stdout.filter { $0 == "\n" }.count == 1, "stdout holds the key only")
    }

    @Test func issueDefaultIDIsCompDateAndFourHexDigits() throws {
        let f = try Folder()
        let r = f.run("issue", "--email", "friend@example.com", "--key", try f.keyFile())
        #expect(r.code == 0, "\(r.stderr)")
        let license = LicenseKey.verify(r.stdout, publicKey: LicenseKey.publicKey(base64: Self.publicA)!)
        #expect(license?.id == "comp-2026-10-16-a0a1")
        #expect(r.stderr.contains("comp-2026-10-16-a0a1"))
    }

    // The payload bytes are the same as the issuer on 1yc.dev writes (docs/LICENSE-KEYS.md). The signature part can
    // differ: CryptoKit signs Ed25519 with fresh randomness, Node signs deterministically. Both verify.
    @Test func issuePayloadIsByteForByteThePayloadOfTheContractExample() throws {
        let f = try Folder()  // the fixed clock is 2026-10-16, the date of the case `valid`
        let valid = LicenseKeyTests.vectors.cases.first { $0.name == "valid" }!
        let r = f.run("issue", "--email", valid.email!, "--id", valid.id!, "--key", try f.keyFile())
        #expect(r.code == 0, "\(r.stderr)")
        func payload(_ key: String) -> Substring { key.split(separator: ".")[0] }
        #expect(payload(r.stdout.trimmingCharacters(in: .newlines)) == payload(valid.key))
    }

    @Test(arguments: ["", "no-at-sign", "a b@c.nl", "@c.nl", "a@", "a@b.nl\nx"])
    func issueRefusesABadEmail(_ email: String) throws {
        let f = try Folder()
        let args = email.isEmpty ? ["issue", "--key", try f.keyFile()] : ["issue", "--email", email, "--key", try f.keyFile()]
        let r = LicenseTool.run(args, environment: f.environment)
        #expect(r.code == 2, "\(email)")
        #expect(r.stdout.isEmpty)
    }

    @Test func issueRefusesAnIDWithSpaces() throws {
        let f = try Folder()
        let r = f.run("issue", "--email", "a@b.nl", "--id", "two words", "--key", try f.keyFile())
        #expect(r.code == 2)
    }

    @Test func utcDateUsesUTCNotTheLocalZone() {
        // 2026-10-16 23:30 UTC and 2026-10-17 00:30 UTC
        #expect(LicenseTool.utcDate(Date(timeIntervalSince1970: 1_792_193_400)) == "2026-10-16")
        #expect(LicenseTool.utcDate(Date(timeIntervalSince1970: 1_792_197_000)) == "2026-10-17")
    }

    // MARK: verify

    @Test func verifyPrintsTheFieldsOfAValidKey() throws {
        let f = try Folder()
        let valid = LicenseKeyTests.vectors.cases.first { $0.name == "valid" }!
        let r = f.run("verify", valid.key, "--public-key", Self.publicA)
        #expect(r.code == 0)
        #expect(r.stdout == "id: cs_test_a1b2c3\nemail: buyer@example.com\nissued: 2026-10-16\n")
    }

    @Test func verifyTellsThatEveryInvalidVectorIsNotValid() throws {
        let f = try Folder()
        for c in LicenseKeyTests.vectors.cases where !c.valid {
            let r = f.run("verify", c.key, "--public-key", Self.publicA)
            #expect(r.code == 1, Comment(rawValue: c.name))
            #expect(r.stderr == LicenseKey.invalidMessage + "\n", Comment(rawValue: c.name))
            #expect(r.stdout.isEmpty, Comment(rawValue: c.name))
        }
    }

    @Test func verifyTakesThePublicKeyFromUpdatesEnvInTheRepository() throws {
        let f = try Folder()
        try FileManager.default.createDirectory(at: f.url.appendingPathComponent("repo/Packaging"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: f.url.appendingPathComponent("repo/Sources/x"), withIntermediateDirectories: true)
        try Data("# comment\nSPOOL_LICENSE_PUBLIC_KEY=\(Self.publicA)\n".utf8)
            .write(to: f.url.appendingPathComponent("repo/Packaging/updates.env"))
        let valid = LicenseKeyTests.vectors.cases.first { $0.name == "valid" }!
        var env = f.environment
        env.currentDirectory = f.url.appendingPathComponent("repo/Sources/x")  // a folder below the repository root
        let r = LicenseTool.run(["verify", valid.key], environment: env)
        #expect(r.code == 0, "\(r.stderr)")
        // --public-key wins over the file: key B does not accept a key of A.
        let other = LicenseTool.run(["verify", valid.key, "--public-key", LicenseKeyTests.vectors.publicKeyB], environment: env)
        #expect(other.code == 1)
    }

    @Test func verifyNeedsAPublicKeyWhenThereIsNoneToFind() throws {
        let f = try Folder()
        let valid = LicenseKeyTests.vectors.cases.first { $0.name == "valid" }!
        // An empty value.
        try FileManager.default.createDirectory(at: f.url.appendingPathComponent("repo/Packaging"), withIntermediateDirectories: true)
        try Data("SPOOL_LICENSE_PUBLIC_KEY=\n".utf8).write(to: f.url.appendingPathComponent("repo/Packaging/updates.env"))
        var env = f.environment
        env.currentDirectory = f.url.appendingPathComponent("repo")
        let empty = LicenseTool.run(["verify", valid.key], environment: env)
        #expect(empty.code == 2)
        #expect(empty.stderr.contains("is empty") && empty.stderr.contains("--public-key"))
        let bad = LicenseTool.run(["verify", valid.key, "--public-key", "AAAA"], environment: env)
        #expect(bad.code == 2)
        #expect(bad.stderr.contains("32-byte"))
    }

    @Test func updatesValueReadsLikeTheShellFunction() throws {
        let f = try Folder()
        let file = f.url.appendingPathComponent("updates.env")
        try Data("""
        # SPOOL_LICENSE_PUBLIC_KEY=commented
        SPOOL_LICENSE_PUBLIC_KEY_OLD=old
        SPOOL_LICENSE_PUBLIC_KEY="quoted+/="  \n
        """.utf8).write(to: file)
        #expect(LicenseTool.updatesValue("SPOOL_LICENSE_PUBLIC_KEY", in: file) == "quoted+/=")
        #expect(LicenseTool.updatesValue("SPOOL_NOPE", in: file) == nil)
    }

    // MARK: usage

    @Test func usageErrorsExitWith2AndHelpExitsWith0() throws {
        let f = try Folder()
        for args in [[], ["bogus"], ["keygen", "--bogus"], ["keygen", "--out"], ["keygen", "extra"],
                     ["keygen", "--out", "a", "--out", "b"], ["verify"], ["verify", "a", "b"], ["issue"]] {
            let r = LicenseTool.run(args, environment: f.environment)
            #expect(r.code == 2, "\(args)")
            #expect(r.stdout.isEmpty, "\(args)")
            #expect(r.stderr.contains("Usage:"), "\(args)")
        }
        for args in [["--help"], ["help"], ["keygen", "--help"], ["env-line", "-h"], ["issue", "--help"], ["verify", "--help"]] {
            let r = LicenseTool.run(args, environment: f.environment)
            #expect(r.code == 0, "\(args)")
            #expect(r.stdout.contains("Usage:"), "\(args)")
        }
        #expect(LicenseTool.run(["env-line", "--help"], environment: f.environment).stdout.contains("only command that prints the private key"))
        #expect(!FileManager.default.fileExists(atPath: f.path("home")), "usage errors write nothing")
    }

    @Test func optionsCanUseTheEqualsForm() throws {
        let f = try Folder()
        let r = f.run("keygen", "--out=" + f.path("eq.key"))
        #expect(r.code == 0, "\(r.stderr)")
        #expect(FileManager.default.fileExists(atPath: f.path("eq.key")))
    }

    @Test func helpTextFollowsTheWritingRules() {
        for text in [LicenseTool.help, LicenseTool.keygenHelp, LicenseTool.envLineHelp, LicenseTool.issueHelp, LicenseTool.verifyHelp] {
            #expect(!text.contains("\u{2014}"), "no em dash")
        }
    }
}
