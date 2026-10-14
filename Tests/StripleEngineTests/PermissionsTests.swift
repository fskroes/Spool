import Testing
@testable import StripleEngine

@Suite struct PermissionsTests {
    // Reset Permission removes only Striple's own entry. `tccutil reset Accessibility` without a
    // bundle ID removes the entry of every app, so no bundle ID must give no command.
    @Test func resetNamesOnlyStriplesOwnEntry() {
        #expect(Permissions.resetArguments(bundleID: "com.fskroes.Striple") == ["reset", "Accessibility", "com.fskroes.Striple"])
        #expect(Permissions.resetArguments(bundleID: " com.fskroes.Striple\n") == ["reset", "Accessibility", "com.fskroes.Striple"])
        #expect(Permissions.resetArguments(bundleID: nil) == nil)
        #expect(Permissions.resetArguments(bundleID: "") == nil)
        #expect(Permissions.resetArguments(bundleID: "  ") == nil)
    }

    // Reset Permission asks first on an ad hoc build: a new entry for it would store cdhashes again.
    @Test func cdhashOnlyRequirementIsAdHoc() {
        #expect(Permissions.isCdhashOnly(requirement: "cdhash H\"9cba34a0\" or cdhash H\"e26922bc\""))
        #expect(Permissions.isCdhashOnly(requirement: "cdhash H\"9cba34a0\"\n"))
        #expect(!Permissions.isCdhashOnly(requirement: "identifier \"com.fskroes.Striple\" and certificate leaf = H\"75929cf2\""))
        #expect(!Permissions.isCdhashOnly(requirement: "identifier \"com.fskroes.Striple\" and anchor apple generic"))
        #expect(!Permissions.isCdhashOnly(requirement: ""))
    }

    // The Security calls work. The test host's signature depends on the toolchain, so only check that it is read.
    @Test func theProcessReadsItsOwnRequirement() throws {
        let requirement = try #require(Permissions.ownRequirement())
        #expect(!requirement.isEmpty)
    }
}

/// Runs `PermissionReset` with fakes and records what it did.
@MainActor
final class ResetRecorder {
    var events: [String] = []
    var requirement: String? = #"identifier "com.fskroes.Striple" and certificate leaf = H"75929cf2""#
    var confirmAnswer = true
    var status: Int32 = 0
    var held: (() -> Void)?
    var holdTccutil = false

    func reset() -> PermissionReset {
        PermissionReset(effects: .init(
            requirement: { self.requirement },
            confirm: { title, _, _ in self.events.append("confirm \(title)"); return self.confirmAnswer },
            alert: { title, text in self.events.append("alert \(title): \(text)") },
            tccutil: { [status] args in status },
            offMain: { work, done in
                let status = work()
                if self.holdTccutil { self.held = { done(status) } } else { done(status) }
            },
            prompt: { self.events.append("prompt") },
            openSettings: { self.events.append("openSettings") },
            log: { _ in }))
    }
}

@MainActor
struct PermissionResetTests {
    @Test func aSuccessfulResetPromptsAndOpensSettings() {
        let r = ResetRecorder()
        r.reset().run(bundleID: "com.fskroes.Striple")
        #expect(r.events == ["prompt", "openSettings"])
    }

    // A failed tccutil leaves the old entry, so a prompt would do nothing. Show the command instead.
    @Test(arguments: [Int32(1), -1])
    func aFailedResetShowsTheCommandAndDoesNotPrompt(status: Int32) {
        let r = ResetRecorder()
        r.status = status
        r.reset().run(bundleID: "com.fskroes.Striple")
        #expect(r.events.count == 1, "\(r.events)")
        #expect(r.events.first?.contains("tccutil reset Accessibility com.fskroes.Striple") == true, "\(r.events)")
        #expect(r.events.first?.contains("Request Permission in Settings > Mac Setup") == true)
        #expect(!r.events.contains("prompt"))
    }

    @Test func anAdHocBuildAsksFirstAndCancelChangesNothing() {
        let r = ResetRecorder()
        r.requirement = #"cdhash H"9cba34a0" or cdhash H"e26922bc""#
        r.confirmAnswer = false
        let reset = r.reset()
        reset.run(bundleID: "com.fskroes.Striple")
        #expect(r.events == ["confirm This build is signed ad hoc"])
        // Cancel must not leave the reset marked as running, or every later click is ignored.
        #expect(!reset.running)
        r.confirmAnswer = true
        reset.run(bundleID: "com.fskroes.Striple")
        #expect(r.events == ["confirm This build is signed ad hoc", "confirm This build is signed ad hoc", "prompt", "openSettings"])
    }

    @Test func anAdHocBuildResetsAfterConfirm() {
        let r = ResetRecorder()
        r.requirement = #"cdhash H"9cba34a0""#
        r.reset().run(bundleID: "com.fskroes.Striple")
        #expect(r.events == ["confirm This build is signed ad hoc", "prompt", "openSettings"])
    }

    @Test(arguments: [nil, "", " "] as [String?])
    func noBundleIDShowsAnAlertAndRunsNothing(bundleID: String?) {
        let r = ResetRecorder()
        r.reset().run(bundleID: bundleID)
        #expect(r.events == ["alert Striple cannot reset its permission: This copy of Striple has no bundle ID. Open Striple.app, not the bare binary."])
    }

    @Test func aSecondClickWhileTccutilRunsIsIgnored() {
        let r = ResetRecorder()
        r.holdTccutil = true
        let reset = r.reset()
        reset.run(bundleID: "com.fskroes.Striple")
        reset.run(bundleID: "com.fskroes.Striple")
        #expect(reset.running)
        #expect(r.events.isEmpty)
        r.held?()
        #expect(!reset.running)
        #expect(r.events == ["prompt", "openSettings"])
        r.holdTccutil = false
        reset.run(bundleID: "com.fskroes.Striple")
        #expect(r.events == ["prompt", "openSettings", "prompt", "openSettings"])
    }
}
