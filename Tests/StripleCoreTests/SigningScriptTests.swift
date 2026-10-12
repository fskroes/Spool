import Foundation
import Testing

/// Runs scripts/make-signing-cert.sh with a fake `security` tool first on PATH and a temporary keychain path,
/// so the keychains of this Mac are never read or changed. The fake logs each call to `calls.log`.
@Suite(.serialized) struct SigningScriptTests {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/make-signing-cert.sh")

    /// What the fake keychains have.
    struct Keychain {
        var file: Bool             // striple-signing.keychain-db exists
        var password: Bool         // the password item is in the login keychain
        var identity: Bool         // the identity is in the Striple keychain
        var listed = false         // the Striple keychain is on the search list
    }

    struct Result { var output: String; var status: Int32; var calls: [String] }

    static func run(_ k: Keychain, _ args: [String]) throws -> Result {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-sign-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keychain = dir.appendingPathComponent("striple-signing.keychain-db")
        if k.file { try Data().write(to: keychain) }
        let log = dir.appendingPathComponent("calls.log")
        let name = "\"Striple Local Signing\""
        let fake = """
        #!/bin/sh
        echo "$*" >> '\(log.path)'
        case "$1" in
          find-generic-password) \(k.password ? "echo secret" : "exit 44") ;;
          unlock-keychain) exit 0 ;;
          list-keychains)
            if [ "$3" = "-s" ]; then exit 0; fi
            echo '    "/Users/x/Library/Keychains/login.keychain-db"'
            \(k.listed ? "echo '    \"\(keychain.path)\"'" : "") ;;
          find-identity)
            \(k.identity ? "echo '  1) ABCD1234 \(name) (CSSMERR_TP_NOT_TRUSTED)'" : "")
            echo '     1 identities found' ;;
          delete-keychain|delete-generic-password) exit 0 ;;
          *) echo "unexpected: $*" >&2; exit 1 ;;
        esac
        """
        let tool = dir.appendingPathComponent("security")
        try Data(fake.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = dir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["STRIPLE_SIGNING_KEYCHAIN"] = keychain.path
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let calls = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        return Result(output: String(decoding: data, as: UTF8.self), status: p.terminationStatus, calls: calls)
    }

    @Test func aReadyIdentityNeedsNothing() throws {
        let r = try Self.run(Keychain(file: true, password: true, identity: true, listed: true), [])
        #expect(r.status == 0)
        #expect(r.output.contains("(ABCD1234). Nothing to do."))
        #expect(!r.calls.contains { $0.hasPrefix("list-keychains -d user -s") })
    }

    // codesign finds an identity only in a keychain on the search list; a list reset by another tool must not
    // make the build fall back to ad hoc.
    @Test func aKeychainThatLeftTheSearchListIsAddedAgainAndKeepsTheOthers() throws {
        let r = try Self.run(Keychain(file: true, password: true, identity: true, listed: false), [])
        #expect(r.status == 0)
        let set = r.calls.first { $0.hasPrefix("list-keychains -d user -s") }
        #expect(set?.contains("/Users/x/Library/Keychains/login.keychain-db") == true)
        #expect(set?.hasSuffix("striple-signing.keychain-db") == true)
    }

    @Test func aKeychainWithoutItsPasswordMustBeRemovedFirst() throws {
        let r = try Self.run(Keychain(file: true, password: false, identity: true), [])
        #expect(r.status != 0)
        #expect(r.output.contains("scripts/make-signing-cert.sh --remove"))
    }

    @Test func aKeychainWithoutTheIdentityMustBeRemovedFirst() throws {
        let r = try Self.run(Keychain(file: true, password: true, identity: false), [])
        #expect(r.status != 0)
        #expect(r.output.contains("scripts/make-signing-cert.sh --remove"))
    }

    @Test func aDryRunChangesNothing() throws {
        let r = try Self.run(Keychain(file: false, password: false, identity: false), ["--dry-run"])
        #expect(r.status == 0)
        #expect(r.output.contains("[dry-run] 2. security create-keychain"))
        #expect(r.calls.isEmpty)
    }

    @Test func removeDeletesTheKeychainThePasswordAndTheListEntry() throws {
        let r = try Self.run(Keychain(file: true, password: true, identity: true, listed: true), ["--remove"])
        #expect(r.status == 0)
        #expect(r.calls.contains { $0.hasPrefix("delete-keychain ") && $0.hasSuffix("striple-signing.keychain-db") })
        #expect(r.calls.contains { $0.hasPrefix("delete-generic-password -s Striple Local Signing keychain") })
        let set = r.calls.first { $0.hasPrefix("list-keychains -d user -s") }
        #expect(set == "list-keychains -d user -s /Users/x/Library/Keychains/login.keychain-db")
    }
}
