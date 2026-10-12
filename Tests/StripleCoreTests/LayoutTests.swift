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
