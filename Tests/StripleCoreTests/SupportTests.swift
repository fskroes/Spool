import CoreGraphics
import Foundation
import Testing
@testable import StripleCore

@Suite struct ConfigTests {
    @Test func roundTrip() throws {
        var c = Config()
        c.layout.innerGap = 14
        c.disabledDisplays = ["ABC"]
        c.rules = [AppRule(bundleID: "com.apple.calculator", appName: "Calculator", action: .float),
                   AppRule(bundleID: "com.apple.Terminal", appName: "Terminal", action: .slot(2))]
        c.bindings[.focusLeft] = [KeyCombo(KeyCode.a, [.command, .shift])]
        let back = try Config.decode(c.encoded())
        #expect(back == c)
    }

    @Test func emptyAndPartialFilesUseDefaults() throws {
        #expect(try Config.decode(Data("{}".utf8)) == Config())
        let partial = try Config.decode(Data(#"{"layout":{"innerGap":20},"appearance":{"focusBorder":true}}"#.utf8))
        #expect(partial.layout.innerGap == 20)
        #expect(partial.layout.outerGaps == EdgeGaps())
        #expect(partial.appearance.focusBorder)
        #expect(partial.appearance.minimap)
        #expect(partial.bindings == DefaultBindings.make())
    }

    @Test func wrongTypeFallsBackPerField() throws {
        let c = try Config.decode(Data(#"{"layout":{"innerGap":"wide","defaultWidth":0.4}}"#.utf8))
        #expect(c.layout.innerGap == LayoutSettings().innerGap)
        #expect(c.layout.defaultWidth == 0.4)
    }

    @Test func unknownCommandsInBindingsAreSkipped() throws {
        let json = #"{"bindings":{"focus-left":[{"key":4,"mods":["ctrl","opt"]}],"warp-drive":[{"key":1,"mods":[]}]}}"#
        let c = try Config.decode(Data(json.utf8))
        #expect(c.bindings[.focusLeft] == [KeyCombo(4, [.control, .option])])
        // The commands that are not in the file get their defaults (see Config.migrate).
        #expect(Set(c.bindings.keys) == Set(DefaultBindings.make().keys))
        #expect(c.bindings[.focusRight] == DefaultBindings.make()[.focusRight])
    }

    // Round 5 finding: one bad combo or rule silently replaced every shortcut or every rule with the defaults.
    @Test func aBadEntryIsAnErrorNotASilentReset() {
        let badMod = #"{"bindings":{"focus-left":[{"key":4,"mods":["ctrl","hyper"]}],"focus-right":[{"key":5,"mods":["ctrl"]}]}}"#
        #expect(throws: DecodingError.self) { try Config.decode(Data(badMod.utf8)) }
        let badRule = #"{"rules":[{"bundleID":"a","appName":"A","action":{"float":{}}},{"bundleID":"b","appName":"B"}]}"#
        #expect(throws: DecodingError.self) { try Config.decode(Data(badRule.utf8)) }
        let badDisplays = #"{"disabledDisplays":"UUID-1"}"#
        #expect(throws: DecodingError.self) { try Config.decode(Data(badDisplays.utf8)) }
        // The good forms still load.
        let good = #"{"rules":[{"bundleID":"a","appName":"A","action":{"float":{}}}],"disabledDisplays":["UUID-1"]}"#
        let c = try? Config.decode(Data(good.utf8))
        #expect(c?.rules.map(\.bundleID) == ["a"])
        #expect(c?.disabledDisplays == ["UUID-1"])
    }

    private func w(_ id: WindowID, _ app: String, _ title: String = "") -> WindowInfo {
        WindowInfo(id: id, pid: 1, bundleID: app, title: title)
    }

    private func oneStrip(_ infos: [WindowInfo], space: UInt64 = 1) -> SessionStrip {
        var strip = Strip()
        for (i, info) in infos.enumerated() { strip.insert(info, width: .proportion(Double(i + 1) / 10), slot: i + 1, focus: false) }
        return SessionStrip(displayID: "D", spaceID: space, strip: strip)
    }

    // Round 6 finding: an app that did not answer during a restore lost the saved places of its windows.
    // Round 7 finding: a slot number went wrong when the restore dropped a closed window before it.
    @Test func aWindowOfAnAppThatDoesNotAnswerGoesBackAfterTheSameNeighbour() {
        // Safari, Mail (not running), Xcode (does not answer), Notes.
        let s = Session(strips: [oneStrip([w(1, "safari"), w(2, "mail"), w(3, "xcode"), w(4, "notes")])])
        let r = s.restore(live: [w(11, "safari"), w(14, "notes")], waitingFor: ["xcode"])
        #expect(r.strips[0].strip.allWindows.map(\.id) == [11, 14])
        #expect(r.held.map(\.info.id) == [3])
        #expect(r.held[0].after == [11])
        #expect(r.held[0].width == .proportion(0.3))
        var strip = r.strips[0].strip
        strip.insert(w(33, "xcode"), width: r.held[0].width, slot: r.held[0].slot(in: strip), focus: false)
        #expect(strip.allWindows.map(\.id) == [11, 33, 14])
    }

    @Test func heldWindowsInARowKeepTheirOrder() {
        // x1, a, x2 (stacked with b), x3, d. Only x does not answer.
        var saved = oneStrip([w(1, "x"), w(2, "a"), w(3, "x"), w(5, "x"), w(6, "d")])
        saved.strip.columns[2].windows.insert(w(4, "b"), at: 0)
        saved.strip.columns[2].heights = [0.5, 0.5]
        let s = Session(strips: [saved, oneStrip([w(7, "x")], space: 2)])
        let r = s.restore(live: [w(2, "a"), w(4, "b"), w(6, "d")], waitingFor: ["x"])

        #expect(r.strips.map(\.spaceID) == [1])
        #expect(r.held.map(\.info.id) == [1, 3, 5, 7])
        #expect(r.held.map(\.after) == [[], [4, 2, 1], [3, 4, 2, 1], []])

        // The windows come back with new IDs, in held order. Each new ID is passed on to the later ones.
        var held = r.held
        var strip = r.strips[0].strip
        for (old, new) in [(WindowID(1), WindowID(21)), (3, 23), (5, 25)] {
            let h = held.first { $0.info.id == old }!
            strip.insert(w(new, "x"), width: h.width, slot: h.slot(in: strip), focus: false)
            held.removeAll { $0.info.id == old }
            HeldWindow.rename(&held, from: old, to: new)
        }
        #expect(strip.allWindows.map(\.id) == [21, 2, 4, 23, 25, 6])
    }

    // Round 8 finding: the engine takes a whole batch first, so a rename after each placement did not reach the
    // other pairs of the batch, and windows of one app that sat next to each other came back in reverse order.
    @Test func aBatchOfHeldWindowsWithNewIDsKeepsItsOrder() {
        let s = Session(strips: [oneStrip([w(1, "a"), w(2, "x"), w(3, "x"), w(4, "b")])])
        let r = s.restore(live: [w(1, "a"), w(4, "b")], waitingFor: ["x"])
        #expect(r.held.map(\.after) == [[1], [2, 1]])

        // As the engine does it: take all, pass the new IDs on, then place in order.
        var held = r.held + [HeldWindow(info: w(9, "x"), displayID: "D", spaceID: 1, after: [3], width: .proportion(0.5))]
        var pairs = HeldWindow.take(&held, for: [w(21, "x"), w(22, "x")], byApp: true)
        #expect(pairs.map(\.live.id) == [21, 22])
        HeldWindow.passOnNewIDs(&pairs, held: &held)
        var strip = r.strips[0].strip
        for p in pairs { strip.insert(p.live, width: p.held.width, slot: p.held.slot(in: strip), focus: false) }
        #expect(strip.allWindows.map(\.id) == [1, 21, 22, 4])
        // The held window that is left also uses the new ID.
        #expect(held.map(\.after) == [[22]])
    }

    // Round 10 finding: a match by app ignored the Space, so a window could go to a strip that is never shown.
    @Test func aHeldWindowIsTakenOnlyByAWindowThatFits() {
        let h = { (id: WindowID, space: UInt64) in HeldWindow(info: w(id, "x"), displayID: "D", spaceID: space, after: [], width: .proportion(0.5)) }
        var held = [h(1, 1), h(2, 2)]
        // Live window 22 is on Space 2, 21 on Space 1. Saved order alone would pair 22 with held 1.
        let spaceOf: [WindowID: UInt64] = [21: 1, 22: 2]
        let pairs = HeldWindow.take(&held, for: [w(22, "x"), w(21, "x")], byApp: true) { h, live in spaceOf[live.id] == h.spaceID }
        #expect(pairs.map { [$0.held.info.id, $0.live.id] } == [[1, 21], [2, 22]])
        // The same ID always matches.
        var again = [h(5, 1)]
        #expect(HeldWindow.take(&again, for: [w(5, "x")], byApp: false) { _, _ in false }.count == 1)
    }

    // Round 10 finding: a floating window of an app that did not answer was tiled when the app answered.
    @Test func aFloatingWindowOfAnAppThatDoesNotAnswerIsHeldAndComesBackFloating() {
        let s = Session(strips: [oneStrip([w(1, "a")])], floating: [w(7, "x", "Palette"), w(8, "b")])
        let r = s.restore(live: [w(1, "a")], waitingFor: ["x"])
        #expect(r.held.map(\.info.id) == [7])
        #expect(r.held.first?.floats == true)
        #expect(r.unmatchedFloating.map(\.id) == [8])
        // A save keeps it out of the strips.
        #expect(HeldWindow.placed(r.held, into: [1: r.strips[0].strip]) { _ in 1 }[1]?.allWindows.map(\.id) == [1])

        // It comes back by title (a new ID), not by a guess by app.
        var held = r.held
        #expect(HeldWindow.take(&held, for: [w(30, "x")], byApp: true).isEmpty)
        #expect(HeldWindow.take(&held, for: [w(30, "x"), w(31, "x", "Palette")], byApp: true).map(\.live.id) == [31])
        #expect(held.isEmpty)
    }

    // Round 8 finding: a quit copy of an app dropped held windows that the other running copy can still show.
    @Test func heldWindowsOfAQuitAppGoToAnotherCopy() {
        let h = { (id: WindowID, pid: Int32) -> HeldWindow in
            var i = w(id, "x"); i.pid = pid
            return HeldWindow(info: i, displayID: "D", spaceID: 1, after: [], width: .proportion(0.5))
        }
        var held = [h(1, 10), h(2, 11), h(3, 10)]
        HeldWindow.appQuit(&held, pid: 10, nextPid: 11)
        #expect(held.map(\.info.pid) == [11, 11, 11])
        HeldWindow.appQuit(&held, pid: 11, nextPid: nil)
        #expect(held.isEmpty)
    }

    @Test func aSaveKeepsHeldWindowsInTheirPlaces() {
        let s = Session(strips: [oneStrip([w(1, "a"), w(2, "x"), w(3, "x"), w(4, "b")])])
        let r = s.restore(live: [w(1, "a"), w(4, "b")], waitingFor: ["x"])
        let placed = HeldWindow.placed(r.held, into: [1: r.strips[0].strip]) { $0.spaceID }
        #expect(placed[1]?.allWindows.map(\.id) == [1, 2, 3, 4])
        #expect(s.restore(live: [w(1, "a"), w(4, "b")]).held.isEmpty)
    }

    // Round 7 finding: matching one window at a time let a new window take the place of another one.
    @Test func exactMatchesComeFirstForHeldWindows() {
        let held0 = [HeldWindow(info: w(1, "x", "Proj1"), displayID: "D", spaceID: 1, after: [], width: .proportion(0.5)),
                     HeldWindow(info: w(2, "x", "Proj2"), displayID: "D", spaceID: 1, after: [1], width: .proportion(0.5))]
        // After a restart the IDs are new. A "Welcome" window is in front.
        let live = [w(30, "x", "Welcome"), w(31, "x", "Proj1"), w(32, "x", "Proj2")]

        var held = held0
        let pairs = HeldWindow.take(&held, for: live, byApp: true)
        #expect(pairs.map(\.live.id) == [31, 32])
        #expect(pairs.map(\.held.info.id) == [1, 2])
        #expect(held.isEmpty)

        // Without byApp only exact matches count.
        held = held0
        #expect(HeldWindow.take(&held, for: [w(30, "x", "Welcome")], byApp: false).isEmpty)
        #expect(held.count == 2)
        // With byApp, the remaining held windows take the remaining windows of the app, in held order.
        #expect(HeldWindow.take(&held, for: [w(40, "x", "A"), w(41, "x", "B")], byApp: true).map(\.held.info.id) == [1, 2])
        held = held0
        #expect(HeldWindow.take(&held, for: [w(2, "x", "Renamed")], byApp: false).map(\.held.info.id) == [2])
        #expect(HeldWindow.take(&held, for: [w(9, "y", "Proj1")], byApp: true).isEmpty)
    }

    @Test func behaviourDefaultsMatchSpec() {
        let c = Config()
        #expect(!c.appearance.focusBorder && !c.appearance.dimInactive)
        #expect(!c.behavior.focusFollowsMouse && !c.behavior.mouseFollowsFocus)
        #expect(c.behavior.preventFocusStealing)
        #expect(c.gestures.fingers == .four)
    }

    @Test func sanitizeClampsBadValues() {
        var s = LayoutSettings()
        s.innerGap = -5
        s.presetWidths = [2, 0]
        s.defaultWidth = 9
        let c = s.sanitized()
        #expect(c.innerGap == 0)
        #expect(c.presetWidths == [0.05, 1])
        #expect(c.defaultWidth == 1)
    }
}

@Suite struct BindingTests {
    @Test func defaultsHaveNoConflicts() {
        #expect(bindingConflicts(DefaultBindings.make()).isEmpty)
    }

    @Test func defaultsUseControlOption() {
        for (_, combos) in DefaultBindings.make() {
            for c in combos { #expect(c.modifiers.isSuperset(of: [.control, .option])) }
        }
    }

    @Test func everyBindableCommandHasADefault() {
        let b = DefaultBindings.make()
        for c in Command.bindable { #expect(b[c]?.isEmpty == false, "no default for \(c.name)") }
    }

    @Test func conflictDetection() {
        var b = DefaultBindings.make()
        b[.wider] = [KeyCombo(KeyCode.r, [.control, .option])]
        #expect(bindingConflicts(b)[KeyCombo(KeyCode.r, [.control, .option])] == [.cycleWidth, .wider])
    }

    @Test func labels() {
        #expect(KeyCombo(KeyCode.h, [.control, .option]).usLabel == "⌃⌥H")
        #expect(KeyCombo(KeyCode.left, [.control, .option, .shift, .command]).usLabel == "⌃⌥⇧⌘←")
    }
}

@Suite struct SessionTests {
    func saved() -> Session {
        var s = Strip()
        s.insert(win(10, "term", "zsh"), width: .proportion(0.4), focus: true)
        s.insert(win(11, "safari", "Docs"), width: .proportion(0.6), focus: true)
        s.insert(win(12, "safari", "News"), width: .proportion(0.5), focus: true)
        _ = s.apply(.stackLeft, settings: settings, metrics: metrics)
        _ = s.apply(.toggleTabbed, settings: settings, metrics: metrics)
        return Session(strips: [SessionStrip(displayID: "D1", spaceID: 7, strip: s)], floating: [win(20, "calc", "Calc")])
    }

    @Test func exactIDsRestoreEverything() {
        let live = [win(10, "term", "zsh"), win(11, "safari", "Docs"), win(12, "safari", "News"), win(20, "calc", "Calc")]
        let r = saved().restore(live: live)
        #expect(r.strips.count == 1)
        #expect(ids(r.strips[0].strip) == [[10], [11, 12]])
        #expect(r.strips[0].strip.columns[1].isTabbed)
        #expect(r.strips[0].strip.columns[0].width == .proportion(0.4))
        #expect(r.strips[0].strip.focusedWindow?.id == 12)
        #expect(r.floating == [20])
        #expect(r.unmatched.isEmpty)
    }

    @Test func newIDsMatchByTitleThenApp() {
        // After a reboot every window has a new ID. Titles decide; the app is the fallback.
        let live = [win(101, "safari", "News"), win(102, "safari", "Docs"), win(103, "term", "other title"), win(104, "notes", "")]
        let r = saved().restore(live: live)
        #expect(ids(r.strips[0].strip) == [[103], [102, 101]])
        #expect(r.unmatched.map(\.id) == [104])
    }

    @Test func exactMatchIsNotStolenByLooseMatch() {
        // Window 12 kept its ID. Window 11 is gone. 12 must stay in its own place.
        let live = [win(10, "term", "zsh"), win(12, "safari", "News")]
        let r = saved().restore(live: live)
        #expect(ids(r.strips[0].strip) == [[10], [12]])
        #expect(r.strips[0].strip.columns[1].isTabbed == false)
        #expect(r.strips[0].strip.focusedWindow?.id == 12)
    }

    @Test func missingWindowsAreDropped() {
        let r = saved().restore(live: [])
        #expect(r.strips.isEmpty)
        #expect(r.unmatchedFloating.map(\.id) == [20])
    }

    func twoSpaces() -> Session {
        var other = Strip()
        other.insert(win(30, "mail", "Inbox"), width: .proportion(0.5), focus: true)
        var s = saved()
        s.strips.append(SessionStrip(displayID: "D1", spaceID: 8, strip: other))
        return s
    }

    @Test func stripsOfSpacesNotOnScreenWait() {
        // Space 8 exists but is not on screen: AX cannot see its windows yet.
        let p = twoSpaces().partition(visible: [7], known: [7, 8])
        #expect(p.now.strips.map(\.spaceID) == [7])
        #expect(p.now.floating.map(\.id) == [20])
        #expect(p.later.map(\.spaceID) == [8])
    }

    @Test func stripsOfRemovedSpacesOrUnknownSpacesRestoreNow() {
        #expect(twoSpaces().partition(visible: [7], known: [7]).later.isEmpty)
        #expect(twoSpaces().partition(visible: [0], known: []).later.isEmpty)
    }

    @Test func savingKeepsTheWaitingStrips() {
        let p = twoSpaces().partition(visible: [7], known: [7, 8])
        let live = Session(strips: p.now.strips, floating: [])
        let merged = live.merging(later: p.later, laterFloating: [win(21, "calc", "Other")], managed: [10, 11, 12])
        #expect(merged.strips.map(\.spaceID) == [7, 8])
        #expect(ids(merged.strips[1].strip) == [[30]])
        #expect(merged.floating.map(\.id) == [21])
    }

    @Test func aWindowManagedNowIsNotSavedTwice() {
        // Window 30 was moved to Space 7 while Striple was off; it is managed there now.
        let p = twoSpaces().partition(visible: [7], known: [7, 8])
        var strip = p.now.strips[0].strip
        strip.insert(win(30, "mail", "Inbox"), width: .proportion(0.5), focus: false)
        let live = Session(strips: [SessionStrip(displayID: "D1", spaceID: 7, strip: strip)], floating: [])
        let merged = live.merging(later: p.later, laterFloating: [win(20, "calc", "Calc")], managed: [10, 11, 12, 20, 30])
        #expect(merged.strips.map(\.spaceID) == [7])
        #expect(merged.floating.isEmpty)
    }

    @Test func waitingStripOnTheSameKeyIsAppended() {
        var a = Strip()
        a.insert(win(40, "x", "a"), width: .proportion(0.5), focus: true)
        var b = Strip()
        b.insert(win(41, "y", "b"), width: .proportion(0.5), focus: true)
        let live = Session(strips: [SessionStrip(displayID: "D1", spaceID: 8, strip: a)], floating: [])
        let merged = live.merging(later: [SessionStrip(displayID: "D1", spaceID: 8, strip: b)], laterFloating: [], managed: [40])
        #expect(ids(merged.strips[0].strip) == [[40], [41]])
    }

    @Test func codableRoundTrip() throws {
        let s = saved()
        let back = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}

@Suite struct RuleTests {
    let config: Config = {
        var c = Config()
        c.rules = [AppRule(bundleID: "float.me", appName: "F", action: .float),
                   AppRule(bundleID: "slot.me", appName: "S", action: .slot(3)),
                   AppRule(bundleID: "tile.me", appName: "T", action: .tile)]
        return c
    }()

    @Test func standardWindowTiles() {
        #expect(WindowRules.decide(WindowTraits(bundleID: "x"), config: config) == .tile(slot: nil))
    }

    @Test func fixedSizeFloats() {
        #expect(WindowRules.decide(WindowTraits(bundleID: "x", isResizable: false), config: config) == .float)
        #expect(WindowRules.decide(WindowTraits(bundleID: "x", zoomButtonEnabled: false), config: config) == .float)
    }

    @Test func dialogsFloatAndOwnWindowsFloat() {
        #expect(WindowRules.decide(WindowTraits(bundleID: "x", subrole: "AXDialog"), config: config) == .float)
        #expect(WindowRules.decide(WindowTraits(bundleID: "x", isOwnApp: true), config: config) == .float)
    }

    @Test func fullscreenAndMinimizedAreIgnored() {
        #expect(WindowRules.decide(WindowTraits(bundleID: "x", isFullscreen: true), config: config) == .ignore)
        #expect(WindowRules.decide(WindowTraits(bundleID: "x", isMinimized: true), config: config) == .ignore)
        #expect(WindowRules.decide(WindowTraits(bundleID: "x", role: "AXSheet"), config: config) == .ignore)
    }

    @Test func rulesWin() {
        #expect(WindowRules.decide(WindowTraits(bundleID: "float.me"), config: config) == .float)
        #expect(WindowRules.decide(WindowTraits(bundleID: "slot.me"), config: config) == .tile(slot: 3))
        #expect(WindowRules.decide(WindowTraits(bundleID: "tile.me", isResizable: false), config: config) == .tile(slot: nil))
        #expect(WindowRules.decide(WindowTraits(bundleID: "tile.me", subrole: "AXDialog"), config: config) == .float)
    }
}

@Suite struct MinimapTests {
    @Test func itemsAndViewportAreNormalised() {
        let d = display(), s = layoutSettings()
        let st = strip([1, 2, 3, 4], focus: 3)
        let m = MinimapModel.make(strip: st, display: d, settings: s, scroll: 600)
        #expect(m.items.count == 4)
        #expect(m.items.filter(\.focused).count == 1)
        for item in m.items {
            #expect(item.rect.minX >= -1e-9 && item.rect.maxX <= 1 + 1e-9)
            #expect(item.rect.minY >= -1e-9 && item.rect.maxY <= 1 + 1e-9)
        }
        #expect(m.viewport.maxX <= 1 + 1e-9)
        #expect(m.viewport.minX > 0.2)
    }

    @Test func tabbedColumnShowsOnlyTheActiveWindow() {
        let d = display(), s = layoutSettings()
        var st = strip([1, 2], focus: 1)
        _ = st.apply(.stackLeft, settings: s, metrics: d.metrics(s))
        _ = st.apply(.toggleTabbed, settings: s, metrics: d.metrics(s))
        #expect(MinimapModel.make(strip: st, display: d, settings: s).items.count == 1)
    }
}

@Suite struct MacSetupTests {
    func status(_ checks: [MacSetupCheck], _ id: String) -> MacSetupCheck.Status? { checks.first { $0.id == id }?.status }

    @Test func fernandosMacToday() {
        // Values read with `defaults read` on 2026-10-12 (macOS 26.7.1).
        let i = MacSetupInputs(accessibilityTrusted: false, swipeFingers: .four, osMajorVersion: 26,
                               fourFingerHorizSwipe: 2, threeFingerHorizSwipe: 0, threeFingerDrag: true)
        let c = MacSetup.evaluate(i)
        #expect(status(c, "accessibility") == .problem)
        #expect(status(c, "swipe") == .problem)
        #expect(status(c, "three-finger-drag") == nil) // only relevant for 3-finger swipes
        #expect(status(c, "mru-spaces") == .warning) // key missing: macOS default is on
        #expect(status(c, "separate-spaces") == .ok)
        #expect(status(c, "stage-manager") == .ok)
        #expect(status(c, "macos-tiling") == .warning)
        #expect(status(c, "other-wm") == .ok)
    }

    // On 2026-10-14 the switch showed on, but the entry held the cdhashes of an old ad hoc build.
    // The fix text must name the way out, because turning the switch off and on does not help.
    @Test func accessibilityFixNamesResetWhenTheSwitchIsOn() {
        let off = MacSetupInputs(accessibilityTrusted: false, swipeFingers: .four, osMajorVersion: 26)
        let fix = MacSetup.evaluate(off).first { $0.id == "accessibility" }?.fix ?? ""
        #expect(fix.contains("Privacy & Security › Accessibility"))
        #expect(fix.contains("Reset Permission"))
        let on = MacSetupInputs(accessibilityTrusted: true, swipeFingers: .four, osMajorVersion: 26)
        #expect(MacSetup.evaluate(on).first { $0.id == "accessibility" }?.fix == "")
    }

    @Test func cleanSetupIsAllGreen() {
        let i = MacSetupInputs(accessibilityTrusted: true, swipeFingers: .four, osMajorVersion: 15, fourFingerHorizSwipe: 0,
                               threeFingerHorizSwipe: 0, threeFingerDrag: true, mruSpaces: false, spansDisplays: false,
                               stageManager: false, tilingByEdgeDrag: false, tilingByTopEdgeDrag: false, tilingOptionAccelerator: false)
        #expect(MacSetup.evaluate(i).allSatisfy { $0.status == .ok })
    }

    @Test func threeFingerSetupNeedsDragOffAndPagesOnTwo() {
        var i = MacSetupInputs(accessibilityTrusted: true, swipeFingers: .three, osMajorVersion: 14,
                               threeFingerHorizSwipe: 1, threeFingerDrag: true)
        var c = MacSetup.evaluate(i)
        #expect(status(c, "swipe") == .problem)
        #expect(c.first { $0.id == "swipe" }!.fix.contains("two fingers"))
        #expect(status(c, "three-finger-drag") == .problem)
        #expect(status(c, "macos-tiling") == nil) // macOS 14 has no edge tiling
        i.threeFingerHorizSwipe = 0
        i.threeFingerDrag = false
        c = MacSetup.evaluate(i)
        #expect(status(c, "swipe") == .ok && status(c, "three-finger-drag") == .ok)
    }

    @Test func otherWindowManagersAreNamed() {
        let i = MacSetupInputs(accessibilityTrusted: true, swipeFingers: .off, osMajorVersion: 26, conflictingApps: ["Rectangle", "Magnet"])
        let c = MacSetup.evaluate(i).first { $0.id == "other-wm" }!
        #expect(c.status == .problem)
        #expect(c.fix == "Quit Magnet, Rectangle. It moves windows too.")
    }
}

@Suite struct SampleWindowTests {
    @Test func percentiles() {
        var w = SampleWindow(capacity: 100)
        #expect(w.percentile(50) == 0)
        for i in 1...100 { w.add(Double(i)) }
        #expect(w.percentile(50) == 50)
        #expect(w.percentile(95) == 95)
        #expect(w.percentile(100) == 100)
    }

    @Test func ringOverwritesOldest() {
        var w = SampleWindow(capacity: 4)
        for i in 1...6 { w.add(Double(i)) }
        #expect(w.count == 4)
        #expect(w.percentile(0) == 3)
        #expect(w.percentile(100) == 6)
    }
}
