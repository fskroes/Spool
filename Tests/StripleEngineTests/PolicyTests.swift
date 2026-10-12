import ApplicationServices
import CoreGraphics
import Testing
@testable import StripleCore
@testable import StripleEngine

@Suite struct PolicyTests {
    @Test func focusSteal() {
        // A brand-new window of a running app, no input for 3 s: stealing.
        #expect(Policy.isFocusSteal(windowAge: 0.2, secondsSinceInput: 3, appAge: 600))
        // The user just pressed a key or clicked: allowed.
        #expect(!Policy.isFocusSteal(windowAge: 0.2, secondsSinceInput: 0.3, appAge: 600))
        // An old window: allowed (the user clicked it or switched to it).
        #expect(!Policy.isFocusSteal(windowAge: 30, secondsSinceInput: 3, appAge: 600))
        // A slow app that the user launched a few seconds ago: allowed.
        #expect(!Policy.isFocusSteal(windowAge: 0.2, secondsSinceInput: 4, appAge: 5))
    }

    @Test func scrollDeltaFollowsTheFingers() {
        var g = GestureSettings()
        g.natural = true
        g.sensitivity = 1
        // Fingers move left a tenth of the trackpad: the strip scrolls right by a tenth of the view.
        #expect(Policy.scrollDelta(dx: -0.1, viewWidth: 1000, settings: g) == 100)
        g.natural = false
        #expect(Policy.scrollDelta(dx: -0.1, viewWidth: 1000, settings: g) == -100)
        g.sensitivity = 2
        #expect(Policy.scrollDelta(dx: 0.1, viewWidth: 1000, settings: g) == 200)
    }

    @Test func scrollBoundsPerCenterMode() {
        let m = StripMetrics(usableWidth: 1000, usableHeight: 800, gap: 10)
        let strip = Strip(columns: (1...3).map { Column(window: WindowInfo(id: WindowID($0)), width: .proportion(0.5)) })
        var s = LayoutSettings()
        s.innerGap = 10
        s.centerMode = .onOverflow
        let p = strip.columnPositions(metrics: m)
        let b = Policy.scrollBounds(strip, settings: s, metrics: m)
        #expect(b.lower == 0)
        #expect(abs(b.upper - (p.total - 1000)) < 0.001)
        s.centerMode = .always
        let c = Policy.scrollBounds(strip, settings: s, metrics: m)
        #expect(abs(c.lower - (p.x[0] - (1000 - p.width[0]) / 2)) < 0.001)
        #expect(abs(c.upper - (p.x[2] - (1000 - p.width[2]) / 2)) < 0.001)
        #expect(Policy.scrollBounds(Strip(), settings: s, metrics: m) == (0, 0))
    }

    @Test func rubberBandResistsAndIsBounded() {
        #expect(Policy.rubberBand(50, lower: 0, upper: 100, dimension: 200) == 50)
        let a = Policy.rubberBand(150, lower: 0, upper: 100, dimension: 200)
        let b = Policy.rubberBand(300, lower: 0, upper: 100, dimension: 200)
        #expect(a > 100 && a < 150)
        #expect(b > a)
        #expect(Policy.rubberBand(1_000_000, lower: 0, upper: 100, dimension: 200) < 300)
        let l = Policy.rubberBand(-50, lower: 0, upper: 100, dimension: 200)
        #expect(l < 0 && l > -50)
    }

    @Test func sameFrameTolerance() {
        let r = CGRect(x: 10, y: 10, width: 100, height: 100)
        #expect(Policy.same(r, r.offsetBy(dx: 1.5, dy: -1)))
        #expect(!Policy.same(r, r.offsetBy(dx: 3, dy: 0)))
        #expect(!Policy.same(r, nil))
    }

    @Test func displayLookup() {
        let frames = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        #expect(Policy.displayIndex(for: CGPoint(x: 1500, y: 10), frames: frames) == 1)
        // Off every display (a parked window's centre): the nearest one.
        #expect(Policy.displayIndex(for: CGPoint(x: 2600, y: 10), frames: frames) == 1)
        #expect(Policy.displayIndex(for: CGPoint(x: -300, y: 900), frames: frames) == 0)
        #expect(Policy.displayIndex(for: .zero, frames: []) == nil)
    }

    @Test func nextDisplayGoesLeftToRightAndWraps() {
        let frames = [CGRect(x: 1000, y: 0, width: 1000, height: 800), CGRect(x: -1200, y: 0, width: 1200, height: 900),
                      CGRect(x: 0, y: 0, width: 1000, height: 800)]
        #expect(Policy.nextDisplay(after: 1, frames: frames) == 2)
        #expect(Policy.nextDisplay(after: 2, frames: frames) == 0)
        #expect(Policy.nextDisplay(after: 0, frames: frames) == 1)
        #expect(Policy.nextDisplay(after: 0, frames: [frames[0]]) == nil)
    }

    @Test func bringIntoView() {
        let area = CGRect(x: 0, y: 25, width: 1000, height: 775)
        // Parked at the right edge with a 1 pt sliver.
        let parked = CGRect(x: 999, y: 799, width: 500, height: 700)
        #expect(Policy.bringIntoView(parked, area: area) == CGRect(x: 500, y: 100, width: 500, height: 700))
        // Too big: shrunk to the area.
        #expect(Policy.bringIntoView(CGRect(x: -10, y: 0, width: 2000, height: 2000), area: area) == area)
        let inside = CGRect(x: 100, y: 100, width: 300, height: 300)
        #expect(Policy.bringIntoView(inside, area: area) == inside)
    }

    @Test func translateKeepsRelativePlace() {
        let a = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let b = CGRect(x: 1000, y: 0, width: 2000, height: 1000)
        let f = CGRect(x: 900, y: 0, width: 100, height: 100) // right edge of a
        #expect(Policy.translate(f, from: a, to: b) == CGRect(x: 2900, y: 0, width: 100, height: 100))
        let big = CGRect(x: 0, y: 0, width: 3000, height: 100)
        #expect(Policy.translate(big, from: b, to: a).width == 1000)
    }

    @Test func adoptedWidthIsAProportionInRange() {
        let m = StripMetrics(usableWidth: 1000, usableHeight: 800, gap: 10)
        guard case .proportion(let p) = Policy.adoptedWidth(495, metrics: m) else { Issue.record("not a proportion"); return }
        #expect(abs(p - 0.5) < 0.001)
        #expect(Policy.adoptedWidth(5000, metrics: m) == .proportion(1))
        #expect(Policy.adoptedWidth(1, metrics: m) == .proportion(0.05))
    }
}

@Suite struct ReleaseAndDragTests {
    let display = DisplayGeometry(frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
                                  usable: CGRect(x: 0, y: 25, width: 1200, height: 875),
                                  neighborLeft: false, neighborRight: false, neighborBelow: false)

    @Test func releaseUsesTheAnimationTargetNotTheLastFrame() {
        // Stopped in the middle of an animation: the window goes to the place it was moving to.
        let target = CGRect(x: 300, y: 35, width: 500, height: 600)
        #expect(Policy.releaseFrame(target: target, known: CGRect(x: 120, y: 35, width: 500, height: 600),
                                    display: display, settings: LayoutSettings()) == target)
    }

    @Test func releaseBringsAParkedTargetIntoView() {
        let r = Policy.releaseFrame(target: CGRect(x: 2000, y: 35, width: 500, height: 600), known: nil,
                                    display: display, settings: LayoutSettings())
        #expect(r.map { display.usable.contains($0) } == true)
    }

    @Test func releaseOfAHiddenWindowUsesItsParkedFrame() {
        // Parked at the bottom right corner with a 1 pt sliver, then the app was hidden.
        let parked = CGRect(x: 1199, y: 899, width: 500, height: 600)
        let r = Policy.releaseFrame(target: nil, known: parked, display: display, settings: LayoutSettings())
        #expect(r == CGRect(x: 700, y: 300, width: 500, height: 600))
        #expect(Policy.releaseFrame(target: nil, known: nil, display: display, settings: LayoutSettings()) == nil)
    }

    @Test func onlyAMovedMouseIsADrag() {
        #expect(!Policy.isDrag(from: nil, to: CGPoint(x: 50, y: 50)))
        #expect(!Policy.isDrag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 13)))
        #expect(Policy.isDrag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 15, y: 10)))
    }

    // Round 2 finding N2: a mouse drag anywhere while the strip animates took over animating windows.
    // Round 2 finding N3: windows of a healed app on other Spaces lost their notifications.
    @Test func healingObservesEveryManagedWindow() {
        let plan = Policy.healPlan(managed: [1: "old1", 2: "old2", 3: "old3"], fresh: [1: "new1", 3: "new3", 9: "unmanaged"])
        #expect(plan.observe == [1: "new1", 2: "old2", 3: "new3"])
        #expect(plan.renewed == [1, 3])
    }

    @Test func onlyThePressedWindowCanBeDragged() {
        #expect(Policy.isUserDrag(window: 7, mouseMoved: true, pressedWindow: 7, ownFrame: false, currentDrag: nil))
        #expect(Policy.isUserDrag(window: 7, mouseMoved: true, pressedWindow: 7, ownFrame: false, currentDrag: 7))
        // Another window that moves because Striple animates the strip.
        #expect(!Policy.isUserDrag(window: 8, mouseMoved: true, pressedWindow: 7, ownFrame: false, currentDrag: nil))
        // The pressed window, but at a frame Striple wrote: selecting text while it animates.
        #expect(!Policy.isUserDrag(window: 7, mouseMoved: true, pressedWindow: 7, ownFrame: true, currentDrag: nil))
        #expect(!Policy.isUserDrag(window: 7, mouseMoved: false, pressedWindow: 7, ownFrame: false, currentDrag: nil))
        #expect(!Policy.isUserDrag(window: 7, mouseMoved: true, pressedWindow: nil, ownFrame: false, currentDrag: nil))
        #expect(!Policy.isUserDrag(window: 7, mouseMoved: true, pressedWindow: 7, ownFrame: false, currentDrag: 9))
    }

    // Round 3 finding: a resize that started outside the window edge was neither adopted nor corrected.
    @Test func aPressJustOutsideTheEdgeBelongsToTheWindow() {
        let a = CGRect(x: 0, y: 0, width: 400, height: 300)
        let b = CGRect(x: 404, y: 0, width: 400, height: 300)
        let order: [(id: WindowID, bounds: CGRect)] = [(1, a), (2, b)]
        // 3 pt right of A's edge, in the gap.
        #expect(Policy.pressedWindow(at: CGPoint(x: 403, y: 100), frontToBack: order, slop: 0) == nil)
        #expect(Policy.pressedWindow(at: CGPoint(x: 403, y: 100), frontToBack: order, slop: 8) == 1)
        // Inside B but within A's margin: the front window wins, as in the window server.
        #expect(Policy.pressedWindow(at: CGPoint(x: 406, y: 100), frontToBack: order, slop: 8) == 1)
        #expect(Policy.pressedWindow(at: CGPoint(x: 406, y: 100), frontToBack: [(2, b), (1, a)], slop: 8) == 2)
        #expect(Policy.pressedWindow(at: CGPoint(x: 900, y: 100), frontToBack: order, slop: 8) == nil)
    }

    @Test func aMoveWhileTheButtonIsDownIsCorrectedUnlessItIsADragOrOurs() {
        #expect(Policy.correctAfterRelease(isUserDrag: false, ownFrame: false))
        #expect(!Policy.correctAfterRelease(isUserDrag: true, ownFrame: false))
        #expect(!Policy.correctAfterRelease(isUserDrag: false, ownFrame: true))
    }

    // Round 3 finding: windows of a hidden app got columns that show nothing.
    @Test func windowsOfHiddenAppsLeaveTheStrip() {
        let tiled: [WindowID: pid_t] = [10: 100, 11: 100, 20: 200, 30: 300]
        #expect(Policy.windowsToHide(tiled: tiled, hiddenApps: [100, 300]) == [10, 11, 30])
        #expect(Policy.windowsToHide(tiled: tiled, hiddenApps: []) == [])
    }

    // Round 3 finding: healing a hung app dropped its working observer before the new one existed.
    @Test func aRewatchKeepsTheOldObserverWhenTheNewOneFails() {
        #expect(WindowTracker.replace(old: "old", make: { nil as String? }) == nil)
        let plan = WindowTracker.replace(old: "old", make: { "new" })
        #expect(plan?.install == "new")
        #expect(plan?.drop == "old")
        var made = 0
        _ = WindowTracker.replace(old: nil as String?, make: { made += 1; return "first" })
        #expect(made == 1)
    }

    @Test func spaceOfARemovedDisplay() {
        let known: [String: Set<UInt64>] = ["A": [1, 2], "B": [5]]
        #expect(Policy.spaceExists(2, onDisplay: "A", known: known))
        // macOS has not moved Space 5 to display A (yet): the column must go to A's current Space.
        #expect(!Policy.spaceExists(5, onDisplay: "A", known: known))
        #expect(Policy.spaceExists(5, onDisplay: "Z", known: ["Main": [5]]))
        #expect(Policy.spaceExists(9, onDisplay: "A", known: [:]))
        #expect(Policy.spaceExists(0, onDisplay: "A", known: known))
    }

    // Round 4 finding: a restored strip kept the saved scroll, so after windows were closed the rest were parked.
    @Test func aRestoredStripScrollsToItsFocusedColumn() {
        let m = StripMetrics(usableWidth: 1000, usableHeight: 800, gap: 10)
        let settings = LayoutSettings()
        let saved = Strip(columns: (1...2).map { Column(window: WindowInfo(id: WindowID($0)), width: .proportion(0.5)) },
                          focusedColumn: 1, scroll: 3000)
        let strip = Policy.restoredStrip(saved, into: nil, settings: settings, metrics: m)
        let p = strip.columnPositions(metrics: m)
        let x = p.x[strip.focusedColumn] - strip.scroll
        #expect(x >= 0 && x + p.width[strip.focusedColumn] <= m.usableWidth)
        // Into a strip that has windows: the saved columns go to the end, the focus stays.
        let existing = Strip(columns: [Column(window: WindowInfo(id: 9), width: .proportion(0.5))])
        let merged = Policy.restoredStrip(saved, into: existing, settings: settings, metrics: m)
        #expect(merged.allWindows.map(\.id) == [9, 1, 2])
        #expect(merged.focusedColumn == 0)
        #expect(merged.scroll <= 0.5)
    }

    // Round 4 finding: parked windows (1 pt slivers at the edge) took focus-follows-mouse and presses.
    @Test func parkedWindowsAreNotUnderTheMouse() {
        let sliver = CGRect(x: 1439, y: 0, width: 1, height: 900)
        let visible = CGRect(x: 800, y: 0, width: 636, height: 900)
        let order: [(id: WindowID, bounds: CGRect)] = [(5, sliver), (6, visible)]
        #expect(Policy.pressedWindow(at: CGPoint(x: 1439.5, y: 400), frontToBack: order, slop: 0, parked: [5]) == nil)
        #expect(Policy.pressedWindow(at: CGPoint(x: 1434, y: 400), frontToBack: order, slop: 8, parked: [5]) == 6)
        #expect(Policy.pressedWindow(at: CGPoint(x: 1434, y: 400), frontToBack: order, slop: 8) == 5)
    }

    // Round 4 finding: a hidden window on another Space was put back on the Space on screen.
    @Test func aWindowGoesBackToItsOwnSpace() {
        #expect(Policy.putBackSpace(old: 1, windowSpaces: [1], active: 2) == 1)
        // Moved to the Space on screen, or its Space is gone: the Space on screen.
        #expect(Policy.putBackSpace(old: 1, windowSpaces: [2], active: 2) == 2)
        #expect(Policy.putBackSpace(old: 1, windowSpaces: [3], active: 2) == 3)
        // Spaces cannot be read: the Space on screen. No Spaces at all: 0.
        #expect(Policy.putBackSpace(old: 1, windowSpaces: [], active: 2) == 2)
        #expect(Policy.putBackSpace(old: 0, windowSpaces: [], active: 0) == 0)
    }

    // Round 4 finding: a drop onto a disabled display reordered the window to the end of its own strip.
    @Test func aDropOntoADisabledDisplayPutsTheWindowBack() {
        #expect(Policy.dropKind(dropDisplay: "B", ownDisplay: "A", dropDisplayDisabled: true) == .putBack)
        #expect(Policy.dropKind(dropDisplay: nil, ownDisplay: "A", dropDisplayDisabled: false) == .putBack)
        #expect(Policy.dropKind(dropDisplay: "B", ownDisplay: "A", dropDisplayDisabled: false) == .otherDisplay)
        #expect(Policy.dropKind(dropDisplay: "A", ownDisplay: "A", dropDisplayDisabled: false) == .reorder)
    }

    // Round 4 finding: watching an app stopped after about 5 s, so a busy app was never tiled.
    @Test func watchRetriesGoOnForAboutTwoMinutes() {
        let delays = (1...40).compactMap { Policy.watchRetryDelay(attempt: $0) }
        #expect(delays.count == 30)
        #expect(delays.prefix(6).reduce(0, +) == 5.25)
        #expect(delays.allSatisfy { $0 <= 5 })
        #expect((115...135).contains(delays.reduce(0, +)))
    }

    // Round 4 finding: hidden and minimized windows lost their slot when Striple restarted.
    @Test func theSessionKeepsTheSlotsOfHiddenAndMinimizedWindows() {
        func col(_ id: WindowID) -> Column { Column(window: WindowInfo(id: id), width: .proportion(0.5)) }
        // [1, B, A, 4] lost A (slot 3) and then B (slot 2). Focus is on 4.
        let strips = ["k": Strip(columns: [col(1), col(4)], focusedColumn: 1)]
        let off: [(info: WindowInfo, key: String, slot: Int?, width: ColumnWidth?)] = [
            (WindowInfo(id: 3), "k", 3, .proportion(0.7)),
            (WindowInfo(id: 2), "k", 2, nil),
            (WindowInfo(id: 8), "other", nil, nil),
        ]
        let out = Policy.stripsForSession(strips, offStrip: off, defaultWidth: .proportion(0.5))
        #expect(out["k"]?.allWindows.map(\.id) == [1, 2, 3, 4])
        #expect(out["k"]?.focusedColumn == 3)
        #expect(out["k"]?.columns[2].width == .proportion(0.7))
        #expect(out["other"]?.allWindows.map(\.id) == [8])
        // Saved and restored, the order stays.
        let session = Session(strips: [SessionStrip(displayID: "D", spaceID: 0, strip: out["k"]!)], floating: [])
        let back = session.restore(live: (1...4).map { WindowInfo(id: WindowID($0)) })
        #expect(back.strips.first?.strip.allWindows.map(\.id) == [1, 2, 3, 4])
    }

    // Round 5 finding: each retry waited for all three notifications of a hung app (about 0.75 s on main).
    @Test func registeringStopsAtTheFirstTimeout() {
        var calls: [String] = []
        let hung = Policy.registerUntilHung(["a", "b", "c"]) { calls.append($0); return $0 == "a" ? .success : .cannotComplete }
        #expect(calls == ["a", "b"])
        #expect(hung.registered == 1 && hung.hung)

        calls = []
        let ok = Policy.registerUntilHung(["a", "b", "c"]) { calls.append($0); return $0 == "b" ? .failure : .success }
        #expect(calls == ["a", "b", "c"])
        #expect(ok.registered == 2 && !ok.hung)
    }

    // Round 5 finding: a tiled window at another window level (video player "Float on Top") counted as closed.
    @Test func windowsAtEveryLevelExist() {
        let list: [[String: Any]] = [
            [kCGWindowNumber as String: NSNumber(value: 10), kCGWindowLayer as String: 0],
            [kCGWindowNumber as String: NSNumber(value: 11), kCGWindowLayer as String: 3],
            [kCGWindowNumber as String: NSNumber(value: 12), kCGWindowLayer as String: 25],
            [kCGWindowLayer as String: 0],
        ]
        #expect(WindowList.ids(in: list) == [10, 11, 12])
    }

    // Round 5 finding: the AX timeout covered app elements only, so a hung app's window could block for 6 s.
    @Test func theGlobalTimeoutCanBeSet() {
        #expect(AX.setGlobalTimeout() == .success)
    }
}
