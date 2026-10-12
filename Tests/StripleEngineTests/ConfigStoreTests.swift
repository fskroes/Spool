import Foundation
import Testing
@testable import StripleCore
@testable import StripleEngine

@MainActor
@Suite struct ConfigStoreTests {
    private func tempFile() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    @Test func firstRunWritesDefaults() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        #expect(store.config == Config())
        #expect(try Config.decode(Data(contentsOf: url)) == Config())
    }

    @Test func updateSavesAndRoundTrips() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        store.update { $0.layout.innerGap = 20; $0.appearance.focusBorder = true }
        let again = ConfigStore(fileURL: url, watch: false)
        #expect(again.config.layout.innerGap == 20)
        #expect(again.config.appearance.focusBorder)
    }

    @Test func externalEditIsLoaded() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        var c = store.config
        c.behavior.focusFollowsMouse = true
        try c.encoded().write(to: url)
        store.reload()
        #expect(store.config.behavior.focusFollowsMouse)
        #expect(store.loadError == nil)
    }

    @Test func brokenFileKeepsTheLastGoodConfig() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        store.update { $0.layout.innerGap = 12 }
        try Data("{ not json".utf8).write(to: url)
        store.reload()
        #expect(store.config.layout.innerGap == 12)
        #expect(store.loadError != nil)
        // Fixing the file clears the error.
        var c = store.config
        c.layout.innerGap = 14
        try c.encoded().write(to: url)
        store.reload()
        #expect(store.loadError == nil)
        #expect(store.config.layout.innerGap == 14)
    }

    @Test func resetAllKeepsOnboardingDone() {
        let store = ConfigStore(fileURL: tempFile(), watch: false)
        store.update { $0.behavior.onboardingDone = true; $0.layout.innerGap = 30 }
        store.resetAll()
        #expect(store.config.behavior.onboardingDone)
        #expect(store.config.layout.innerGap == Config().layout.innerGap)
    }

    // Round 5 finding: a bad combo reset all shortcuts, and the next save wrote the loss to the user's file.
    @Test func aBadComboKeepsTheLastGoodConfigAndTheUsersFile() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        store.update { $0.bindings[.focusLeft] = [KeyCombo(KeyCode.h, [.command, .option])] }
        let mine = store.config.bindings
        let broken = #"{"version":2,"bindings":{"focus-left":[{"key":4,"mods":["ctrl","hyper"]}]}}"#
        try Data(broken.utf8).write(to: url)
        store.reload()
        #expect(store.config.bindings == mine)
        #expect(store.loadError?.contains("bindings.focus-left[0].mods") == true)
        #expect(store.loadError?.contains("hyper") == true)

        // A setting changes before the user fixes the file: the user's file is kept next to the saved one.
        store.update { $0.behavior.focusFollowsMouse = true }
        #expect(try String(contentsOf: store.brokenCopyURL, encoding: .utf8) == broken)
        #expect(try Config.decode(Data(contentsOf: url)).bindings == mine)
        #expect(store.loadError?.contains("config.json.broken") == true)

        // A later save does not touch the copy again.
        store.update { $0.behavior.focusFollowsMouse = false }
        #expect(try String(contentsOf: store.brokenCopyURL, encoding: .utf8) == broken)
    }

    // Round 5 finding: a version 1 file was migrated again on every load, so a combo added back by hand vanished.
    @Test func aMigratedFileIsSavedOnceAsTheCurrentVersion() throws {
        let url = tempFile()
        var old = Config()
        old.version = 1
        try old.encoded().write(to: url)
        let store = ConfigStore(fileURL: url, watch: false)
        #expect(Config.fileVersion(try Data(contentsOf: url)) == Config.currentVersion)

        // The user adds ⌃⌥⇧← back by hand (after freeing it in System Settings). It stays.
        let left = KeyCombo(KeyCode.left, [.control, .option, .shift])
        var mine = store.config
        mine.bindings[.moveLeft] = [left]
        try mine.encoded().write(to: url)
        store.reload()
        #expect(store.config.bindings[.moveLeft] == [left])
    }

    // Round 6 finding: a broken file at launch gave factory settings, and the first automatic save wrote them.
    @Test func aBrokenFileAtLaunchStartsWithTheLastGoodSettings() throws {
        let url = tempFile()
        let first = ConfigStore(fileURL: url, watch: false)
        first.update { $0.layout.innerGap = 13; $0.behavior.onboardingDone = true }
        let broken = #"{"version":2,"bindings":{"focus-left":[{"key":4,"mods":["hyper"]}]}}"#
        try Data(broken.utf8).write(to: url)

        let store = ConfigStore(fileURL: url, watch: false)
        #expect(store.fileHasError)
        #expect(store.config.layout.innerGap == 13)
        #expect(store.config.behavior.onboardingDone)
        #expect(store.loadError?.contains("bindings.focus-left[0].mods") == true)
        #expect(try String(contentsOf: url, encoding: .utf8) == broken)

        // A change by the user keeps the file as .broken, and the message still tells what was wrong.
        store.update { $0.behavior.focusFollowsMouse = true }
        #expect(!store.fileHasError)
        #expect(try String(contentsOf: store.brokenCopyURL, encoding: .utf8) == broken)
        let saved = try Config.decode(Data(contentsOf: url))
        #expect(saved.layout.innerGap == 13 && saved.behavior.focusFollowsMouse)
        #expect(store.loadError?.contains("bindings.focus-left[0].mods") == true)
        #expect(store.loadError?.contains("config.json.broken") == true)
    }

    @Test func aBrokenFileWithNoLastGoodCopyStartsWithTheFactorySettings() throws {
        let url = tempFile()
        try Data("{ not json".utf8).write(to: url)
        let store = ConfigStore(fileURL: url, watch: false)
        #expect(store.fileHasError)
        #expect(store.config == Config())
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }

    // Round 6 finding: after a broken file was deleted, every save failed on the copy step.
    @Test func aDeletedBrokenFileIsWrittenAgainOnTheNextSave() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        try Data("{ not json".utf8).write(to: url)
        store.reload()
        #expect(store.fileHasError)
        try FileManager.default.removeItem(at: url)
        store.reload()
        #expect(!store.fileHasError)
        #expect(store.loadError == nil)

        store.update { $0.layout.innerGap = 21 }
        #expect(store.loadError == nil)
        #expect(try Config.decode(Data(contentsOf: url)).layout.innerGap == 21)
        #expect(!FileManager.default.fileExists(atPath: store.brokenCopyURL.path))
    }

    // Round 7 finding: a broken file deleted while Striple ran gave factory settings at the next launch.
    @Test func aDeletedBrokenFileIsWrittenWithTheSettingsInUse() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        store.update { $0.layout.innerGap = 19 }
        try Data("{ not json".utf8).write(to: url)
        store.reload()
        try FileManager.default.removeItem(at: url)
        store.reload()
        #expect(try Config.decode(Data(contentsOf: url)).layout.innerGap == 19)

        let next = ConfigStore(fileURL: url, watch: false)
        #expect(next.config.layout.innerGap == 19)
        #expect(try Config.decode(Data(contentsOf: next.lastGoodURL)).layout.innerGap == 19)
    }

    // Round 7 finding: the menu said "Problem With config.json" after a save had fixed the file.
    @Test func theNoteAboutTheCopyIsNotAProblem() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        #expect(!store.hasProblem)
        try Data("{ not json".utf8).write(to: url)
        store.reload()
        #expect(store.hasProblem)
        store.dismissNote()
        #expect(store.loadError != nil)

        store.update { $0.layout.innerGap = 3 }
        #expect(!store.hasProblem)
        #expect(store.loadError?.contains("config.json.broken") == true)
        store.dismissNote()
        #expect(store.loadError == nil)
    }

    private func writeInPlace(_ data: Data, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: 0)
        try h.write(contentsOf: data)
        try h.close()
    }

    // Round 8 finding: a folder watch does not see a file written in place (nano, `jq … > config.json`).
    @Test func anEditWrittenInPlaceIsLoaded() async throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: true)
        var c = store.config
        c.layout.innerGap = 27
        try writeInPlace(c.encoded(), to: url)
        for _ in 0..<40 where store.config.layout.innerGap != 27 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(store.config.layout.innerGap == 27)

        // After an atomic save (a new file), in-place edits are still seen.
        store.update { $0.layout.innerGap = 5 }
        try await Task.sleep(nanoseconds: 300_000_000)
        c = store.config
        c.layout.innerGap = 28
        try writeInPlace(c.encoded(), to: url)
        for _ in 0..<40 where store.config.layout.innerGap != 28 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(store.config.layout.innerGap == 28)
    }

    @Test func aChangeInSettingsKeepsAnEditThatWasNotLoadedYet() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        var c = store.config
        c.rules = [AppRule(bundleID: "com.apple.Notes", appName: "Notes", action: .float)]
        try writeInPlace(c.encoded(), to: url)

        store.update { $0.behavior.focusFollowsMouse = true }
        let saved = try Config.decode(Data(contentsOf: url))
        #expect(saved.rules.map(\.bundleID) == ["com.apple.Notes"])
        #expect(saved.behavior.focusFollowsMouse)
    }

    // Round 8 finding: a launch with config.json missing wrote factory settings over config.json.lastgood.
    @Test func aMissingFileAtLaunchIsWrittenFromTheLastGoodCopy() throws {
        let url = tempFile()
        ConfigStore(fileURL: url, watch: false).update { $0.layout.innerGap = 15; $0.behavior.onboardingDone = true }
        try FileManager.default.removeItem(at: url)

        let store = ConfigStore(fileURL: url, watch: false)
        #expect(store.config.layout.innerGap == 15)
        #expect(store.config.behavior.onboardingDone)
        #expect(try Config.decode(Data(contentsOf: url)).layout.innerGap == 15)
        #expect(try Config.decode(Data(contentsOf: store.lastGoodURL)).layout.innerGap == 15)

        // Both files deleted: the factory settings.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.removeItem(at: store.lastGoodURL)
        #expect(ConfigStore(fileURL: url, watch: false).config == Config())
    }

    // Round 9 finding: an atomic save replaced a symlinked config.json (a dotfiles repo) with a plain file.
    @Test func aSymlinkedFileStaysALinkAndItsTargetIsSaved() async throws {
        let url = tempFile()
        let dotfiles = url.deletingLastPathComponent().appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("striple.json")
        var c = Config()
        c.layout.innerGap = 21
        try c.encoded().write(to: target)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "dotfiles/striple.json")

        let store = ConfigStore(fileURL: url, watch: true)
        #expect(store.config.layout.innerGap == 21)
        store.update { $0.layout.innerGap = 22 }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == "dotfiles/striple.json")
        #expect(try Config.decode(Data(contentsOf: target)).layout.innerGap == 22)

        // An editor saves the target atomically, twice: both edits load (the watch follows the new file).
        for gap in [23.0, 24.0] {
            try await Task.sleep(nanoseconds: 300_000_000)
            c.layout.innerGap = gap
            try c.encoded().write(to: target, options: .atomic)
            for _ in 0..<40 where store.config.layout.innerGap != gap { try await Task.sleep(nanoseconds: 50_000_000) }
            #expect(store.config.layout.innerGap == gap)
        }
        #expect(ConfigStore.writeTarget(of: url).standardizedFileURL.path == target.standardizedFileURL.path)
    }

    // Round 10 finding: `..` in a relative link was resolved as text, so with a folder reached through a link
    // (~/.config -> ~/dotfiles/config) the save went to a stray file and the next change undid the last one.
    @Test func aRelativeLinkInALinkedFolderSavesToTheRealFile() throws {
        let root = tempFile().deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("dotfiles/config/striple"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("dotfiles/hosts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("home/.config").path, withDestinationPath: "../dotfiles/config")
        let real = root.appendingPathComponent("dotfiles/hosts/striple.json")
        var c = Config()
        c.layout.innerGap = 21
        try c.encoded().write(to: real)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("dotfiles/config/striple/config.json").path,
                                  withDestinationPath: "../../hosts/striple.json")

        let url = root.appendingPathComponent("home/.config/striple/config.json")
        let store = ConfigStore(fileURL: url, watch: false)
        #expect(store.config.layout.innerGap == 21)
        store.update { $0.layout.innerGap = 30 }
        store.update { $0.behavior.focusFollowsMouse = true }
        #expect(store.config.layout.innerGap == 30)
        let saved = try Config.decode(Data(contentsOf: real))
        #expect(saved.layout.innerGap == 30 && saved.behavior.focusFollowsMouse)
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("home/hosts").path))
    }

    // Round 10 finding: an atomic save replaced a read-only file in a writable folder without a message.
    @Test func aReadOnlyFileIsNotReplaced() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        store.update { $0.layout.innerGap = 11 }
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        store.update { $0.layout.innerGap = 12 }
        #expect(try Data(contentsOf: url) == before)
        #expect(store.hasProblem)
        #expect(store.loadError?.hasPrefix("Could not save config.json") == true)
        #expect(store.config.layout.innerGap == 12)
    }

    // Round 10 finding: an automatic change checked for a broken file before the read that found it.
    @Test func anAutomaticChangeDoesNotSaveOverABrokenEditNotLoadedYet() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        let broken = Data(#"{"version":2,"bindings":{"focus-left":[{"key":4,"mods":["hyper"]}]}}"#.utf8)
        try broken.write(to: url)
        #expect(!store.fileHasError)

        store.update(automatic: true) { $0.behavior.launchAtLogin.toggle() }
        #expect(try Data(contentsOf: url) == broken)
        #expect(store.fileHasError)
        #expect(!FileManager.default.fileExists(atPath: store.brokenCopyURL.path))
    }

    // Round 9 finding: after a failed save, the next change reloaded the old file and undid the unsaved change.
    @Test func aFailedSaveDoesNotLoseTheChangeAtTheNextChange() throws {
        let url = tempFile()
        let dir = url.deletingLastPathComponent()
        let store = ConfigStore(fileURL: url, watch: false)
        store.update { $0.layout.innerGap = 11 }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        store.update { $0.behavior.focusFollowsMouse = true }
        #expect(store.hasProblem)
        store.update { $0.layout.innerGap = 12 }
        #expect(store.config.behavior.focusFollowsMouse)
        #expect(store.config.layout.innerGap == 12)
    }

    @Test func anOldBrokenCopyIsReplacedByTheNewOne() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        for text in ["{ first", "{ second"] {
            try Data(text.utf8).write(to: url)
            store.reload()
            store.update { $0.layout.innerGap += 1 }
            #expect(try String(contentsOf: store.brokenCopyURL, encoding: .utf8) == text)
        }
    }

    // Round 6 finding: on macOS 13 and 14 a version 1 file was saved as version 2, so the migration never ran later.
    @Test func aVersion1FileStaysVersion1UntilTheSystemTakesTheArrows() throws {
        let url = tempFile()
        let left = KeyCombo(KeyCode.left, [.control, .option, .shift])
        var old = Config()
        old.version = 1
        old.bindings[.moveLeft] = [left]
        let data = try old.encoded()
        try data.write(to: url)

        let onSonoma = ConfigStore(fileURL: url, watch: false, arrowsTaken: false)
        #expect(try Data(contentsOf: url) == data)
        onSonoma.update { $0.layout.innerGap = 17 }
        #expect(Config.fileVersion(try Data(contentsOf: url)) == 1)
        #expect(onSonoma.config.bindings[.moveLeft] == [left])

        let onSequoia = ConfigStore(fileURL: url, watch: false, arrowsTaken: true)
        #expect(onSequoia.config.bindings[.moveLeft]?.contains(left) == false)
        #expect(onSequoia.config.layout.innerGap == 17)
        #expect(Config.fileVersion(try Data(contentsOf: url)) == Config.currentVersion)
    }

    @Test func aFileWithoutAVersionIsNotRewritten() throws {
        let url = tempFile()
        let json = Data(#"{"layout":{"innerGap":9}}"#.utf8)
        try json.write(to: url)
        let store = ConfigStore(fileURL: url, watch: false)
        #expect(store.config.layout.innerGap == 9)
        #expect(try Data(contentsOf: url) == json)
    }
}
