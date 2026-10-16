import Foundation

/// What `spool license` shows: the license status of the running app, without the key itself.
public struct LicenseReport: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case licensed
        case unlicensed
        /// A developer build outside an app bundle (`LicenseStatus.notRequired`).
        case notRequired = "not-required"
    }

    public var state: State
    public var email: String?
    /// The order ID.
    public var order: String?

    public init(_ status: LicenseStatus) {
        switch status {
        case .licensed(let license): (state, email, order) = (.licensed, license.email, license.id)
        case .unlicensed: (state, email, order) = (.unlicensed, nil, nil)
        case .notRequired: (state, email, order) = (.notRequired, nil, nil)
        }
    }

    public static let notLicensedText = "Not licensed."
    public static let notRequiredText = "This build of Spool needs no license."

    /// The line `spool license` prints.
    public var text: String {
        switch state {
        case .licensed: return "Licensed to \(email ?? "") (order \(order ?? ""))"
        case .unlicensed: return Self.notLicensedText
        case .notRequired: return Self.notRequiredText
        }
    }
}

/// What the app does at launch about the license (F25). AppDelegate follows it.
public enum LicenseLaunch {
    public enum Window: Equatable, Sendable {
        /// The window "Activate Spool". The guide comes after a successful activation.
        case license
        /// The first-launch guide, when the first run is not done.
        case guideIfNeeded
    }

    /// Without a license the engine is asked to start anyway, so it refuses at once and its status
    /// (menu, Settings, `spool state`) says why, also when "start at launch" is off.
    public static func startsEngine(autoStart: Bool, status: LicenseStatus) -> Bool {
        autoStart || status == .unlicensed
    }

    /// The window to open after launch. `status` is read after a `spool://license` URL that came in
    /// before the launch finished was activated.
    public static func window(for status: LicenseStatus) -> Window {
        status == .unlicensed ? .license : .guideIfNeeded
    }
}

/// Reads, checks and stores the key of one copy of Spool. The app owns one. It has no UI, so tests use it
/// with a temporary file.
public struct LicenseKeeper: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The key is valid and stored.
        case activated(License)
        /// A developer build: nothing to activate, nothing stored.
        case notRequired
        /// The key is not valid for the public key of this app. Nothing is stored.
        case invalid
        /// The key is valid, but the file could not be written. The text says why.
        case saveFailed(String)
    }

    /// `SpoolLicensePublicKey` of Info.plist (base64), or nil when the app has none.
    public var publicKey: String?
    public var inAppBundle: Bool
    public var file: LicenseFile

    public init(publicKey: String?, inAppBundle: Bool, file: LicenseFile = LicenseFile()) {
        self.publicKey = publicKey
        self.inAppBundle = inAppBundle
        self.file = file
    }

    /// The `SpoolLicensePublicKey` of an Info.plist dictionary. Nil when it is missing, not text, or empty.
    public static func publicKey(info: [String: Any]?) -> String? {
        guard let text = info?["SpoolLicensePublicKey"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// True when this copy needs a license key. Only a debug binary of `swift build`, which has no bundle ID,
    /// runs without one (`scripts/verify smoke`, the tests). A release build always needs a key: a renamed
    /// or copied bundle, or one without its Info.plist, must not unlock the app.
    public static func needsLicense(debugBuild: Bool, bundleIdentifier: String?) -> Bool {
        !debugBuild || bundleIdentifier != nil
    }

    public var status: LicenseStatus {
        .resolve(storedKey: file.read(), publicKey: publicKey, inAppBundle: inAppBundle)
    }

    /// Checks `text`. A valid key is written to the license file. Any other text changes nothing.
    public func activate(_ text: String) -> Outcome {
        if status == .notRequired { return .notRequired }
        guard let publicKey, let keyData = LicenseKey.publicKey(base64: publicKey),
              let license = LicenseKey.verify(text, publicKey: keyData) else { return .invalid }
        do {
            try file.write(license.key)
        } catch {
            return .saveFailed("Spool could not save the license key: \(error.localizedDescription)")
        }
        return .activated(license)
    }

    /// The answer to `spool license`.
    public func statusResponse() -> IPCResponse {
        let status = status
        return IPCResponse(ok: status.allowsStart, error: status.allowsStart ? nil : LicenseReport.notLicensedText,
                           license: LicenseReport(status))
    }

    /// The answer to `spool license <key>`, for the outcome of `activate`.
    public func response(for outcome: Outcome) -> IPCResponse {
        switch outcome {
        case .activated(let license): return IPCResponse(ok: true, license: LicenseReport(.licensed(license)))
        case .notRequired: return IPCResponse(ok: true, license: LicenseReport(.notRequired))
        case .invalid: return IPCResponse(ok: false, error: LicenseKey.invalidMessage)
        case .saveFailed(let message): return IPCResponse(ok: false, error: message)
        }
    }
}
