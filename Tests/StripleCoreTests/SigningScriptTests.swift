import Foundation
import Testing

/// Runs scripts/make-signing-cert.sh with --dry-run and a fake `security` tool first on PATH,
/// so the keychain of this Mac is never read or changed.
@Suite(.serialized) struct SigningScriptTests {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/make-signing-cert.sh")

    /// What the fake keychain has: the certificate, its private key, and the code signing trust.
    struct Keychain { var certificate: Bool; var key: Bool; var trusted: Bool }

    static func run(_ keychain: Keychain) throws -> (output: String, status: Int32) {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("striple-sign-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bin) }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let name = "\"Striple Local Signing\""
        let valid = keychain.certificate && keychain.key && keychain.trusted
        let identity = keychain.certificate && keychain.key
        let fake = """
        #!/bin/sh
        case "$1 $2" in
          "find-identity -v") \(valid ? "echo '  1) ABCD \(name)'; " : "")echo '     \(valid ? 1 : 0) valid identities found' ;;
          "find-identity -p") \(identity ? "echo '  1) ABCD \(name)\(valid ? "" : " (CSSMERR_TP_NOT_TRUSTED)")'; " : "")echo '     identities found' ;;
          "find-certificate -a") \(keychain.certificate ? "echo '    \"labl\"<blob>=\(name)'" : "exit 44") ;;
          "find-certificate -c") printf -- '-----BEGIN CERTIFICATE-----\\nMIIB\\n-----END CERTIFICATE-----\\n' ;;
          *) echo "unexpected: $*" >&2; exit 1 ;;
        esac
        """
        let tool = bin.appendingPathComponent("security")
        try Data(fake.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, "--dry-run"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = bin.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }

    @Test func aValidIdentityNeedsNothing() throws {
        let r = try Self.run(Keychain(certificate: true, key: true, trusted: true))
        #expect(r.status == 0)
        #expect(r.output.contains("valid for code signing. Nothing to do."))
        #expect(!r.output.contains("[dry-run]"))
    }

    // Round 4 finding: a certificate without the trust made the script say "Nothing to do" for ever.
    @Test func aCertificateWithoutTrustIsTrustedAgain() throws {
        let r = try Self.run(Keychain(certificate: true, key: true, trusted: false))
        #expect(r.status == 0)
        #expect(!r.output.contains("Nothing to do"))
        #expect(r.output.contains("[dry-run] security add-trusted-cert -r trustRoot -p codeSign"))
        #expect(!r.output.contains("security import"))
    }

    @Test func aCertificateWithoutItsKeyMustBeRemovedFirst() throws {
        let r = try Self.run(Keychain(certificate: true, key: false, trusted: false))
        #expect(r.status != 0)
        #expect(r.output.contains("security delete-certificate -c \"Striple Local Signing\""))
    }

    @Test func noCertificateMakesANewOne() throws {
        let r = try Self.run(Keychain(certificate: false, key: false, trusted: false))
        #expect(r.status == 0)
        #expect(r.output.contains("[dry-run] security import"))
        #expect(r.output.contains("[dry-run] security add-trusted-cert"))
    }
}
