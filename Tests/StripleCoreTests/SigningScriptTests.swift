import Foundation
import Testing

/// Runs scripts/make-signing-cert.sh with a fake `security` tool first on PATH and a temporary keychain path,
/// so the keychains of this Mac are never read or changed. The fake logs each call to `calls.log`: argv as is,
/// and a command read by `security -i` from stdin as `stdin: <command>`.
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
        var emptyList = false      // the user search list is empty
    }

    struct Result { var output: String; var status: Int32; var calls: [String] }

    static func run(_ k: Keychain, _ args: [String], env extra: [String: String] = [:]) throws -> Result {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-sign-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keychain = dir.appendingPathComponent("striple-signing.keychain-db")
        if k.file { try Data().write(to: keychain) }
        let log = dir.appendingPathComponent("calls.log")
        let name = "\"Striple Local Signing\""
        let fake = """
        #!/bin/sh
        if [ "$1" = "-i" ]; then
          read -r line
          echo "stdin: $line" >> '\(log.path)'
          set -- $line
        else
          echo "$*" >> '\(log.path)'
        fi
        case "$1" in
          find-generic-password) \(k.password ? "echo 5ec7e7" : "exit 44") ;;
          unlock-keychain) exit 0 ;;
          list-keychains)
            if [ "$3" = "-s" ]; then exit 0; fi
            \(k.emptyList ? "exit 0" : "echo '    \"/Users/x/Library/Keychains/login.keychain-db\"'")
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
        env["HOME"] = "/Users/x"
        env.merge(extra) { $1 }
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
        #expect(r.output.contains("[dry-run] 2. write the backup"))
        #expect(r.output.contains("[dry-run] 3. security create-keychain"))
        #expect(r.calls.isEmpty)
    }

    // The keychain exists but is not on the search list: a real run would unlock it and change the list.
    @Test func aDryRunWithAKeychainDoesNotTouchIt() throws {
        let r = try Self.run(Keychain(file: true, password: true, identity: true, listed: false), ["--dry-run"])
        #expect(r.status == 0)
        #expect(r.output.contains("makes nothing new"))
        #expect(r.calls.isEmpty)
    }

    @Test func theKeychainPasswordIsNeverAnArgument() throws {
        let r = try Self.run(Keychain(file: true, password: true, identity: true, listed: false), [])
        #expect(r.status == 0)
        #expect(r.calls.contains { $0.hasPrefix("stdin: unlock-keychain -p 5ec7e7 ") })
        #expect(!r.calls.contains { !$0.hasPrefix("stdin: ") && $0.contains("5ec7e7") }, "\(r.calls)")
    }

    // bash 3.2 fails on an empty array under set -u, and an empty list would hide the login keychain.
    @Test func anEmptySearchListGetsTheLoginKeychainBack() throws {
        let r = try Self.run(Keychain(file: true, password: true, identity: true, emptyList: true), [])
        #expect(r.status == 0, "\(r.output)")
        let set = r.calls.first { $0.hasPrefix("list-keychains -d user -s") }
        #expect(set?.hasPrefix("list-keychains -d user -s /Users/x/Library/Keychains/login.keychain-db ") == true)
        #expect(set?.hasSuffix("striple-signing.keychain-db") == true)
    }

    @Test func removeWithoutYesWarnsAndChangesNothing() throws {
        let r = try Self.run(Keychain(file: true, password: true, identity: true, listed: true), ["--remove"])
        #expect(r.status == 1)
        #expect(r.output.contains("--import <backup file>"))
        #expect(r.calls.isEmpty)
    }

    @Test func importNeedsAReadableBackup() throws {
        let r = try Self.run(Keychain(file: false, password: false, identity: false), ["--import", "/nonexistent.p12"])
        #expect(r.status == 1)
        #expect(r.output.contains("no such file: /nonexistent.p12"))
        #expect(try Self.run(Keychain(file: false, password: false, identity: false), ["--yes"]).status == 1)
    }

    @Test func removeDeletesTheKeychainThePasswordAndTheListEntry() throws {
        let r = try Self.run(Keychain(file: true, password: true, identity: true, listed: true), ["--remove", "--yes"])
        #expect(r.status == 0)
        #expect(r.calls.contains { $0.hasPrefix("delete-keychain ") && $0.hasSuffix("striple-signing.keychain-db") })
        #expect(r.calls.contains { $0.hasPrefix("delete-generic-password -s Striple Local Signing keychain") })
        let set = r.calls.first { $0.hasPrefix("list-keychains -d user -s") }
        #expect(set == "list-keychains -d user -s /Users/x/Library/Keychains/login.keychain-db")
    }

    // A backup that cannot be written must stop the script before the keychains change.
    @Test func aBackupFolderThatDoesNotExistStopsBeforeAnyChange() throws {
        let r = try Self.run(Keychain(file: false, password: false, identity: false), [],
                             env: ["STRIPLE_SIGNING_BACKUP": "/nonexistent-\(UUID().uuidString)/identity.p12"])
        #expect(r.status == 1)
        #expect(r.output.contains("cannot write the backup to /nonexistent-"))
        #expect(r.calls.isEmpty, "\(r.calls)")
    }

    // The fake `security` refuses create-keychain, so the run fails at the first keychain step. The key must
    // already be in the backup, with its passphrase printed.
    @Test func theBackupIsWrittenBeforeTheKeychainIsMade() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backup = dir.appendingPathComponent("identity.p12")
        let r = try Self.run(Keychain(file: false, password: false, identity: false), [],
                             env: ["STRIPLE_SIGNING_BACKUP": backup.path])
        #expect(r.status != 0)
        #expect(r.calls.first?.hasPrefix("stdin: create-keychain -p ") == true, "\(r.calls)")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        let mode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(r.output.range(of: #"Passphrase: [0-9a-f]{32}\n"#, options: .regularExpression) != nil, "\(r.output)")
        #expect(r.output.range(of: #"SHA-1: +[0-9A-F]{40}\n"#, options: .regularExpression) != nil)
    }

    // `security -i` reads a backslash as an escape, also inside double quotes.
    @Test func securityQuoteEscapesBackslashesAndQuotes() throws {
        let env = Self.script.deletingLastPathComponent().appendingPathComponent("signing-env.sh").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", #"source "$0"; for v in plain 'a b' 'x\y' 'q"t' 'e\"' ''; do striple_security_quote "$v"; echo; done"#, env]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast() == [
            #""plain""#, #""a b""#, #""x\\y""#, #""q\"t""#, #""e\\\"""#, #""""#,
        ])
    }
}
