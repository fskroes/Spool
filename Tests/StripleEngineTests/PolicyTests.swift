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

    @Test func spaceOfARemovedDisplay() {
        let known: [String: Set<UInt64>] = ["A": [1, 2], "B": [5]]
        #expect(Policy.spaceExists(2, onDisplay: "A", known: known))
        // macOS has not moved Space 5 to display A (yet): the column must go to A's current Space.
        #expect(!Policy.spaceExists(5, onDisplay: "A", known: known))
        #expect(Policy.spaceExists(5, onDisplay: "Z", known: ["Main": [5]]))
        #expect(Policy.spaceExists(9, onDisplay: "A", known: [:]))
        #expect(Policy.spaceExists(0, onDisplay: "A", known: known))
    }
}
