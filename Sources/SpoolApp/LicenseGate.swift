import Foundation
import Security
import SwiftUI
import SpoolCore

/// The license of this copy of Spool, for the app. The rules live in `LicenseKeeper` (SpoolCore).
@MainActor
final class LicenseGate: ObservableObject {
    let keeper: LicenseKeeper
    @Published private(set) var status: LicenseStatus
    /// The text under the paste field: the last key that failed. Nil after a success.
    @Published var error: String?

    init(keeper: LicenseKeeper = LicenseGate.appKeeper()) {
        self.keeper = keeper
        status = keeper.status
    }

    /// Reads `SpoolLicensePublicKey` from Info.plist and the bundle type of the running process.
    nonisolated static func appKeeper(bundle: Bundle = .main) -> LicenseKeeper {
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        // The E2E build (`make e2e`, SPOOL_E2E) is signed ad hoc and has the public test key. release.sh,
        // install.sh and make-dmg.sh refuse an app with that key.
        #if SPOOL_E2E
        let signed = true
        #else
        let signed = debugBuild || isSigned(bundle, byTeam: LicenseKeeper.releaseTeam)
        #endif
        return LicenseKeeper(publicKey: LicenseKeeper.trustedPublicKey(info: bundle.infoDictionary, signedByReleaseTeam: signed),
                             inAppBundle: LicenseKeeper.needsLicense(debugBuild: debugBuild,
                                                                     bundleIdentifier: bundle.bundleIdentifier))
    }

    /// True when the bundle on disk has a valid signature of an Apple certificate of `team`. An edited
    /// Info.plist or binary breaks the signature; a copy signed again (ad hoc, or by someone else) has no
    /// certificate of the team.
    nonisolated static func isSigned(_ bundle: Bundle, byTeam team: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = LicenseKeeper.trustRequirement(team: team) as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    var allowsStart: Bool { status.allowsStart }

    /// Reads the key file again, then answers. The engine asks before every start, so a key that was
    /// removed while Spool runs stops the next start.
    func checkBeforeStart() -> Bool {
        let now = keeper.status
        if now != status { status = now }
        return now.allowsStart
    }

    /// The email of the license, for the Settings line. Nil when there is none.
    var licensedEmail: String? {
        if case .licensed(let license) = status { return license.email }
        return nil
    }

    /// Checks and stores `text`. Updates `status` and `error`.
    func activate(_ text: String) -> LicenseKeeper.Outcome {
        let outcome = keeper.activate(text)
        switch outcome {
        case .activated, .notRequired: error = nil
        case .invalid: error = LicenseKey.invalidMessage
        case .saveFailed(let message): error = message
        }
        status = keeper.status
        return outcome
    }
}
