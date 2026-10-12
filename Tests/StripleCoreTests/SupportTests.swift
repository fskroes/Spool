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
