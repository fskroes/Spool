import CryptoKit
import Foundation

/// A paid license of Spool. The contract is docs/LICENSE-KEYS.md: `SPOOL-<payload>.<signature>`, the payload
/// a JSON object in base64url, the signature Ed25519 over the payload bytes. Checked on the Mac, with no
/// network call.
public struct License: Equatable, Sendable {
    /// The order ID: a Stripe Checkout Session ID, or `comp-...` for a key the owner gave away.
    public var id: String
    public var email: String
    /// `YYYY-MM-DD`, UTC.
    public var issued: String
    /// The key with all white space removed, as Spool stores it.
    public var key: String
}

public enum LicenseKey {
    public static let prefix = "SPOOL-"
    public static let product = "spool"
    public static let version = 1
    /// The text the app shows for every key that is not valid. It does not say which check failed.
    public static let invalidMessage = "This license key is not valid."
    /// Where a user buys a key, and where 1yc.dev sends a lost key again (docs/LICENSE-KEYS.md).
    public static let buyURL = URL(string: "https://1yc.dev/spool")!
    public static let restoreURL = URL(string: "https://1yc.dev/spool/restore")!

    /// The key without white space: email clients wrap long lines.
    public static func normalized(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// The license in `text` when its signature is valid for `publicKey` (32 raw bytes) and its payload
    /// follows the contract. Nil for every other text.
    public static func verify(_ text: String, publicKey: Data) -> License? {
        let key = normalized(text)
        guard key.hasPrefix(prefix) else { return nil }
        let parts = key.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payload = base64URLDecode(parts[0]),
              let signature = base64URLDecode(parts[1]), signature.count == 64,
              let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              verifier.isValidSignature(signature, for: payload),
              let fields = try? JSONDecoder().decode(Payload.self, from: payload),
              fields.v == version, fields.product == product,
              !fields.id.isEmpty, !fields.email.isEmpty, !fields.issued.isEmpty
        else { return nil }
        return License(id: fields.id, email: fields.email, issued: fields.issued, key: key)
    }

    /// The 32-byte public key in standard base64 (Info.plist, Packaging/updates.env). Nil when it is not one.
    public static func publicKey(base64: String) -> Data? {
        guard let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)),
              (try? Curve25519.Signing.PublicKey(rawRepresentation: data)) != nil else { return nil }
        return data
    }

    // MARK: Issue (the owner's tool, spool-license)

    /// The public key of a 32-byte Ed25519 seed.
    public static func publicKey(seed: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
    }

    /// A new key for the order `id`, signed with the 32-byte Ed25519 `seed`. The payload has the fields in
    /// the order of the contract, like the issuer on 1yc.dev.
    public static func issue(id: String, email: String, issued: String, seed: Data) throws -> String {
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func json(_ s: String) throws -> String { String(decoding: try encoder.encode(s), as: UTF8.self) }
        let text = "{\"v\":\(version),\"product\":\(try json(product)),\"id\":\(try json(id)),"
            + "\"email\":\(try json(email)),\"issued\":\(try json(issued))}"
        let payload = Data(text.utf8)
        let signature = try signer.signature(for: payload)
        return prefix + base64URLEncode(payload) + "." + base64URLEncode(signature)
    }

    // MARK: base64url (RFC 4648, section 5), no padding

    static func base64URLDecode(_ text: Substring) -> Data? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !text.isEmpty, text.count % 4 != 1,
              text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }

    static func base64URLEncode<D: DataProtocol>(_ data: D) -> String {
        Data(data).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct Payload: Decodable {
        var v: Int
        var product: String
        var id: String
        var email: String
        var issued: String
    }
}

/// Whether this copy of Spool may start its window manager.
public enum LicenseStatus: Equatable, Sendable {
    case licensed(License)
    /// No valid key is stored. The window manager does not start.
    case unlicensed
    /// A debug binary of `swift build` with no bundle ID: a developer run (`scripts/verify smoke`, tests).
    /// It has no Info.plist, so no public key, and needs no license. See `LicenseKeeper.needsLicense`.
    case notRequired

    public var allowsStart: Bool { self != .unlicensed }

    /// `publicKey` is the base64 text of `SpoolLicensePublicKey` in Info.plist, or nil when there is none.
    /// `inAppBundle` is true when this copy needs a license (`LicenseKeeper.needsLicense`). Such a copy with no
    /// valid public key is unlicensed: removing the key must not unlock the app.
    public static func resolve(storedKey: String?, publicKey: String?, inAppBundle: Bool) -> LicenseStatus {
        guard let publicKey else { return inAppBundle ? .unlicensed : .notRequired }
        guard let keyData = LicenseKey.publicKey(base64: publicKey),
              let storedKey, let license = LicenseKey.verify(storedKey, publicKey: keyData) else { return .unlicensed }
        return .licensed(license)
    }
}

/// The stored key: `license.key` in the data folder (docs/LICENSE-KEYS.md).
public struct LicenseFile: Sendable {
    public var url: URL

    public init(url: URL = SpoolPaths.supportDirectory.appendingPathComponent("license.key")) {
        self.url = url
    }

    /// The stored text, or nil when there is no file.
    public func read() -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// Writes the key (one line) readable by this user only. The file has mode 600 from the moment it exists:
    /// it is made with that mode under another name, then renamed over the old file.
    public func write(_ key: String) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(".license.key.\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let data = Data((key + "\n").utf8)
        let written = data.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
        let closed = close(fd)
        guard written == data.count, closed == 0, rename(temp.path, url.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            unlink(temp.path)
            throw POSIXError(code)
        }
    }
}
