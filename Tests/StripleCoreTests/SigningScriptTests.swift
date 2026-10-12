import Foundation
import Testing

/// Runs scripts/make-signing-cert.sh with fake `security` and `codesign` tools first on PATH and a temporary
/// keychain path, so the keychains of this Mac are never read or changed. The fakes log each call to `calls.log`:
/// argv as is, a command read by `security -i` from stdin as `stdin: <command>`, and codesign as `codesign <args>`.
/// The fake `security` keeps state in its folder: with `acceptMake`, a full make or import runs to the end.
/// The pin in Packaging/updates.env is not read: `STRIPLE_UPDATES_ENV` is /dev/null (no pin) unless a test gives a file.
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
        var identityHash = "ABCD1234"  // the SHA-1 that find-identity shows for `identity`
        var acceptMake = false     // create-keychain, import and the other make steps succeed
        var badDR = false          // codesign shows a requirement with another certificate
        var importShows: String? = nil  // after an import, find-identity shows this SHA-1, not the file's
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
          printf 'stdin: %s\\n' "$line" >> '\(log.path)'
          set -f; set -- $line; set +f
        else
          printf '%s\\n' "$*" >> '\(log.path)'
        fi
        make() { \(k.acceptMake ? "true" : "echo \"unexpected: $*\" >&2; exit 1") ; }
        case "$1" in
          find-generic-password)
            if \(k.password ? "true" : "false") || [ -f '\(dir.path)/password' ]; then echo 5ec7e7; else exit 44; fi ;;
          unlock-keychain) exit 0 ;;
          list-keychains)
            if [ "$4" = "-s" ]; then exit 0; fi
            \(k.emptyList ? "exit 0" : "echo '    \"/Users/x/Library/Keychains/login.keychain-db\"'")
            \(k.listed ? "echo '    \"\(keychain.path)\"'" : "") ;;
          find-identity)
            if [ -s '\(dir.path)/imported' ]; then printf '  1) %s %s (CSSMERR_TP_NOT_TRUSTED)\\n' "$(cat '\(dir.path)/imported')" '\(name)'
            \(k.identity ? "else echo '  1) \(k.identityHash) \(name) (CSSMERR_TP_NOT_TRUSTED)'" : "")
            fi
            echo '     1 identities found' ;;
          create-keychain) make "$@"; : > '\(keychain.path)' ;;
          set-keychain-settings|set-key-partition-list) make "$@" ;;
          add-generic-password) make "$@"; : > '\(dir.path)/password' ;;
          import)
            make "$@"
            f=$(printf '%s' "$2" | tr -d '"')
            /usr/bin/openssl pkcs12 -in "$f" -nokeys -passin env:STRIPLE_SIGNING_P12_PASSWORD 2>/dev/null \\
              | /usr/bin/openssl x509 -noout -fingerprint -sha1 | sed -e 's/.*=//' -e 's/://g' > '\(dir.path)/imported'
            \(k.importShows.map { "echo \($0) > '\(dir.path)/imported'" } ?? "") ;;
          delete-keychain|delete-generic-password) exit 0 ;;
          *) echo "unexpected: $*" >&2; exit 1 ;;
        esac
        """
        let codesign = """
        #!/bin/sh
        printf 'codesign %s\\n' "$*" >> '\(log.path)'
        if [ "$1" = "--force" ]; then printf '%s' "$3" > '\(dir.path)/signed'; exit 0; fi
        h=$(tr 'A-F' 'a-f' < '\(dir.path)/signed')
        \(k.badDR ? "h=0000" : "")
        echo "designated => identifier \\"com.fskroes.Striple.probe\\" and certificate leaf = H\\"$h\\"" >&2
        """
        let codesignTool = dir.appendingPathComponent("codesign")
        try Data(codesign.utf8).write(to: codesignTool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codesignTool.path)
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
        env["STRIPLE_UPDATES_ENV"] = "/dev/null"
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
        #expect(r.output.contains("(ABCD1234) and signs. Nothing to do."))
        #expect(!r.calls.contains { $0.hasPrefix("list-keychains -d user -s") })
        // "Ready" is proven by a signature, not assumed from the keychain listing.
        #expect(r.calls.contains { $0.hasPrefix("codesign --force --sign ABCD1234 ") }, "\(r.calls)")
        #expect(r.calls.contains { $0.hasPrefix("codesign -d -r - ") })
    }

    @Test func aReadyIdentityWhoseRequirementNamesAnotherCertificateFails() throws {
        var k = Keychain(file: true, password: true, identity: true, listed: true)
        k.badDR = true
        let r = try Self.run(k, [])
        #expect(r.status == 1)
        #expect(r.output.contains("the designated requirement does not name the certificate ABCD1234"), "\(r.output)")
        #expect(!r.output.contains("Nothing to do"))
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

    // MARK: full runs: no secret is ever an argument

    /// A PKCS#12 "Striple Local Signing" identity like the backup of make-signing-cert.sh, and its SHA-1.
    static func makeP12(in dir: URL, passphrase: String, withKey: Bool = true) throws -> (file: URL, sha1: String) {
        let key = dir.appendingPathComponent("k.pem"), cert = dir.appendingPathComponent("c.pem")
        let p12 = dir.appendingPathComponent("backup.p12")
        func openssl(_ args: [String], env: [String: String] = [:]) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            p.arguments = args
            p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
            return String(decoding: data, as: UTF8.self)
        }
        _ = try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "1",
                         "-subj", "/CN=Striple Local Signing", "-keyout", key.path, "-out", cert.path])
        _ = try openssl(["pkcs12", "-export", "-name", "Striple Local Signing"]
                        + (withKey ? ["-inkey", key.path] : ["-nokeys"]) + ["-in", cert.path,
                         "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
                         "-passout", "env:P", "-out", p12.path], env: ["P": passphrase])
        let fp = try openssl(["x509", "-in", cert.path, "-noout", "-fingerprint", "-sha1"])
        let sha1 = fp.split(separator: "=").last.map { $0.replacingOccurrences(of: ":", with: "") }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (p12, sha1)
    }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-p12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aFullMakeKeepsEverySecretOutOfTheArgumentList() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var k = Keychain(file: false, password: false, identity: false)
        k.acceptMake = true
        let r = try Self.run(k, [], env: ["STRIPLE_SIGNING_BACKUP": dir.appendingPathComponent("b.p12").path])
        #expect(r.status == 0, "\(r.output)")
        #expect(r.output.contains("signs with no prompt"))
        let kcPass = r.calls.first { $0.hasPrefix("stdin: create-keychain -p ") }
            .map { String($0.split(separator: " ")[3]) } ?? ""
        let p12Pass = r.output.firstMatch(of: #/Passphrase: ([0-9a-f]{32})\n/#).map { String($0.1) } ?? ""
        #expect(kcPass.count == 48 && p12Pass.count == 32, "\(r.calls)")
        // Each secret reaches security, on stdin.
        #expect(r.calls.contains { $0.hasPrefix("stdin: unlock-keychain -p \(kcPass) ") })
        #expect(r.calls.contains { $0.hasPrefix("stdin: add-generic-password ") && $0.contains(" -w \(kcPass) ") })
        #expect(r.calls.contains { $0.hasPrefix("stdin: import ") && $0.contains(" -P \"\(p12Pass)\" ") })
        #expect(r.calls.contains { $0.hasPrefix("stdin: set-key-partition-list ") && $0.contains(" -k \(kcPass) ") })
        let argv = r.calls.filter { !$0.hasPrefix("stdin: ") }
        #expect(!argv.isEmpty)
        #expect(!argv.contains { $0.contains(kcPass) || $0.contains(p12Pass) }, "\(argv)")
    }

    // The passphrase has the characters that `security -i` needs escaped, and a space.
    @Test func aFullImportKeepsThePassphraseOutOfTheArgumentList() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pass = #"pa ss"w\rd"#
        let (p12, sha1) = try Self.makeP12(in: dir, passphrase: pass)
        var k = Keychain(file: false, password: false, identity: false)
        k.acceptMake = true
        let r = try Self.run(k, ["--import", p12.path], env: ["STRIPLE_SIGNING_P12_PASSWORD": pass])
        #expect(r.status == 0, "\(r.output)")
        #expect(r.output.contains("(\(sha1)) signs with no prompt"), "\(r.output)")
        #expect(r.calls.contains { $0.hasPrefix("stdin: import ") && $0.contains(#" -P "pa ss\"w\\rd" "#) }, "\(r.calls)")
        #expect(!r.calls.contains { !$0.hasPrefix("stdin: ") && ($0.contains("pa ss") || $0.contains(#"w\rd"#)) }, "\(r.calls)")
    }

    // The import reports success only when the keychain then has the certificate of the backup.
    @Test func anImportThatLeavesAnotherCertificateFails() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p12, sha1) = try Self.makeP12(in: dir, passphrase: "secret")
        var k = Keychain(file: false, password: false, identity: false)
        k.acceptMake = true
        k.importShows = "FEDC9876"
        let r = try Self.run(k, ["--import", p12.path], env: ["STRIPLE_SIGNING_P12_PASSWORD": "secret"])
        #expect(r.status == 1)
        #expect(r.output.contains("the keychain identity (FEDC9876) is not the certificate in the backup (\(sha1))"), "\(r.output)")
    }

    @Test func importOverAnotherIdentityStopsAndChangesNothing() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p12, sha1) = try Self.makeP12(in: dir, passphrase: "secret")
        let r = try Self.run(Keychain(file: true, password: true, identity: true, listed: true),
                             ["--import", p12.path], env: ["STRIPLE_SIGNING_P12_PASSWORD": "secret"])
        #expect(r.status == 1)
        #expect(r.output.contains("the keychain has another identity (ABCD1234) than \(p12.path) (\(sha1))"), "\(r.output)")
        #expect(!r.output.contains("Nothing to do"))
        #expect(!r.calls.contains { $0.contains("import ") || $0.contains("create-keychain") || $0.hasPrefix("codesign") })
    }

    @Test func importOfTheIdentityThatIsThereIsReady() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p12, sha1) = try Self.makeP12(in: dir, passphrase: "secret")
        var k = Keychain(file: true, password: true, identity: true, listed: true)
        k.identityHash = sha1
        let r = try Self.run(k, ["--import", p12.path], env: ["STRIPLE_SIGNING_P12_PASSWORD": "secret"])
        #expect(r.status == 0, "\(r.output)")
        #expect(r.output.contains("(\(sha1)) and signs. Nothing to do."))
        #expect(r.calls.contains { $0.hasPrefix("codesign --force --sign \(sha1) ") })
    }

    // MARK: the pin in Packaging/updates.env

    static let pin = "B608FA4F3D9A1FC14CDBAB47421A660E429053DC"

    /// An updates.env with STRIPLE_SIGNING_CERT_SHA1=`sha1`, as the env for `run`.
    static func pinned(_ sha1: String, in dir: URL) throws -> [String: String] {
        let file = dir.appendingPathComponent("updates-\(UUID().uuidString).env")
        try Data("STRIPLE_RELEASES_REPO=fskroes/striple-releases\nSTRIPLE_SIGNING_CERT_SHA1=\(sha1)\n".utf8).write(to: file)
        return ["STRIPLE_UPDATES_ENV": file.path]
    }

    // On a new Mac, a new identity would break the Accessibility permission of every installed copy.
    @Test func makeWithAPinStopsAndChangesNothing() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = dir.appendingPathComponent("b.p12")
        var k = Keychain(file: false, password: false, identity: false)
        k.acceptMake = true
        let r = try Self.run(k, [], env: try Self.pinned(Self.pin, in: dir).merging(["STRIPLE_SIGNING_BACKUP": backup.path]) { $1 })
        #expect(r.status == 1)
        #expect(r.output.contains("pins the identity \(Self.pin)"), "\(r.output)")
        #expect(r.output.contains("scripts/make-signing-cert.sh --import <backup file>"))
        #expect(r.output.contains("--new-identity"))
        #expect(r.calls.isEmpty, "\(r.calls)")
        #expect(!FileManager.default.fileExists(atPath: backup.path))

        let dry = try Self.run(k, ["--dry-run"], env: try Self.pinned(Self.pin, in: dir))
        #expect(dry.status == 0)
        #expect(dry.output.contains("the script stops and makes nothing"), "\(dry.output)")
        #expect(!dry.output.contains("create-keychain"))
    }

    @Test func aPinThatIsNotASHA1StopsTheScript() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try Self.run(Keychain(file: true, password: true, identity: true, listed: true), [],
                             env: try Self.pinned("ABCD1234", in: dir))
        #expect(r.status == 1)
        #expect(r.output.contains("is not a SHA-1: ABCD1234"), "\(r.output)")
        #expect(r.calls.isEmpty)
    }

    @Test func newIdentityMakesOneAndSaysThatThePinChanges() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var k = Keychain(file: false, password: false, identity: false)
        k.acceptMake = true
        let env = try Self.pinned(Self.pin, in: dir).merging(["STRIPLE_SIGNING_BACKUP": dir.appendingPathComponent("b.p12").path]) { $1 }
        let r = try Self.run(k, ["--new-identity"], env: env)
        #expect(r.status == 0, "\(r.output)")
        #expect(r.output.contains("signs with no prompt"))
        #expect(r.output.contains("(it pins \(Self.pin) now)"), "\(r.output)")
        #expect(r.output.contains("asks for the Accessibility permission again"))
        #expect(try Self.run(k, ["--import", "x.p12", "--new-identity"], env: env).output.contains("--new-identity is only for"))
    }

    @Test func aReadyIdentityThatIsNotPinnedFails() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var k = Keychain(file: true, password: true, identity: true, listed: true)
        k.identityHash = "0123456789ABCDEF0123456789ABCDEF01234567"
        let r = try Self.run(k, [], env: try Self.pinned(Self.pin, in: dir))
        #expect(r.status == 1)
        #expect(r.output.contains("the keychain has the identity \(k.identityHash), but "), "\(r.output)")
        #expect(r.output.contains("pins \(Self.pin)"))
        #expect(!r.output.contains("Nothing to do"))
        #expect(!r.calls.contains { $0.hasPrefix("codesign") || $0.contains("create-keychain") || $0.contains("import ") })

        // The pinned identity is ready. The pin may use lowercase letters.
        k.identityHash = Self.pin
        let ok = try Self.run(k, [], env: try Self.pinned(Self.pin.lowercased(), in: dir))
        #expect(ok.status == 0, "\(ok.output)")
        #expect(ok.output.contains("(\(Self.pin)) and signs. Nothing to do."))
    }

    @Test func importOfABackupThatIsNotPinnedFailsAndChangesNothing() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p12, sha1) = try Self.makeP12(in: dir, passphrase: "secret")
        var k = Keychain(file: false, password: false, identity: false)
        k.acceptMake = true
        let r = try Self.run(k, ["--import", p12.path],
                             env: try Self.pinned(Self.pin, in: dir).merging(["STRIPLE_SIGNING_P12_PASSWORD": "secret"]) { $1 })
        #expect(r.status == 1)
        #expect(r.output.contains("\(p12.path) has the identity \(sha1), but "), "\(r.output)")
        #expect(r.output.contains("pins \(Self.pin)"))
        #expect(r.output.contains("Nothing was changed."))
        #expect(r.calls.isEmpty, "\(r.calls)")

        let ok = try Self.run(k, ["--import", p12.path],
                              env: try Self.pinned(sha1, in: dir).merging(["STRIPLE_SIGNING_P12_PASSWORD": "secret"]) { $1 })
        #expect(ok.status == 0, "\(ok.output)")
        #expect(ok.output.contains("pins this identity already"), "\(ok.output)")
    }

    // An updates.env without a value for the pin works as before the pin: make mode makes an identity.
    @Test func anEmptyPinKeepsTheOldBehavior() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var k = Keychain(file: false, password: false, identity: false)
        k.acceptMake = true
        let env = try Self.pinned("", in: dir).merging(["STRIPLE_SIGNING_BACKUP": dir.appendingPathComponent("b.p12").path]) { $1 }
        let r = try Self.run(k, [], env: env)
        #expect(r.status == 0, "\(r.output)")
        #expect(r.output.contains("if releases use this identity"), "\(r.output)")
        var ready = Keychain(file: true, password: true, identity: true, listed: true)
        ready.identityHash = "0123456789ABCDEF0123456789ABCDEF01234567"
        #expect(try Self.run(ready, [], env: try Self.pinned("", in: dir)).output.contains("Nothing to do"))
    }

    // MARK: --remove of the pinned identity needs its backup

    static func deleted(_ r: Result) -> Bool {
        r.calls.contains { $0.hasPrefix("delete-keychain ") || $0.hasPrefix("delete-generic-password ") }
    }

    @Test func removeOfThePinnedIdentityWithoutItsBackupRefuses() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var k = Keychain(file: true, password: true, identity: true, listed: true)
        k.identityHash = Self.pin
        let r = try Self.run(k, ["--remove", "--yes"], env: try Self.pinned(Self.pin, in: dir))
        #expect(r.status == 1)
        #expect(r.output.contains("the keychain has the pinned identity \(Self.pin)."), "\(r.output)")
        #expect(r.output.contains("--remove --yes --backup <backup file>"))
        #expect(r.output.contains("Nothing was deleted."))
        #expect(!Self.deleted(r), "\(r.calls)")
        #expect(!r.calls.contains { $0.hasPrefix("list-keychains -d user -s") && !$0.contains("striple-signing") }, "\(r.calls)")

        // An identity that cannot be read can be the pinned one.
        let unreadable = try Self.run(Keychain(file: true, password: false, identity: false), ["--remove", "--yes"],
                                      env: try Self.pinned(Self.pin, in: dir))
        #expect(unreadable.status == 1)
        #expect(unreadable.output.contains("an identity that cannot be read"), "\(unreadable.output)")
        #expect(!Self.deleted(unreadable))
    }

    @Test func removeWithAWrongBackupRefuses() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p12, sha1) = try Self.makeP12(in: dir, passphrase: "secret")
        var k = Keychain(file: true, password: true, identity: true, listed: true)
        k.identityHash = Self.pin
        let env = try Self.pinned(Self.pin, in: dir).merging(["STRIPLE_SIGNING_P12_PASSWORD": "secret"]) { $1 }
        let other = try Self.run(k, ["--remove", "--yes", "--backup", p12.path], env: env)
        #expect(other.status == 1)
        #expect(other.output.contains("is not a backup of the pinned identity \(Self.pin) (\(sha1))"), "\(other.output)")
        #expect(!Self.deleted(other))

        let missing = try Self.run(k, ["--remove", "--yes", "--backup", dir.appendingPathComponent("no.p12").path], env: env)
        #expect(missing.status == 1)
        #expect(missing.output.contains("no such file"))
        #expect(!Self.deleted(missing))

        // The right certificate, but the wrong passphrase, or no private key: not a backup.
        k.identityHash = sha1
        let pinnedEnv = try Self.pinned(sha1, in: dir)
        let wrongPass = try Self.run(k, ["--remove", "--yes", "--backup", p12.path],
                                     env: pinnedEnv.merging(["STRIPLE_SIGNING_P12_PASSWORD": "wrong"]) { $1 })
        #expect(wrongPass.status == 1)
        #expect(wrongPass.output.contains("cannot read it: wrong passphrase"), "\(wrongPass.output)")
        #expect(!Self.deleted(wrongPass))

        let certDir = dir.appendingPathComponent("cert-only")
        try FileManager.default.createDirectory(at: certDir, withIntermediateDirectories: true)
        let (certOnly, certSha1) = try Self.makeP12(in: certDir, passphrase: "secret", withKey: false)
        k.identityHash = certSha1
        let noKey = try Self.run(k, ["--remove", "--yes", "--backup", certOnly.path],
                                 env: try Self.pinned(certSha1, in: dir).merging(["STRIPLE_SIGNING_P12_PASSWORD": "secret"]) { $1 })
        #expect(noKey.status == 1)
        #expect(noKey.output.contains("has no private key"), "\(noKey.output)")
        #expect(!Self.deleted(noKey))
    }

    @Test func removeWithTheBackupOfThePinnedIdentityDeletes() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p12, sha1) = try Self.makeP12(in: dir, passphrase: "secret")
        var k = Keychain(file: true, password: true, identity: true, listed: true)
        k.identityHash = sha1
        let r = try Self.run(k, ["--remove", "--yes", "--backup", p12.path],
                             env: try Self.pinned(sha1.lowercased(), in: dir).merging(["STRIPLE_SIGNING_P12_PASSWORD": "secret"]) { $1 })
        #expect(r.status == 0, "\(r.output)")
        #expect(r.output.contains("is a backup of the pinned identity"))
        #expect(r.calls.contains { $0.hasPrefix("delete-keychain ") && $0.hasSuffix("striple-signing.keychain-db") })
        #expect(try Self.run(k, ["--backup", p12.path]).output.contains("--backup is only for --remove"))
    }

    @Test func removeOfAnIdentityThatIsNotPinnedNeedsNoBackup() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var k = Keychain(file: true, password: true, identity: true, listed: true)
        k.identityHash = "0123456789ABCDEF0123456789ABCDEF01234567"
        let r = try Self.run(k, ["--remove", "--yes"], env: try Self.pinned(Self.pin, in: dir))
        #expect(r.status == 0, "\(r.output)")
        #expect(r.calls.contains { $0.hasPrefix("delete-keychain ") && $0.hasSuffix("striple-signing.keychain-db") })
        #expect(r.calls.contains { $0.hasPrefix("delete-generic-password ") })
    }

    // MARK: security -i lines

    static func shell(_ script: String, path: String? = nil) throws -> (out: String, err: String, status: Int32) {
        let env = Self.script.deletingLastPathComponent().appendingPathComponent("signing-env.sh").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "source \"$0\"; " + script, env]
        if let path { p.environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { $1 } }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self), p.terminationStatus)
    }

    @Test func securityQuoteRefusesALineBreak() throws {
        for v in [#"$'a\nb'"#, #"$'a\rb'"#] {
            let r = try Self.shell("striple_security_quote \(v)")
            #expect(r.status == 2, "\(v)")
            #expect(r.out.isEmpty)
            #expect(r.err.contains("cannot have a line break"))
        }
    }

    // `security -i` reads 4096 bytes at a time and runs the rest of a longer line as a second command.
    @Test func securitySecretRunsOnlyOneLineBelowTheLimit() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("calls.log")
        let fake = "#!/bin/sh\ncat >> '\(log.path)'\n"
        try Data(fake.utf8).write(to: dir.appendingPathComponent("security"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("security").path)
        let path = dir.path + ":/usr/bin:/bin"
        func lines() -> Int { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count }

        #expect(try Self.shell(#"striple_security_secret "x$(printf 'y%.0s' $(seq 1 3998))""#, path: path).status == 0)
        #expect(lines() == 1)
        for refused in [#""x$(printf 'y%.0s' $(seq 1 3999))""#,     // 4000 bytes
                        #""$(printf '\303\251%.0s' $(seq 1 2000))""#, // 2000 characters, 4000 bytes
                        #"$'a\nb'"#, #"$'a\rb'"#] {
            let r = try Self.shell("striple_security_secret \(refused)", path: path)
            #expect(r.status == 2, "\(refused)")
            #expect(r.err.contains("striple: a security command must be"), "\(r.err)")
        }
        #expect(lines() == 1, "a refused line must never reach security")
    }
}
