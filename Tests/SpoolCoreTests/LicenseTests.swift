import Foundation
import Testing
@testable import SpoolCore

/// The verifier side of docs/LICENSE-KEYS.md. The cases come from docs/license-test-vectors.json, the file
/// the issuer on 1yc.dev tests against too.
@Suite struct LicenseKeyTests {
    struct Vectors: Decodable {
        struct Case: Decodable {
            var name: String
            var key: String
            var valid: Bool
            var email: String?
            var id: String?
            var issued: String?
        }
        var publicKeyA: String
        var seedA: String
        var publicKeyB: String
        var cases: [Case]
    }

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let vectors: Vectors = {
        let url = root.appendingPathComponent("docs/license-test-vectors.json")
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()
    static var keyA: Data { LicenseKey.publicKey(base64: vectors.publicKeyA)! }

    @Test func everyVectorHasTheExpectedResult() {
        #expect(Self.vectors.cases.count >= 10)
        for c in Self.vectors.cases {
            let license = LicenseKey.verify(c.key, publicKey: Self.keyA)
            #expect((license != nil) == c.valid, "\(c.name)")
            if let email = c.email { #expect(license?.email == email, "\(c.name)") }
            if let id = c.id { #expect(license?.id == id, "\(c.name)") }
            if let issued = c.issued { #expect(license?.issued == issued, "\(c.name)") }
        }
    }

    @Test func theStoredKeyHasNoWhiteSpace() throws {
        let wrapped = try #require(Self.vectors.cases.first { $0.name.hasPrefix("valid, wrapped") })
        let license = try #require(LicenseKey.verify(wrapped.key, publicKey: Self.keyA))
        #expect(license.key == Self.vectors.cases[0].key)
        #expect(!license.key.contains { $0.isWhitespace })
    }

    // The case "signed by another key" fails with key A because key B signed it. With key B it is valid,
    // so it fails for the right reason.
    @Test func aKeyOfAnotherPairFailsOnlyBecauseOfThePair() throws {
        let other = try #require(Self.vectors.cases.first { $0.name == "signed by another key" })
        let keyB = try #require(LicenseKey.publicKey(base64: Self.vectors.publicKeyB))
        #expect(LicenseKey.verify(other.key, publicKey: Self.keyA) == nil)
        #expect(LicenseKey.verify(other.key, publicKey: keyB) != nil)
    }

    @Test func theSeedGivesThePublicKeyOfTheVectors() throws {
        let seed = try #require(Data(base64Encoded: Self.vectors.seedA))
        #expect(try LicenseKey.publicKey(seed: seed) == Self.keyA)
    }

    // CryptoKit and Node sign the same payload bytes. The bytes, not the signature, must match: the
    // signature of CryptoKit is not always the same for the same input, but both are valid Ed25519.
    @Test func anIssuedKeyHasThePayloadOfTheIssuerAndVerifies() throws {
        let seed = try #require(Data(base64Encoded: Self.vectors.seedA))
        let valid = Self.vectors.cases[0]
        let key = try LicenseKey.issue(id: valid.id!, email: valid.email!, issued: valid.issued!, seed: seed)
        #expect(key.split(separator: ".")[0] == valid.key.split(separator: ".")[0])
        let license = try #require(LicenseKey.verify(key, publicKey: Self.keyA))
        #expect(license == License(id: valid.id!, email: valid.email!, issued: valid.issued!, key: key))
    }

    @Test func issueEscapesTheEmailLikeJSON() throws {
        let seed = try #require(Data(base64Encoded: Self.vectors.seedA))
        let email = #"a"b\c/d@example.com"#
        let key = try LicenseKey.issue(id: "comp-2026-10-16-1", email: email, issued: "2026-10-16", seed: seed)
        #expect(LicenseKey.verify(key, publicKey: Self.keyA)?.email == email)
    }

    @Test(arguments: ["", "abc", "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMb==", "AAAA"])
    func aPublicKeyMustBe32Bytes(_ text: String) {
        #expect(LicenseKey.publicKey(base64: text) == nil)
    }

    @Test(arguments: ["", "SPOOL-", "SPOOL-.", "SPOOL-a.b.c", "SPOOL-a=.b"])
    func malformedKeysAreNotValid(_ text: String) {
        #expect(LicenseKey.verify(text, publicKey: Self.keyA) == nil)
    }
}

@Suite struct LicenseStatusTests {
    static var valid: String { LicenseKeyTests.vectors.cases[0].key }
    static var keyA: String { LicenseKeyTests.vectors.publicKeyA }

    @Test func aValidStoredKeyLicensesTheApp() throws {
        let status = LicenseStatus.resolve(storedKey: Self.valid + "\n", publicKey: Self.keyA, inAppBundle: true)
        guard case .licensed(let license) = status else { Issue.record("\(status)"); return }
        #expect(license.email == "buyer@example.com")
        #expect(status.allowsStart)
    }

    @Test func noKeyOrABadKeyStopsTheApp() {
        #expect(LicenseStatus.resolve(storedKey: nil, publicKey: Self.keyA, inAppBundle: true) == .unlicensed)
        #expect(LicenseStatus.resolve(storedKey: "SPOOL-x.y", publicKey: Self.keyA, inAppBundle: true) == .unlicensed)
        #expect(!LicenseStatus.unlicensed.allowsStart)
    }

    // Removing SpoolLicensePublicKey from Info.plist, or breaking it, must not unlock a bundled app.
    @Test func anAppBundleWithoutAValidPublicKeyIsUnlicensed() {
        #expect(LicenseStatus.resolve(storedKey: Self.valid, publicKey: nil, inAppBundle: true) == .unlicensed)
        #expect(LicenseStatus.resolve(storedKey: Self.valid, publicKey: "", inAppBundle: true) == .unlicensed)
        #expect(LicenseStatus.resolve(storedKey: Self.valid, publicKey: "bm90IGEga2V5", inAppBundle: true) == .unlicensed)
    }

    // `swift build` products have no Info.plist: scripts/verify smoke and the tests run them.
    @Test func aBinaryOutsideAnAppBundleNeedsNoLicense() {
        let status = LicenseStatus.resolve(storedKey: nil, publicKey: nil, inAppBundle: false)
        #expect(status == .notRequired && status.allowsStart)
    }

    @Test func theFileStoresTheKeyForThisUserOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spool-license-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = LicenseFile(url: dir.appendingPathComponent("license.key"))
        #expect(file.read() == nil)
        try file.write(Self.valid)
        #expect(file.read() == Self.valid + "\n")
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }
}
