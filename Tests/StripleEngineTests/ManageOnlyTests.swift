import AppKit
import Testing
@testable import StripleEngine

/// The test seam `STRIPLE_MANAGE_ONLY` (docs/E2E.md): with a list, Striple never adopts a window of another app.
@Suite struct ManageOnlyTests {
    @Test func theListComesFromTheEnvironment() {
        #expect(Policy.manageOnlyBundleIDs(environment: [:]) == nil)
        #expect(Policy.manageOnlyBundleIDs(environment: ["STRIPLE_MANAGE_ONLY": ""]) == [])
        #expect(Policy.manageOnlyBundleIDs(environment: ["STRIPLE_MANAGE_ONLY": " , "]) == [])
        #expect(Policy.manageOnlyBundleIDs(environment: ["STRIPLE_MANAGE_ONLY": "com.a, com.b ,,com.c"]) == ["com.a", "com.b", "com.c"])
    }

    @Test func withoutAListEveryAppIsAllowed() {
        #expect(Policy.isAllowed(bundleID: "com.apple.Safari", manageOnly: nil))
        #expect(Policy.isAllowed(bundleID: nil, manageOnly: nil))
    }

    @Test func withAListOnlyThoseAppsAreAllowed() {
        let list: Set = ["com.fskroes.Striple.e2e-windows"]
        #expect(Policy.isAllowed(bundleID: "com.fskroes.Striple.e2e-windows", manageOnly: list))
        #expect(!Policy.isAllowed(bundleID: "com.apple.Safari", manageOnly: list))
        #expect(!Policy.isAllowed(bundleID: nil, manageOnly: list))
        // Set but empty: fail closed, manage nothing.
        #expect(!Policy.isAllowed(bundleID: "com.apple.Safari", manageOnly: []))
    }

    @Test func theGateIsPartOfIsManageableApp() {
        let list: Set = ["com.test"]
        #expect(Policy.isManageableApp(policy: .regular, pid: 100, ownPID: 1, terminated: false, bundleID: "com.test", manageOnly: list))
        #expect(!Policy.isManageableApp(policy: .regular, pid: 100, ownPID: 1, terminated: false, bundleID: "com.other", manageOnly: list))
        // The list never makes an app manageable that is not manageable without it.
        #expect(!Policy.isManageableApp(policy: .accessory, pid: 100, ownPID: 1, terminated: false, bundleID: "com.test", manageOnly: list))
    }

    @MainActor @Test func theTestProcessManagesEveryApp() {
        // `swift test` does not set STRIPLE_MANAGE_ONLY.
        #expect(WindowTracker.manageOnly == nil)
    }
}
