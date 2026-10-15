import AppKit
import Testing
@testable import SpoolApp
import SpoolCore

@Suite struct DockPresenceTests {
    /// A scheduled update came while Settings was open; Sparkle waits to show it. After Settings closes, only the
    /// update is left, and AppModel.windowClosed then calls Updater.showPendingUpdate. After the update alert or the
    /// update window itself closes, it does not.
    @Test func onlyTheUpdateIsLeftAfterTheLastSpoolWindowCloses() {
        var dock = DockPresence()
        _ = dock.opened("settings")
        _ = dock.opened(UpdateWindows.window)
        _ = dock.closed("settings")
        #expect(dock.onlyUpdateLeft(after: "settings"))
        #expect(!dock.onlyUpdateLeft(after: UpdateWindows.alert))
        #expect(!dock.onlyUpdateLeft(after: UpdateWindows.window))

        var two = DockPresence()
        _ = two.opened("settings")
        _ = two.opened("guide")
        _ = two.opened(UpdateWindows.window)
        _ = two.closed("settings")
        // The guide is still open: nothing to do.
        #expect(!two.onlyUpdateLeft(after: "settings"))

        var none = DockPresence()
        _ = none.opened("settings")
        _ = none.closed("settings")
        #expect(!none.onlyUpdateLeft(after: "settings"))
    }

    @Test func firstWindowShowsTheDockIconAndLastWindowHidesIt() {
        var dock = DockPresence()
        #expect(dock.policy == .accessory)
        #expect(dock.opened("settings") == .regular)
        // Settings comes to the front again, or the guide opens too: no change.
        #expect(dock.opened("settings") == nil)
        #expect(dock.opened("guide") == nil)
        // One window is still open.
        #expect(dock.closed("settings") == nil)
        #expect(dock.policy == .regular)
        #expect(dock.closed("guide") == .accessory)
        // A close without an open (a window closed twice) changes nothing.
        #expect(dock.closed("guide") == nil)
        #expect(dock.policy == .accessory)
    }

    @Test func aMinimizedWindowIsStillOpen() {
        #expect(HostedWindow.isOpen(visible: true, minimized: false))
        #expect(HostedWindow.isOpen(visible: false, minimized: true))
        #expect(!HostedWindow.isOpen(visible: false, minimized: false))
    }

    /// reopen uses hasOpenWindow to show the open windows (About too) instead of opening Settings.
    @Test func hasOpenWindowFollowsTheOpenIds() {
        var dock = DockPresence()
        #expect(!dock.hasOpenWindow)
        _ = dock.opened("about")
        #expect(dock.hasOpenWindow)
        _ = dock.closed("about")
        #expect(!dock.hasOpenWindow)
    }

    /// showAbout watches the window that the About panel added: visible now, not visible before. Not Settings,
    /// which was open already, and not a window that is not on screen.
    @Test func theAboutPanelIsTheWindowThatJustBecameVisible() {
        final class Win { let visible: Bool; init(_ visible: Bool) { self.visible = visible } }
        let settings = Win(true), hidden = Win(false), about = Win(true)
        let before: Set<ObjectIdentifier> = [ObjectIdentifier(settings)]
        #expect(AppModel.newWindow([settings, hidden, about], isVisible: \.visible, before: before) === about)
        #expect(AppModel.newWindow([settings, hidden], isVisible: \.visible, before: before) == nil)
    }
}

@MainActor @Suite struct UpdateWindowsTests {
    /// Feeds the Sparkle events through `UpdateWindows` into a `DockPresence`, as AppModel does.
    private func run(_ events: (UpdateWindows) -> Void, start: Set<String> = []) -> DockPresence {
        var dock = DockPresence()
        for id in start { _ = dock.opened(id) }
        let windows = UpdateWindows()
        windows.opened = { _ = dock.opened($0) }
        windows.closed = { _ = dock.closed($0) }
        events(windows)
        return dock
    }

    @Test func theUpdateWindowKeepsTheDockIconAfterSettingsCloses() {
        var dock = run({ $0.updateWillShow(byStandardDriver: true) }, start: ["settings"])
        _ = dock.closed("settings")
        #expect(dock.policy == .regular)
    }

    @Test func theDockIconGoesWhenTheUpdateSessionEnds() {
        let dock = run { $0.updateWillShow(byStandardDriver: true); $0.sessionWillFinish() }
        #expect(dock.policy == .accessory)
    }

    @Test func anAlertCountsWhileItIsOnScreen() {
        var shown = DockPresence()
        let windows = UpdateWindows()
        windows.opened = { _ = shown.opened($0) }
        windows.closed = { _ = shown.closed($0) }
        windows.alertWillShow()
        #expect(shown.policy == .regular)
        windows.alertDidClose()
        #expect(shown.policy == .accessory)
    }

    /// Sparkle finds the delegate methods by their Objective-C names. A renamed Swift method would fail silently.
    @Test func sparkleFindsEveryDelegateMethod() {
        let windows = UpdateWindows()
        for name in ["standardUserDriverWillHandleShowingUpdate:forUpdate:state:",
                     "standardUserDriverWillShowModalAlert",
                     "standardUserDriverDidShowModalAlert",
                     "standardUserDriverWillFinishUpdateSession"] {
            #expect(windows.responds(to: Selector(name)), "\(name)")
        }
    }

    @Test func anUpdateThatSparkleDoesNotShowOpensNothing() {
        #expect(run { $0.updateWillShow(byStandardDriver: false) }.policy == .accessory)
    }

    @Test func aSessionWithNoWindowChangesNothing() {
        #expect(run({ $0.sessionWillFinish() }, start: ["settings"]).policy == .regular)
    }
}

@Suite struct SettingsPagesTests {
    @Test func everyPageIsInTheSidebarOnce() {
        let listed = SettingsTab.sidebarGroups.flatMap { $0 }
        #expect(listed.count == SettingsTab.allCases.count)
        #expect(Set(listed) == Set(SettingsTab.allCases))
        #expect(SettingsTab.sidebarGroups.allSatisfy { !$0.isEmpty })
    }

    @Test func everyPageHasAUrl() {
        for tab in SettingsTab.allCases {
            #expect(URLRoute(URL(string: "spool://settings/\(tab.rawValue)")!) == .settings(tab))
        }
        // The page links of earlier versions still open the same page.
        let earlier: [(String, SettingsTab)] = [("general", .general), ("displays", .displays), ("rules", .rules),
                                                ("shortcuts", .shortcuts), ("mac-setup", .macSetup), ("help", .help)]
        for (name, tab) in earlier {
            #expect(URLRoute(URL(string: "spool://settings/\(name)")!) == .settings(tab), "\(name)")
        }
        // An unknown page opens the page that was shown last.
        #expect(URLRoute(URL(string: "spool://settings/nope")!) == .settings(nil))
    }

    @Test func titlesAreUnique() {
        #expect(Set(SettingsTab.allCases.map(\.title)).count == SettingsTab.allCases.count)
    }
}

@Suite struct PlaceSummaryTests {
    private let mods: KeyModifiers = [.control, .option]
    private func label(_ c: KeyCombo) -> String { c.usLabel }
    private func digits(_ m: KeyModifiers) -> [[KeyCombo]] {
        let codes = [KeyCode.one, KeyCode.two, KeyCode.three, KeyCode.four, KeyCode.five,
                     KeyCode.six, KeyCode.seven, KeyCode.eight, KeyCode.nine]
        return codes.map { [KeyCombo($0, m)] }
    }

    @Test func aFullRunShowsFirstAndLast() {
        #expect(PlaceSummary.text(digits(mods), label: label) == "⌃⌥1 to ⌃⌥9")
    }

    @Test func noShortcuts() {
        #expect(PlaceSummary.text(Array(repeating: [], count: 9), label: label) == "No shortcuts")
    }

    @Test func aGapShowsTheCount() {
        var combos = digits(mods)
        combos[4] = []
        #expect(PlaceSummary.text(combos, label: label) == "8 of 9 set")
    }

    @Test func mixedModifiersShowTheCount() {
        var combos = digits(mods)
        combos[0] = [KeyCombo(KeyCode.one, [.command, .option])]
        #expect(PlaceSummary.text(combos, label: label) == "9 of 9 set")
    }

    @Test func aKeyThatIsNotItsDigitShowsTheCount() {
        // Place 3 on ⌃⌥F: "⌃⌥1 to ⌃⌥9" would hide that.
        var combos = digits(mods)
        combos[2] = [KeyCombo(KeyCode.f, mods)]
        #expect(PlaceSummary.text(combos, label: label) == "9 of 9 set")
    }

    @Test func twoCombosOnOnePlaceShowTheCount() {
        var combos = digits(mods)
        combos[0].append(KeyCombo(KeyCode.one, [.command]))
        #expect(PlaceSummary.text(combos, label: label) == "9 of 9 set")
    }
}

@Suite struct PlaceFoldingTests {
    private let defaults = DefaultBindings.make()

    @Test func noConflictAndNoRecordingKeepsEveryGroupFolded() {
        let bindings = defaults
        #expect(PlaceFolding.groupsToOpen(bindings: bindings, conflicts: bindingConflicts(bindings), recording: nil).isEmpty)
    }

    @Test func aConflictOnAPlaceOpensItsGroupOnly() {
        var bindings = defaults
        // Move place 3 onto the key of focus-left.
        bindings[.moveToIndex(3)] = bindings[.focusLeft]
        let open = PlaceFolding.groupsToOpen(bindings: bindings, conflicts: bindingConflicts(bindings), recording: nil)
        #expect(open == [.move])
    }

    @Test func recordingAPlaceOpensItsGroup() {
        let open = PlaceFolding.groupsToOpen(bindings: defaults, conflicts: [:], recording: .focusIndex(7))
        #expect(open == [.focus])
    }

    @Test func aPlaceComboThatMacOSRefusesOpensItsGroup() {
        let refused = Set(defaults[.focusIndex(2)] ?? [])
        let open = PlaceFolding.groupsToOpen(bindings: defaults, conflicts: [:], refused: refused, recording: nil)
        #expect(open == [.focus])
        #expect(PlaceFolding.hasProblem(.focusIndex(2), bindings: defaults, conflicts: [:], refused: refused))
        #expect(!PlaceFolding.hasProblem(.focusIndex(3), bindings: defaults, conflicts: [:], refused: refused))
    }

    @Test func recordingARowThatIsNotAPlaceOpensNothing() {
        #expect(PlaceFolding.groupsToOpen(bindings: defaults, conflicts: [:], recording: .focusLeft).isEmpty)
    }

    @Test func aGroupThatMustBeOpenIsOpenAndDoesNotClose() {
        let forced = PlaceFolding.groupsToOpen(bindings: defaults, conflicts: [:], recording: .focusIndex(7))
        // Recording started, the group was not opened by hand: it shows anyway.
        #expect(PlaceFolding.isOpen(.focus, expanded: [], forced: forced))
        // A click on the triangle while it records: it stays open, so the recorder is not hidden.
        let afterClose = PlaceFolding.toggled(.focus, open: false, expanded: [.focus, .move], forced: forced)
        #expect(afterClose == [.focus, .move])
        #expect(PlaceFolding.isOpen(.focus, expanded: afterClose, forced: forced))
    }

    /// Another app can own ⌃⌥1 for good. The group opens to show it, but a click must still fold it.
    @Test func aGroupOpenedForARefusedComboClosesByHand() {
        let refused = Set(defaults[.focusIndex(2)] ?? [])
        let opens = PlaceFolding.groupsToOpen(bindings: defaults, conflicts: [:], refused: refused, recording: nil)
        let stays = PlaceFolding.groupsThatStayOpen(bindings: defaults, conflicts: [:], recording: nil)
        #expect(opens == [.focus])
        #expect(stays.isEmpty)
        let closed = PlaceFolding.toggled(.focus, open: false, expanded: opens, forced: stays)
        #expect(!PlaceFolding.isOpen(.focus, expanded: closed, forced: stays))
    }

    /// Focus place 1 has a refused combo and you closed Focus. A recording in Move, its end, or the list drawn again
    /// after a keyboard layout change or a page change must not open Focus again.
    @Test func aGroupClosedByHandStaysClosedWhenAnotherGroupChanges() {
        let refused: Set<Command> = [.focusIndex(1)]
        var expanded = PlaceFolding.opened(refused, before: [], expanded: [])
        #expect(expanded == [.focus])
        expanded = PlaceFolding.toggled(.focus, open: false, expanded: expanded, forced: [])
        #expect(expanded.isEmpty)
        expanded = PlaceFolding.opened(refused.union([.moveToIndex(4)]), before: refused, expanded: expanded)
        #expect(expanded == [.move])
        expanded = PlaceFolding.opened(refused, before: refused.union([.moveToIndex(4)]), expanded: expanded)
        #expect(expanded == [.move])
        expanded = PlaceFolding.opened(refused, before: refused, expanded: expanded)
        #expect(!expanded.contains(.focus))
        // The problem went away and came back: that is new, so the group opens again.
        expanded = PlaceFolding.opened([], before: refused, expanded: expanded)
        expanded = PlaceFolding.opened(refused, before: [], expanded: expanded)
        #expect(expanded.contains(.focus))
    }

    /// Focus place 1 has a refused combo and you closed Focus. Then place 3 gets a problem too (another app took its
    /// combo, or a conflict). That row needs you, so Focus opens, and it stays open after the conflict is solved.
    @Test func aNewProblemInAGroupThatHasOneOpensIt() {
        let bindings = defaults
        let refused = Set(bindings[.focusIndex(1)] ?? [])
        let first = PlaceFolding.placesToOpen(bindings: bindings, conflicts: [:], refused: refused, recording: nil)
        #expect(first == [.focusIndex(1)])
        var expanded = PlaceFolding.toggled(.focus, open: false,
                                            expanded: PlaceFolding.opened(first, before: [], expanded: []), forced: [])
        #expect(expanded.isEmpty)

        let alsoRefused = refused.union(bindings[.focusIndex(3)] ?? [])
        let second = PlaceFolding.placesToOpen(bindings: bindings, conflicts: [:], refused: alsoRefused, recording: nil)
        #expect(PlaceFolding.opened(second, before: first, expanded: expanded) == [.focus])

        // A conflict on place 2 (focus-left recorded as its combo) while Focus is closed.
        var clash = bindings
        clash[.focusLeft] = bindings[.focusIndex(2)]
        let third = PlaceFolding.placesToOpen(bindings: clash, conflicts: bindingConflicts(clash), refused: refused,
                                              recording: nil)
        #expect(third == [.focusIndex(1), .focusIndex(2)])
        expanded = PlaceFolding.opened(third, before: first, expanded: expanded)
        // You record a free combo for place 2: the conflict is gone, the group stays open under the pointer.
        expanded = PlaceFolding.opened([.focusIndex(1), .focusIndex(2)], before: third, expanded: expanded)
        expanded = PlaceFolding.opened(first, before: [.focusIndex(1), .focusIndex(2)], expanded: expanded)
        #expect(PlaceFolding.isOpen(.focus, expanded: expanded, forced: []))
    }

    @Test func aConflictOrARecordingKeepsTheGroupOpen() {
        var bindings = defaults
        bindings[.moveToIndex(3)] = bindings[.focusLeft]
        #expect(PlaceFolding.groupsThatStayOpen(bindings: bindings, conflicts: bindingConflicts(bindings), recording: nil) == [.move])
        #expect(PlaceFolding.groupsThatStayOpen(bindings: defaults, conflicts: [:], recording: .focusIndex(7)) == [.focus])
    }

    @Test func aGroupThatNeedsNothingOpensAndClosesByHand() {
        let opened = PlaceFolding.toggled(.move, open: true, expanded: [], forced: [])
        #expect(opened == [.move])
        #expect(PlaceFolding.isOpen(.move, expanded: opened, forced: []))
        let closed = PlaceFolding.toggled(.move, open: false, expanded: opened, forced: [.focus])
        #expect(closed.isEmpty)
        #expect(!PlaceFolding.isOpen(.move, expanded: closed, forced: [.focus]))
    }
}

/// The menu bar that Spool shows while one of its windows is open. Each item must call the right action, with
/// the standard key, and Check for Updates must be off when Sparkle cannot check.
@MainActor @Suite struct MainMenuTests {
    private final class Stub: NSObject, MainMenuActions {
        func showAbout() {}
        func checkForUpdates() {}
        func openSettings() {}
        func openHelp() {}
        func openGuide() {}
        func openMacSetup() {}
        func openConfig() {}
        func revealLog() {}
    }

    private func installed() -> (menu: NSMenu, stub: Stub) {
        let app = NSApplication.shared
        let before = app.mainMenu
        let stub = Stub()
        MainMenu.install(target: stub)
        let menu = app.mainMenu!
        app.mainMenu = before
        return (menu, stub)
    }

    private func item(_ menu: NSMenu, _ top: String, _ title: String) -> NSMenuItem? {
        menu.items.first { $0.title == top }?.submenu?.items.first { $0.title == title }
    }

    @Test func theMenusAreInTheStandardOrder() {
        let (menu, _) = installed()
        #expect(menu.items.map(\.title) == ["Spool", "Edit", "Window", "Help"])
        #expect(NSApplication.shared.windowsMenu === menu.items[2].submenu)
        #expect(NSApplication.shared.helpMenu === menu.items[3].submenu)
    }

    @Test func everySpoolItemCallsItsAction() {
        let (menu, stub) = installed()
        let expected: [(String, String, Selector, String)] = [
            ("Spool", "About Spool", #selector(MainMenuActions.showAbout), ""),
            ("Spool", "Check for Updates…", #selector(MainMenuActions.checkForUpdates), ""),
            ("Spool", "Settings…", #selector(MainMenuActions.openSettings), ","),
            ("Help", "Spool Help", #selector(MainMenuActions.openHelp), "?"),
            ("Help", "Show the Guide", #selector(MainMenuActions.openGuide), ""),
            ("Help", "Mac Setup…", #selector(MainMenuActions.openMacSetup), ""),
            ("Help", "Open Configuration File", #selector(MainMenuActions.openConfig), ""),
            ("Help", "Reveal Engine Log", #selector(MainMenuActions.revealLog), ""),
        ]
        for (top, title, action, key) in expected {
            let found = item(menu, top, title)
            #expect(found?.action == action, "\(title)")
            #expect(found?.target === stub, "\(title)")
            #expect(found?.keyEquivalent == key, "\(title)")
            #expect(AppDelegate.instancesRespond(to: action), "\(title)")
        }
    }

    @Test func theStandardItemsGoToAppKit() {
        let (menu, _) = installed()
        let expected: [(String, String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Spool", "Hide Spool", #selector(NSApplication.hide(_:)), "h", .command),
            ("Spool", "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            ("Spool", "Quit Spool", #selector(NSApplication.terminate(_:)), "q", .command),
            ("Edit", "Copy", #selector(NSText.copy(_:)), "c", .command),
            ("Edit", "Paste", #selector(NSText.paste(_:)), "v", .command),
            ("Edit", "Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Window", "Close", #selector(NSWindow.performClose(_:)), "w", .command),
            ("Window", "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", .command),
        ]
        for (top, title, action, key, mods) in expected {
            let found = item(menu, top, title)
            #expect(found?.action == action, "\(title)")
            #expect(found?.target == nil, "\(title) goes up the responder chain")
            #expect(found?.keyEquivalent == key, "\(title)")
            #expect(found?.keyEquivalentModifierMask == mods, "\(title)")
        }
    }

    /// A test run has no updater, as a build without a feed: Check for Updates is off, the other items are on.
    @Test func checkForUpdatesIsOffWithoutAnUpdater() {
        let (menu, _) = installed()
        let delegate = AppDelegate()
        #expect(!Updater.shared.canCheckForUpdates)
        #expect(!delegate.validateMenuItem(item(menu, "Spool", "Check for Updates…")!))
        #expect(delegate.validateMenuItem(item(menu, "Spool", "Settings…")!))
    }
}
