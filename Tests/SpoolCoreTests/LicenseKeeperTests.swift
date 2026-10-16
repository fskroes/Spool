import Foundation
import Testing
@testable import SpoolCore

/// The app side of the license: the stored key, the activation, and the answers to `spool license` (F25).
@Suite struct LicenseKeeperTests {
    static let vectors = LicenseKeyTests.vectors
    static var valid: LicenseKeyTests.Vectors.Case { vectors.cases[0] }

    /// A keeper with its own license file in a temporary folder.
    func keeper(publicKey: String? = LicenseKeyTests.vectors.publicKeyA, inAppBundle: Bool = true) -> LicenseKeeper {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spool-license-test-\(UUID().uuidString)")
        return LicenseKeeper(publicKey: publicKey, inAppBundle: inAppBundle,
                             file: LicenseFile(url: dir.appendingPathComponent("license.key")))
    }

    @Test func aValidKeyIsStoredAndLicensesTheApp() throws {
        let k = keeper()
        #expect(k.status == .unlicensed)
        guard case .activated(let license) = k.activate(Self.valid.key) else {
            Issue.record("a valid key must activate")
            return
        }
        #expect(license.email == Self.valid.email)
        #expect(k.status == .licensed(license))
        #expect(k.file.read()?.trimmingCharacters(in: .whitespacesAndNewlines) == license.key)
    }

    @Test func aKeyWrappedByAnEmailClientActivates() throws {
        let k = keeper()
        let wrapped = try #require(Self.vectors.cases.first { $0.name.hasPrefix("valid, wrapped") })
        guard case .activated = k.activate(wrapped.key) else {
            Issue.record("a wrapped key must activate")
            return
        }
        #expect(k.file.read()?.contains(" ") == false)
    }

    @Test func aKeyThatIsNotValidIsNotStored() {
        let k = keeper()
        for c in Self.vectors.cases where !c.valid {
            #expect(k.activate(c.key) == .invalid, "\(c.name)")
        }
        #expect(k.activate("") == .invalid)
        #expect(k.file.read() == nil)
        #expect(k.status == .unlicensed)
    }

    @Test func aBadKeyDoesNotReplaceAGoodOne() {
        let k = keeper()
        _ = k.activate(Self.valid.key)
        #expect(k.activate("SPOOL-nope") == .invalid)
        #expect(k.status != .unlicensed)
    }

    @Test func aBuildOutsideAnAppBundleNeedsNoLicense() {
        let k = keeper(publicKey: nil, inAppBundle: false)
        #expect(k.status == .notRequired)
        #expect(k.activate(Self.valid.key) == .notRequired)
        #expect(k.file.read() == nil)
    }

    @Test func anAppBundleWithoutAPublicKeyStaysUnlicensed() {
        let k = keeper(publicKey: nil, inAppBundle: true)
        #expect(k.status == .unlicensed)
        #expect(k.activate(Self.valid.key) == .invalid)
    }

    @Test func aFileThatCannotBeWrittenIsReported() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("spool-license-blocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        // The data folder is a file, so the key cannot go in it.
        let k = LicenseKeeper(publicKey: Self.vectors.publicKeyA, inAppBundle: true,
                              file: LicenseFile(url: blocker.appendingPathComponent("license.key")))
        guard case .saveFailed(let message) = k.activate(Self.valid.key) else {
            Issue.record("a write error must be reported")
            return
        }
        #expect(message.hasPrefix("Spool could not save the license key"))
        #expect(k.response(for: .saveFailed(message)) == IPCResponse(ok: false, error: message))
    }

    @Test func infoPlistKey() {
        #expect(LicenseKeeper.publicKey(info: ["SpoolLicensePublicKey": "abc"]) == "abc")
        #expect(LicenseKeeper.publicKey(info: ["SpoolLicensePublicKey": "  \n"]) == nil)
        #expect(LicenseKeeper.publicKey(info: ["SpoolLicensePublicKey": 5]) == nil)
        #expect(LicenseKeeper.publicKey(info: [:]) == nil)
        #expect(LicenseKeeper.publicKey(info: nil) == nil)
    }

    @Test func appBundleDetection() {
        #expect(LicenseKeeper.isAppBundle(URL(fileURLWithPath: "/Applications/Spool.app")))
        #expect(LicenseKeeper.isAppBundle(URL(fileURLWithPath: "/Applications/Spool.app/")))
        #expect(!LicenseKeeper.isAppBundle(URL(fileURLWithPath: "/repo/.build/debug")))
        #expect(!LicenseKeeper.isAppBundle(URL(fileURLWithPath: "/Applications/Spool.app/Contents/MacOS")))
    }

    @Test func statusAnswers() {
        let unlicensed = keeper()
        #expect(unlicensed.statusResponse() == IPCResponse(ok: false, error: "Not licensed.", license: LicenseReport(.unlicensed)))
        _ = unlicensed.activate(Self.valid.key)
        let response = unlicensed.statusResponse()
        #expect(response.ok)
        #expect(response.license?.text == "Licensed to buyer@example.com (order cs_test_a1b2c3)")
        let dev = keeper(publicKey: nil, inAppBundle: false).statusResponse()
        #expect(dev.ok)
        #expect(dev.license?.state == .notRequired)
    }

    @Test func activationAnswers() {
        let k = keeper()
        #expect(k.response(for: .invalid) == IPCResponse(ok: false, error: LicenseKey.invalidMessage))
        #expect(k.response(for: .invalid).error == "This license key is not valid.")
        #expect(k.response(for: .notRequired).license?.state == .notRequired)
        let outcome = k.activate(Self.valid.key)
        #expect(k.response(for: outcome).license?.state == .licensed)
        #expect(k.response(for: outcome).ok)
    }
}
