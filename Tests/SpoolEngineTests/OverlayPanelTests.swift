import AppKit
import Testing
import SpoolCore
@testable import SpoolEngine

/// Spool has a Hide command while Settings is open. Hiding the app must not hide what Spool draws on the strip.
@MainActor
@Suite struct OverlayPanelTests {
    @Test func overlaysStayWhenSpoolIsHidden() {
        #expect(!Overlays.makePanel().canHide)
        #expect(!Overlays.makePanel(clickThrough: false, level: .floating).canHide)
        #expect(!Overlays.makePanel().hidesOnDeactivate)
    }

    /// A sheet (App Rules' app picker, the Reset All Shortcuts dialog) or a child window is in front of Settings.
    /// The dim must go below Settings, not between it and Settings.
    @Test func aChildWindowCountsAsTheWindowItBelongsTo() {
        let settings = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                                backing: .buffered, defer: true)
        let child = NSWindow(contentRect: .init(x: 0, y: 0, width: 50, height: 50), styleMask: [.titled],
                             backing: .buffered, defer: true)
        let grandchild = NSWindow(contentRect: .init(x: 0, y: 0, width: 20, height: 20), styleMask: [.titled],
                                  backing: .buffered, defer: true)
        settings.addChildWindow(child, ordered: .above)
        child.addChildWindow(grandchild, ordered: .above)
        defer {
            child.removeChildWindow(grandchild)
            settings.removeChildWindow(child)
        }
        #expect(Overlays.topLevel(grandchild) === settings)
        #expect(Overlays.topLevel(child) === settings)
        #expect(Overlays.topLevel(settings) === settings)
    }

    @Test func aSheetCountsAsTheWindowItBelongsTo() {
        let settings = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                                backing: .buffered, defer: true)
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 50, height: 50), styleMask: [.titled],
                             backing: .buffered, defer: true)
        settings.beginSheet(sheet)
        defer { settings.endSheet(sheet) }
        #expect(sheet.sheetParent === settings)
        #expect(Overlays.topLevel(sheet) === settings)
    }
}

/// While Spool is active (Settings in front), the dimming must not cover Settings. Before, a display without the
/// focused window, or every display when no window had the focus, got its dim panel on top of all, Settings too.
@Suite struct DimOrderTests {
    @Test func theDisplayOfTheFocusedWindowIsDimmedBelowThatWindow() {
        let focused: (window: WindowID, display: String) = (7, "A")
        #expect(Overlays.dimOrder(display: "A", focused: focused, ownBack: nil) == .below(7))
        // Settings in front does not change it: the focused window is below Settings already.
        #expect(Overlays.dimOrder(display: "A", focused: focused, ownBack: 99) == .below(7))
    }

    @Test func anotherDisplayIsDimmedBelowSettingsWhileSpoolIsActive() {
        let focused: (window: WindowID, display: String) = (7, "A")
        #expect(Overlays.dimOrder(display: "B", focused: focused, ownBack: 99) == .below(99))
        #expect(Overlays.dimOrder(display: "B", focused: nil, ownBack: 99) == .below(99))
    }

    @Test func withSpoolInTheBackTheDimGoesOnTop() {
        let focused: (window: WindowID, display: String) = (7, "A")
        #expect(Overlays.dimOrder(display: "B", focused: focused, ownBack: nil) == .front)
        #expect(Overlays.dimOrder(display: "A", focused: nil, ownBack: nil) == .front)
    }
}

/// Which Spool window the dim goes below while Spool is active. Windows are front to back.
@Suite struct BackmostOwnWindowTests {
    private func win(_ number: Int, top: Int? = nil, visible: Bool = true, normal: Bool = true) -> Overlays.OwnWindow {
        Overlays.OwnWindow(number: number, top: top ?? number, visible: visible, normal: normal)
    }

    /// The guide or About in front of Settings: the dim goes below Settings, not between the two.
    @Test func theDimGoesBelowTheBackmostSpoolWindow() {
        let guide = win(20), settings = win(10)
        #expect(Overlays.backmostOwnWindow([guide, settings], overlays: []) == 10)
    }

    /// The dim, border, minimap and tab bar panels are Spool windows too; they never count.
    @Test func overlaysDoNotCount() {
        #expect(Overlays.backmostOwnWindow([win(10), win(5)], overlays: [5]) == 10)
        #expect(Overlays.backmostOwnWindow([win(5)], overlays: [5]) == nil)
    }

    /// The colour panel floats and the status item is at the status bar level: not at the normal level.
    @Test func windowsAboveTheNormalLevelDoNotCount() {
        let colourPanel = win(30, normal: false), settings = win(10), statusItem = win(3, normal: false)
        #expect(Overlays.backmostOwnWindow([colourPanel, settings, statusItem], overlays: []) == 10)
    }

    /// A sheet counts as Settings, also when it is the backmost entry of a group.
    @Test func aSheetCountsAsItsWindow() {
        #expect(Overlays.backmostOwnWindow([win(40, top: 10)], overlays: []) == 10)
        #expect(Overlays.backmostOwnWindow([win(20), win(40, top: 10), win(10)], overlays: []) == 10)
    }

    /// A minimized or closed window is not on screen.
    @Test func hiddenWindowsDoNotCount() {
        #expect(Overlays.backmostOwnWindow([win(10), win(11, visible: false)], overlays: []) == 10)
        #expect(Overlays.backmostOwnWindow([win(11, visible: false)], overlays: []) == nil)
    }

    /// A click on Settings brings only Settings forward. The windows to bring along are back to front, so the
    /// window you clicked comes last and stays in front.
    @Test func theWindowsToRaiseAreBackToFront() {
        let settings = win(10), about = win(30), guide = win(20)
        #expect(Overlays.ownWindowsBackToFront([settings, about, guide], overlays: []) == [20, 30, 10])
    }

    /// A sheet and its window are raised once, as the window; overlays, hidden and floating windows not at all.
    @Test func eachWindowIsRaisedOnceAndOnlyNormalOnScreenWindows() {
        let windows = [win(40, top: 10), win(10), win(5), win(11, visible: false), win(30, normal: false), win(20)]
        #expect(Overlays.ownWindowsBackToFront(windows, overlays: [5]) == [20, 10])
    }

    /// Without the dimming nothing needs the raise, so a click on one Spool window raises only that window, as
    /// macOS does. When Spool is not active, another app is in front and its order counts.
    @Test func theOtherWindowsComeAlongOnlyWhileActiveWithTheDimmingOn() {
        #expect(Overlays.raisesOwnWindows(active: true, dimming: true))
        #expect(!Overlays.raisesOwnWindows(active: true, dimming: false))
        #expect(!Overlays.raisesOwnWindows(active: false, dimming: true))
    }

    /// Only the change from off to on raises; a change of another appearance setting does not.
    @Test func onlyTurningTheDimmingOnRaises() {
        #expect(Overlays.dimmingTurnedOn(was: false, now: true))
        #expect(!Overlays.dimmingTurnedOn(was: true, now: true))
        #expect(!Overlays.dimmingTurnedOn(was: true, now: false))
        #expect(!Overlays.dimmingTurnedOn(was: false, now: false))
    }
}
