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
