import CoreGraphics
import Foundation
import Testing
@testable import StripleCore

// Display 1200x900 at the origin; usable area below a 25 pt menu bar. Outer gaps 10, inner gap 10.
func display(left: Bool = false, right: Bool = false, below: Bool = false) -> DisplayGeometry {
    DisplayGeometry(frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
                    usable: CGRect(x: 0, y: 25, width: 1200, height: 875),
                    neighborLeft: left, neighborRight: right, neighborBelow: below)
}

func layoutSettings(_ mode: CenterMode = .onOverflow) -> LayoutSettings {
    var s = LayoutSettings()
    s.innerGap = 10
    s.outerGaps = EdgeGaps(top: 10, bottom: 10, left: 10, right: 10)
    s.centerMode = mode
    return s
}

@Suite struct LayoutTests {
    @Test func twoHalfColumnsFillTheWorkAreaExactly() {
        let d = display(), s = layoutSettings()
        let r = Layout.compute(strip([1, 2]), display: d, settings: s)
        let a = r.frames[1]!, b = r.frames[2]!
        #expect(a.minX == 10)
        #expect(b.minX == a.maxX + 10)
        #expect(abs(b.maxX - 1190) < 0.001)
        #expect(a.minY == 35 && a.maxY == 890)
    }

    @Test func thirdsFitWithTwoGaps() {
        let d = display(), s = layoutSettings()
        let r = Layout.compute(strip([1, 2, 3], width: 1.0 / 3.0), display: d, settings: s)
        #expect(abs(r.frames[3]!.maxX - 1190) < 0.001)
    }

    @Test func stackFillsHeightWithGaps() {
        let d = display(), s = layoutSettings()
        var st = strip([1, 2, 3], focus: 1)
        _ = st.apply(.stackLeft, settings: s, metrics: d.metrics(s))
        let r = Layout.compute(st, display: d, settings: s)
        let a = r.frames[1]!, b = r.frames[2]!
        #expect(a.minY == 35)
        #expect(b.minY == a.maxY + 10)
        #expect(b.maxY == 890)
        #expect(a.width == b.width)
    }

    @Test func tabbedColumnGivesFullHeightAndATabBar() {
        let d = display(), s = layoutSettings()
        var st = strip([1, 2], focus: 1)
        _ = st.apply(.stackLeft, settings: s, metrics: d.metrics(s))
        _ = st.apply(.toggleTabbed, settings: s, metrics: d.metrics(s))
        let r = Layout.compute(st, display: d, settings: s)
        #expect(r.frames[1] == r.frames[2])
        #expect(abs(r.frames[1]!.minY - (35 + s.tabBarHeight)) < 1e-6)
        #expect(r.frames[1]!.maxY == 890)
        #expect(r.tabBars.count == 1)
        #expect(r.tabBars[0].windows.map(\.id) == [1, 2])
        #expect(r.tabBars[0].activeIndex == 1)
    }

    @Test func focusedWindowIsLastInOrder() {
        let r = Layout.compute(strip([1, 2, 3], focus: 1), display: display(), settings: layoutSettings())
        #expect(r.order.last == 2)
        #expect(Set(r.order) == [1, 2, 3])
    }

    @Test func scrollShiftsFrames() {
        let d = display(), s = layoutSettings()
        let a = Layout.compute(strip([1, 2]), display: d, settings: s, scroll: 0).frames[1]!
        let b = Layout.compute(strip([1, 2]), display: d, settings: s, scroll: 100).frames[1]!
        #expect(b.minX == a.minX - 100)
    }
}

@Suite struct CenterModeTests {
    let d = display()
    var m: StripMetrics { d.metrics(layoutSettings()) }

    @Test func onOverflowLeftAlignsWhenEverythingFits() {
        var st = strip([1, 2], focus: 1)
        st.ensureFocusVisible(settings: layoutSettings(.onOverflow), metrics: m)
        #expect(st.scroll == 0)
    }

    @Test func onOverflowCentresAndClampsWhenItOverflows() {
        let s = layoutSettings(.onOverflow)
        var st = strip([1, 2, 3, 4, 5], focus: 2)
        st.ensureFocusVisible(settings: s, metrics: m)
        let p = st.columnPositions(metrics: m)
        #expect(abs(st.scroll - (p.x[2] - (m.usableWidth - p.width[2]) / 2)) < 0.001)
        st.focusedColumn = 0
        st.ensureFocusVisible(settings: s, metrics: m)
        #expect(st.scroll == 0)
        st.focusedColumn = 4
        st.ensureFocusVisible(settings: s, metrics: m)
        #expect(abs(st.scroll - (p.total - m.usableWidth)) < 0.001)
    }

    @Test func alwaysCentresEvenTheFirstColumn() {
        var st = strip([1, 2, 3], focus: 0)
        st.ensureFocusVisible(settings: layoutSettings(.always), metrics: m)
        #expect(st.scroll < 0)
    }

    @Test func neverScrollsTheMinimum() {
        let s = layoutSettings(.never)
        var st = strip([1, 2, 3, 4], focus: 0)
        st.ensureFocusVisible(settings: s, metrics: m)
        #expect(st.scroll == 0)
        st.focusedColumn = 1
        st.ensureFocusVisible(settings: s, metrics: m)
        #expect(st.scroll == 0) // column 2 is already visible
        st.focusedColumn = 2
        st.ensureFocusVisible(settings: s, metrics: m)
        let p = st.columnPositions(metrics: m)
        #expect(abs(st.scroll - (p.x[2] + p.width[2] - m.usableWidth)) < 0.001)
        st.focusedColumn = 0
        st.ensureFocusVisible(settings: s, metrics: m)
        #expect(st.scroll == 0)
    }

    @Test func snapSettlesOnNearestColumnAndUsesVelocity() {
        let s = layoutSettings(.always)
        let st = strip([1, 2, 3, 4, 5], focus: 0)
        let p = st.columnPositions(metrics: m)
        let centre = { (i: Int) in p.x[i] - (m.usableWidth - p.width[i]) / 2 }
        let still = st.snappedScroll(from: centre(2) + 40, velocity: 0, settings: s, metrics: m)
        #expect(still.column == 2)
        #expect(abs(still.scroll - centre(2)) < 0.001)
        let flick = st.snappedScroll(from: centre(2) + 40, velocity: 3000, settings: s, metrics: m)
        #expect(flick.column == 3)
    }

    @Test func snapInNeverModeAlignsToAnEdge() {
        let s = layoutSettings(.never)
        let st = strip([1, 2, 3, 4, 5], focus: 0)
        let p = st.columnPositions(metrics: m)
        let r = st.snappedScroll(from: p.x[2] - 30, velocity: 0, settings: s, metrics: m)
        #expect(abs(r.scroll - p.x[2]) < 0.001)
        #expect(r.column == 2)
    }
}

@Suite struct PhysicalPlacementTests {
    let s = layoutSettings()

    @Test func onScreenFrameIsUnchanged() {
        let f = CGRect(x: 100, y: 35, width: 500, height: 500)
        #expect(Layout.physical(f, display: display(), settings: s) == .init(frame: f, hidden: false))
    }

    @Test func partlyOffScreenWithoutNeighbourStaysPartlyOff() {
        let f = CGRect(x: 1000, y: 35, width: 500, height: 500)
        #expect(Layout.physical(f, display: display(), settings: s).frame.minX == 1000)
    }

    @Test func partlyOffScreenTowardNeighbourIsFlush() {
        let f = CGRect(x: 900, y: 35, width: 500, height: 500) // 200 of 500 past the edge
        let p = Layout.physical(f, display: display(right: true), settings: s)
        #expect(p.frame.maxX == 1200 && !p.hidden)
        let l = Layout.physical(CGRect(x: -100, y: 35, width: 500, height: 500), display: display(left: true), settings: s)
        #expect(l.frame.minX == 0 && !l.hidden)
    }

    @Test func moreThanHalfTowardNeighbourParksOnTheOtherSide() {
        let f = CGRect(x: 1100, y: 35, width: 300, height: 500) // 200 of 300 past the edge
        let p = Layout.physical(f, display: display(right: true), settings: s)
        #expect(p.hidden)
        #expect(p.frame.maxX == 1) // parked on the left edge with a 1 pt sliver
    }

    @Test func outOfViewIsParkedAtTheBottomCornerWithASliver() {
        let p = Layout.physical(CGRect(x: 1500, y: 35, width: 400, height: 500), display: display(), settings: s)
        #expect(p.hidden)
        #expect(p.frame.minX == 1199 && p.frame.minY == 899)
        let l = Layout.physical(CGRect(x: -900, y: 35, width: 400, height: 500), display: display(), settings: s)
        #expect(l.hidden && l.frame.maxX == 1)
    }

    @Test func widthDoesNotChangeWhileTheStripScrolls() {
        // A fractional scroll offset must not change the size, or each frame is an extra AX resize.
        var widths = Set<CGFloat>()
        for step in 0..<40 {
            let f = CGRect(x: 100 + CGFloat(step) * 0.37, y: 35.5, width: 499.6, height: 500)
            widths.insert(Layout.physical(f, display: display(), settings: s).frame.width)
        }
        #expect(widths == [500])
        #expect(Layout.pixelAligned(CGRect(x: 10.4, y: 0.6, width: 99.5, height: 50.2)) == CGRect(x: 10, y: 1, width: 100, height: 50))
    }

    @Test func displayBelowKeepsYWhenParked() {
        let p = Layout.physical(CGRect(x: 1500, y: 35, width: 400, height: 500), display: display(below: true), settings: s)
        #expect(p.frame.minY == 35)
    }

    @Test func neighboursOnBothSidesParkBelowInsideTheDisplay() {
        let p = Layout.physical(CGRect(x: 1500, y: 35, width: 400, height: 500), display: display(left: true, right: true), settings: s)
        #expect(p.hidden && p.frame.minX >= 0 && p.frame.maxX <= 1200 && p.frame.minY == 899)
    }
}

@Suite struct SpringTests {
    @Test func reachesTargetAndSettles() {
        var sp = Spring(value: 0, response: 0.22)
        sp.retarget(1000, at: 0)
        #expect(sp.value(at: 0) == 0)
        #expect(abs(sp.value(at: 1) - 1000) < 0.01)
        #expect(sp.isSettled(at: 1))
        #expect(!sp.isSettled(at: 0.05))
    }

    @Test func criticallyDampedNeverOvershootsFromRest() {
        var sp = Spring(value: 0, response: 0.22)
        sp.retarget(1000, at: 0)
        var t = 0.0
        while t < 1 { #expect(sp.value(at: t) <= 1000.0001); t += 1.0 / 240 }
    }

    @Test func frameRateIndependent() {
        var a = Spring(value: 0, response: 0.22)
        a.retarget(500, at: 0)
        // Sampling at 60 Hz or 120 Hz gives the same value at the same time.
        #expect(a.value(at: 10.0 / 60) == a.value(at: 20.0 / 120))
    }

    @Test func retargetKeepsPositionAndVelocity() {
        var sp = Spring(value: 0, response: 0.22)
        sp.retarget(1000, at: 0)
        let x = sp.value(at: 0.05), v = sp.velocity(at: 0.05)
        sp.retarget(0, at: 0.05)
        #expect(abs(sp.value(at: 0.05) - x) < 1e-9)
        #expect(abs(sp.velocity(at: 0.05) - v) < 1e-9)
    }

    @Test func velocityMatchesNumericalDerivative() {
        var sp = Spring(value: 0, response: 0.3)
        sp.retarget(300, at: 0, velocity: 2000)
        let t = 0.07, h = 1e-6
        let numeric = (sp.value(at: t + h) - sp.value(at: t - h)) / (2 * h)
        #expect(abs(numeric - sp.velocity(at: t)) < 1e-3)
    }
}

@Suite struct AnimatorTests {
    @Test func newWindowsAppearAtTargetWithoutMotion() {
        var a = FrameAnimator()
        a.setTargets([1: CGRect(x: 0, y: 0, width: 100, height: 100)], at: 0, animate: true)
        #expect(a.isSettled(at: 0))
    }

    @Test func movesThenSettlesAndStopsWork() {
        var a = FrameAnimator()
        let r0 = CGRect(x: 0, y: 0, width: 100, height: 100)
        let r1 = CGRect(x: 500, y: 0, width: 200, height: 100)
        a.setTargets([1: r0], at: 0, animate: true)
        a.setTargets([1: r1], at: 1, animate: true)
        #expect(!a.isSettled(at: 1.05))
        let mid = a.frame(1, at: 1.05)!
        #expect(mid.minX > 0 && mid.minX < 500)
        #expect(a.isSettled(at: 2))
        #expect(a.frame(1, at: 2) == r1)
    }

    @Test func noAnimateJumps() {
        var a = FrameAnimator()
        a.setTargets([1: CGRect(x: 0, y: 0, width: 100, height: 100)], at: 0, animate: true)
        a.setTargets([1: CGRect(x: 300, y: 0, width: 100, height: 100)], at: 1, animate: false)
        #expect(a.frame(1, at: 1)!.minX == 300)
        #expect(a.isSettled(at: 1))
    }

    @Test func disabledAnimationJumps() {
        var a = FrameAnimator(enabled: false)
        a.setTargets([1: CGRect(x: 0, y: 0, width: 100, height: 100)], at: 0, animate: true)
        a.setTargets([1: CGRect(x: 300, y: 0, width: 100, height: 100)], at: 1, animate: true)
        #expect(a.isSettled(at: 1))
    }

    @Test func removedWindowsAreDropped() {
        var a = FrameAnimator()
        a.setTargets([1: .zero, 2: .zero], at: 0, animate: true)
        a.setTargets([2: .zero], at: 0, animate: true)
        #expect(a.windowIDs == [2])
    }

    @Test func releaseVelocityCarriesIntoSpring() {
        var a = FrameAnimator()
        let r = CGRect(x: 0, y: 0, width: 100, height: 100)
        a.setTargets([1: r], at: 0, animate: true)
        a.setTargets([1: r], at: 0, animate: true, velocityX: 3000)
        #expect(a.frame(1, at: 0.02)!.minX > 10)
    }

    // Round 3 finding: the Duration setting changed only windows added after the change.
    @Test func aNewDurationChangesWindowsAlreadyOnScreen() {
        let r0 = CGRect(x: 0, y: 0, width: 100, height: 100)
        let r1 = CGRect(x: 1000, y: 0, width: 100, height: 100)
        var slow = FrameAnimator(response: 0.22)
        slow.setTargets([1: r0], at: 0, animate: true)
        slow.setResponse(0.5, at: 0.5)
        slow.setTargets([1: r1], at: 1, animate: true)
        // A spring made with response 0.5 is the reference.
        var x = Spring(value: 0, response: 0.5)
        x.retarget(1000, at: 1)
        #expect(abs(Double(slow.frame(1, at: 1.1)!.minX) - x.value(at: 1.1)) < 0.001)
        #expect(slow.response == 0.5)
    }

    @Test func aNewDurationDuringMotionDoesNotJump() {
        let r0 = CGRect(x: 0, y: 0, width: 100, height: 100)
        let r1 = CGRect(x: 1000, y: 0, width: 100, height: 100)
        var a = FrameAnimator(response: 0.22)
        a.setTargets([1: r0], at: 0, animate: true)
        a.setTargets([1: r1], at: 1, animate: true)
        let before = a.frame(1, at: 1.05)!
        a.setResponse(0.6, at: 1.05)
        #expect(abs(a.frame(1, at: 1.05)!.minX - before.minX) < 0.001)
        // Slower now: less distance in the next 50 ms than the old spring would cover.
        var old = Spring(value: 0, response: 0.22)
        old.retarget(1000, at: 1)
        #expect(Double(a.frame(1, at: 1.10)!.minX) < old.value(at: 1.10))
        #expect(!a.isSettled(at: 1.6))
        #expect(a.isSettled(at: 4))
    }
}

@Suite struct LayoutBenchmarkTests {
    @Test func fiftyColumnsLayoutUnderBudget() {
        let d = display(), s = layoutSettings()
        var st = Strip()
        for i in 1...50 { st.insert(win(WindowID(i)), width: .proportion(0.5), focus: true) }
        // Stack every fifth window so the stack path is measured too.
        for i in stride(from: 45, through: 5, by: -5) {
            st.focusedColumn = i
            _ = st.apply(.stackLeft, settings: s, metrics: d.metrics(s))
        }
        let runs = 2000
        var sink = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<runs {
            let r = Layout.compute(st, display: d, settings: s, scroll: Double(i))
            for f in r.frames.values { sink &+= Int(Layout.physical(f, display: d, settings: s).frame.minX) }
        }
        let perRunMicros = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(runs) / 1000
        print("Layout + placement, 50 windows: \(String(format: "%.1f", perRunMicros)) µs per frame (sink \(sink))")
        // The budget is for the shipped (release) build; `make bench` runs it. Debug builds are ~6x slower.
        #if DEBUG
        #expect(perRunMicros < 200)
        #else
        #expect(perRunMicros < 50)
        #endif
    }
}

/// The frame Striple writes while a size animates: the origin follows the spring, the size holds.
@Suite struct WriteFrameTests {
    let small = CGRect(x: 0, y: 0, width: 100, height: 80)
    let big = CGRect(x: 400, y: 20, width: 300, height: 200)

    func animating(from a: CGRect, to b: CGRect) -> FrameAnimator {
        var anim = FrameAnimator()
        anim.setTargets([1: a], at: 0, animate: true)
        anim.setTargets([1: b], at: 1, animate: true)
        return anim
    }

    /// Times from the retarget until just before the animation settles.
    func moving(_ anim: FrameAnimator) -> [Double] {
        stride(from: 1.0, to: 3, by: 1.0 / 120).filter { !anim.isSettled(at: $0) }
    }

    @Test func aGrowingWindowGetsItsSizeOnTheFirstFrame() {
        var anim = animating(from: small, to: big)
        let w = anim.writeFrame(1, at: 1 + 1.0 / 60)!
        #expect(w.size == big.size)
        #expect(anim.frame(1, at: 1 + 1.0 / 60)!.width < big.width, "the drawn spring is still growing")
    }

    /// Each axis is held until its own spring settles. The size can settle before the origin: from then on the
    /// window has its target size.
    @Test func aShrinkingWindowKeepsItsSizeUntilItSettles() {
        var anim = animating(from: big, to: small)
        let times = moving(anim)
        #expect(times.count > 10)
        let frames = times.map { anim.writeFrame(1, at: $0)! }
        for axis in [\CGRect.width, \CGRect.height] {
            let values = frames.map { $0[keyPath: axis] }
            let held = values.prefix { $0 == big[keyPath: axis] }
            #expect(held.count > times.count / 2, "most of the animation keeps the old size")
            #expect(values.dropFirst(held.count).allSatisfy { $0 == small[keyPath: axis] }, "then the target, nothing between")
        }
        let end = times.last! + 1.0 / 120
        #expect(anim.writeFrame(1, at: end) == small)
    }

    /// The point of the policy: between two retargets the app gets at most two sizes, the held one and the
    /// target, so it lays out its window at most twice, not on every frame.
    @Test func theWrittenSizeDoesNotChangeBetweenRetargets() {
        for (a, b) in [(small, big), (big, small)] {
            var anim = animating(from: a, to: b)
            let widths = moving(anim).map { anim.writeFrame(1, at: $0)!.width }
            let changes = zip(widths, widths.dropFirst()).filter { $0 != $1 }.count
            #expect(changes <= 1)
            #expect(Set(widths).isSubset(of: [a.width, b.width]))
        }
    }

    @Test func theOriginStillAnimates() {
        var anim = animating(from: small, to: big)
        for t in moving(anim) {
            let drawn = anim.frame(1, at: t)!
            let written = anim.writeFrame(1, at: t)!
            #expect(written.origin == drawn.origin)
        }
        #expect(Set(moving(anim).map { anim.writeFrame(1, at: $0)!.minX }).count > 10)
    }

    /// A retarget during a shrink holds the size the window has at that moment, not the old start size.
    /// A retarget during a shrink (here: the strip scrolls, only x changes) keeps the size on screen. The spring
    /// is between the two sizes, but the window is not: writing the spring value would be one more resize
    /// (critic round 2).
    @Test func aRetargetKeepsTheSizeOnScreen() {
        var anim = animating(from: big, to: small)
        #expect(anim.frame(1, at: 1.05)!.width < big.width, "the spring is between the two sizes")
        #expect(anim.writeFrame(1, at: 1.05)!.size == big.size)
        let scrolled = small.offsetBy(dx: 50, dy: 0)
        anim.setTargets([1: scrolled], at: 1.05, animate: true)
        #expect(anim.writeFrame(1, at: 1.06)!.size == big.size)
        let frames = moving(anim).filter { $0 > 1.06 }.map { anim.writeFrame(1, at: $0)! }
        for axis in [\CGRect.width, \CGRect.height] {
            let values = Set(frames.map { $0[keyPath: axis] })
            #expect(values.isSubset(of: [big[keyPath: axis], small[keyPath: axis]]), "no size between the two: \(values)")
        }
        #expect(anim.writeFrame(1, at: 9) == scrolled)
    }

    /// A retarget to a size between the size on screen and the old target holds the size on screen.
    @Test func aRetargetToALargerTargetDuringAShrinkHoldsTheSizeOnScreen() {
        var anim = animating(from: big, to: small)
        let between = CGRect(x: 0, y: 0, width: 200, height: 150)
        anim.setTargets([1: between], at: 1.05, animate: true)
        #expect(anim.writeFrame(1, at: 1.06)!.size == big.size)
        var grow = animating(from: small, to: CGRect(x: 0, y: 0, width: 200, height: 150))
        grow.setTargets([1: big], at: 1.05, animate: true)
        #expect(grow.writeFrame(1, at: 1.06)!.size == big.size, "a growing window gets the new, larger target")
    }

    /// A new speed (`setResponse`, a config reload) retargets every spring: the size on screen stays.
    @Test func aNewSpeedKeepsTheSizeOnScreen() {
        var anim = animating(from: big, to: small)
        anim.setResponse(0.4, at: 1.05)
        #expect(anim.writeFrame(1, at: 1.06)!.size == big.size)
    }

    /// `setCurrent` starts from the frame on screen: that size is held.
    @Test func setCurrentHoldsTheFrameOnScreen() {
        var anim = animating(from: big, to: small)
        anim.setCurrent(1, frame: CGRect(x: 10, y: 10, width: 250, height: 180), at: 1.05)
        #expect(anim.writeFrame(1, at: 1.06)!.size == CGSize(width: 250, height: 180))
    }

    /// Width and height are separate: a window that gets wider and lower writes the larger value of each.
    @Test func eachAxisHoldsItsLargerValue() {
        let wideLow = CGRect(x: 0, y: 0, width: 300, height: 80)
        var anim = animating(from: CGRect(x: 0, y: 0, width: 100, height: 200), to: wideLow)
        let w = anim.writeFrame(1, at: 1.05)!
        #expect(w.width == 300)
        #expect(w.height == 200)
    }

    @Test func aSettledWindowWritesItsTarget() {
        var anim = animating(from: small, to: big)
        #expect(anim.writeFrame(1, at: 5) == big)
        #expect(anim.writeFrame(2, at: 5) == nil)
        var still = FrameAnimator()
        still.setTargets([1: small], at: 0, animate: true)
        #expect(still.writeFrame(1, at: 0) == small)
    }

    /// With animations off every frame is the target at once.
    @Test func disabledAnimationsWriteTheTarget() {
        var anim = FrameAnimator(enabled: false)
        anim.setTargets([1: small], at: 0, animate: true)
        anim.setTargets([1: big], at: 1, animate: true)
        #expect(anim.writeFrame(1, at: 1) == big)
    }

    /// Critic round 4, issue 1: a spring that was retargeted while it moved can enter the settle band and leave
    /// it again. The width it gave (the target) must stay: before the fix the window went 400, 800, 400.
    /// Frames at 60 Hz as `Engine.tick` writes them; a shrink 800 -> 300 from rest (started now, or one frame
    /// early as `Engine.animationStart` does), then 400 after `gap`. The case needs an exact gap (53.5 ms with the
    /// early start, 70.25 ms without), so the gaps go in 0.25 ms steps.
    @Test func aSizeThatReachedItsTargetKeepsIt() {
        let tick = 1.0 / 60
        var bandExits = 0
        for lead in [0, tick] {
            for gapUs in stride(from: 20000, to: 350000, by: 250) {
                let gap = Double(gapUs) / 1_000_000
                var anim = FrameAnimator()
                anim.setTargets([1: CGRect(x: 0, y: 0, width: 800, height: 600)], at: 0, animate: true)
                _ = anim.writeFrame(1, at: 0)
                var spring = Spring(value: 800, response: anim.response)
                anim.setTargets([1: CGRect(x: 0, y: 0, width: 300, height: 600)], at: 10 - lead, animate: true)
                spring.retarget(300, at: 10 - lead)
                var k = 0
                while 10 + Double(k) * tick < 10 + gap { _ = anim.writeFrame(1, at: 10 + Double(k) * tick); k += 1 }
                anim.setTargets([1: CGRect(x: 0, y: 0, width: 400, height: 600)], at: 10 + gap, animate: true)
                spring.retarget(400, at: 10 + gap)
                var given: [Double] = []
                var wasSettled = false
                while 10 + Double(k) * tick < 12 {
                    let t = 10 + Double(k) * tick
                    given.append(Double(anim.writeFrame(1, at: t)!.width))
                    let settled = spring.isSettled(at: t)
                    if wasSettled && !settled { bandExits += 1 }
                    wasSettled = settled
                    k += 1
                }
                let reached = given.firstIndex(of: 400) ?? given.count
                #expect(given.dropFirst(reached).allSatisfy { $0 == 400 }, "gap \(gapUs) us: \(given)")
                #expect(given.allSatisfy { [800, 300, 400].contains($0) })
                #expect(given.last == 400)
            }
        }
        #expect(bandExits > 0, "the case happens: the width spring leaves the settle band after it entered it")
    }

    /// Critic round 4, issue 2: two commands within one frame (no write between them). The second one holds the
    /// size that was written (800), not the target of the first one (1000), which no frame gave.
    @Test func twoRetargetsWithinOneFrameHoldTheSizeOnScreen() {
        var anim = FrameAnimator()
        anim.setTargets([1: CGRect(x: 0, y: 0, width: 800, height: 600)], at: 0, animate: true)
        anim.setTargets([1: CGRect(x: 200, y: 0, width: 800, height: 600)], at: 1, animate: true)
        #expect(anim.writeFrame(1, at: 1.01)!.width == 800)
        anim.setTargets([1: CGRect(x: 200, y: 0, width: 1000, height: 600)], at: 1.02, animate: true)
        anim.setTargets([1: CGRect(x: 200, y: 0, width: 600, height: 600)], at: 1.026, animate: true)
        let widths = stride(from: 1.03, to: 3, by: 1.0 / 60).map { anim.writeFrame(1, at: $0)!.width }
        #expect(Set(widths) == [800, 600], "\(Set(widths))")
    }

    /// The variant: the width settled, but no frame was written after that (a missed tick), so the window still has
    /// the held size. A retarget then holds that size, not the target that the model reached.
    @Test func aRetargetAfterAMissedSettleFrameHoldsTheSizeOnScreen() {
        var anim = animating(from: big, to: small)
        #expect(anim.writeFrame(1, at: 1.05)!.width == big.width)
        let between = CGRect(x: 0, y: 0, width: 200, height: 150)
        anim.setTargets([1: between], at: 4, animate: true)
        let widths = stride(from: 4.0, to: 6, by: 1.0 / 60).map { anim.writeFrame(1, at: $0)!.width }
        #expect(Set(widths).isSubset(of: [big.width, between.width]), "\(Set(widths))")
        #expect(widths.first == big.width)
        #expect(widths.last == between.width)
    }

    @Test func writeFramesHasEveryWindow() {
        var anim = FrameAnimator()
        anim.setTargets([1: small, 2: big], at: 0, animate: true)
        anim.setTargets([1: big, 2: small], at: 1, animate: true)
        let all = anim.writeFrames(at: 1.05)
        #expect(all.count == 2)
        #expect(all[1] == anim.writeFrame(1, at: 1.05))
        #expect(all[2] == anim.writeFrame(2, at: 1.05))
    }
}
