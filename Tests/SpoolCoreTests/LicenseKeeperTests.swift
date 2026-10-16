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

    // F25: the license window comes before the guide, and an unlicensed engine refuses at launch so its
    // status says why, also with "start at launch" off.
    @Test func theLaunchPlanPutsTheLicenseFirst() {
        let licensed = LicenseStatus.licensed(License(id: "i", email: "e", issued: "d", key: "k"))
        #expect(LicenseLaunch.window(for: .unlicensed) == .license)
        #expect(LicenseLaunch.window(for: licensed) == .guideIfNeeded)
        #expect(LicenseLaunch.window(for: .notRequired) == .guideIfNeeded)
        #expect(LicenseLaunch.startsEngine(autoStart: false, status: .unlicensed))
        #expect(!LicenseLaunch.startsEngine(autoStart: false, status: licensed))
        #expect(LicenseLaunch.startsEngine(autoStart: true, status: licensed))
        #expect(!LicenseLaunch.startsEngine(autoStart: false, status: .notRequired))
    }

    // An edited or re-signed copy is not signed by the release team: its Info.plist key is not used, so a key
    // the cracker put there cannot unlock it.
    @Test func onlyACopySignedByTheTeamUsesItsInfoPlistKey() {
        let info: [String: Any] = ["SpoolLicensePublicKey": Self.vectors.publicKeyA]
        #expect(LicenseKeeper.trustedPublicKey(info: info, signedByReleaseTeam: true) == Self.vectors.publicKeyA)
        #expect(LicenseKeeper.trustedPublicKey(info: info, signedByReleaseTeam: false) == nil)
        // A key signed by the cracker's own pair, stored next to the copy: still locked.
        let original = keeper()
        guard case .activated = original.activate(Self.valid.key) else {
            Issue.record("a valid key must activate")
            return
        }
        let resigned = LicenseKeeper(publicKey: LicenseKeeper.trustedPublicKey(info: info, signedByReleaseTeam: false),
                                     inAppBundle: true, file: original.file)
        #expect(resigned.status == .unlicensed)
    }

    // The team in the binary is the team of the releases.
    @Test func theCompiledTeamIsTheTeamOfTheReleases() throws {
        let env = try String(contentsOf: LicenseKeyTests.root.appendingPathComponent("Packaging/updates.env"), encoding: .utf8)
        #expect(env.contains("\nSPOOL_TEAM_ID=\(LicenseKeeper.releaseTeam)\n"))
    }

    @Test func whatALicenseLinkDoes() {
        let licensed = LicenseStatus.licensed(License(id: "i", email: "e", issued: "d", key: "k"))
        #expect(LicenseLaunch.urlAction(key: "SPOOL-x.y", status: .notRequired) == .ignore)
        #expect(LicenseLaunch.urlAction(key: "", status: .unlicensed) == .openLicenseWindow)
        #expect(LicenseLaunch.urlAction(key: "", status: licensed) == .openSettings)
        #expect(LicenseLaunch.urlAction(key: "SPOOL-x.y", status: .unlicensed) == .activate("SPOOL-x.y"))
        #expect(LicenseLaunch.urlAction(key: "SPOOL-x.y", status: licensed) == .activate("SPOOL-x.y"),
                "a new key from the email replaces the old one")
    }

    // The file never has another mode than 600, and a second write leaves no temporary file.
    @Test func theKeyFileIsMode600AndReplacedInPlace() throws {
        let k = keeper()
        try k.file.write("first")
        try k.file.write("second")
        #expect(k.file.read() == "second\n")
        let mode = try FileManager.default.attributesOfItem(atPath: k.file.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: k.file.url.deletingLastPathComponent().path)
        #expect(names == ["license.key"])
    }

    @Test func infoPlistKey() {
        #expect(LicenseKeeper.publicKey(info: ["SpoolLicensePublicKey": "abc"]) == "abc")
        #expect(LicenseKeeper.publicKey(info: ["SpoolLicensePublicKey": "  \n"]) == nil)
        #expect(LicenseKeeper.publicKey(info: ["SpoolLicensePublicKey": 5]) == nil)
        #expect(LicenseKeeper.publicKey(info: [:]) == nil)
        #expect(LicenseKeeper.publicKey(info: nil) == nil)
    }

    // A release build needs a key, also when its bundle is renamed (Spool.x), copied, or has no Info.plist
    // (no bundle ID). Only a debug binary of `swift build` runs without one.
    @Test func onlyADebugBinaryWithoutBundleIDRunsWithoutAKey() {
        #expect(LicenseKeeper.needsLicense(debugBuild: false, bundleIdentifier: "com.fskroes.Spool"))
        #expect(LicenseKeeper.needsLicense(debugBuild: false, bundleIdentifier: nil))
        #expect(LicenseKeeper.needsLicense(debugBuild: true, bundleIdentifier: "com.fskroes.Spool"))
        #expect(!LicenseKeeper.needsLicense(debugBuild: true, bundleIdentifier: nil))
        let release = LicenseKeeper(publicKey: nil, inAppBundle: LicenseKeeper.needsLicense(debugBuild: false, bundleIdentifier: nil))
        #expect(release.status == .unlicensed, "a release binary with its Info.plist removed stays locked")
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
