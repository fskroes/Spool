import ApplicationServices
import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import StripleCore
@testable import StripleEngine

/// Records every frame the engine sends. The engine under test has no AX: its windows belong to a pid that does
/// not exist, and its frames go here.
private final class RecordingWriter: FrameWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(id: WindowID, frame: CGRect)] = []

    func write(_ write: FrameWrite, previous: CGRect?) -> WriteResult {
        lock.withLock { log.append((write.id, write.frame)) }
        return .written
    }

    func frames(_ id: WindowID) -> [CGRect] { lock.withLock { log.filter { $0.id == id }.map(\.frame) } }

    /// Waits until window `id` got more than `count` frames (the applier writes on its own queues).
    func waitForFrame(_ id: WindowID, after count: Int) -> CGRect? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let f = frames(id)
            if f.count > count { return f[count] }
            usleep(1000)
        }
        return nil
    }
}

/// A frame clock that fires only when a test calls `TestEngine.nextFrame`.
@MainActor
private final class StillTicker: FrameTicker {
    let period: Double
    private(set) var isRunning = false
    init(period: Double) { self.period = period }
    func start() { isRunning = true }
    func stop() { isRunning = false }
}

/// An engine with two displays side by side (A: 2056 x 1329, the main display; B: 1920 x 1080 to its right) and
/// tiled windows on A (1, 2, 3 by default), at rest. No hotkeys, no AX, no display link, and no session file: `stop` ends with the
/// engine stopped, so the delayed session save does nothing.
@MainActor
private struct TestEngine {
    let engine: Engine
    let writer = RecordingWriter()
    let ticker: StillTicker
    let a = Engine.StripKey(display: "A", space: 1)
    let b = Engine.StripKey(display: "B", space: 2)
    init(period: Double = 1.0 / 60, ids: [WindowID] = [1, 2, 3]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-engine-test-\(UUID().uuidString)")
        engine = Engine(configStore: ConfigStore(fileURL: dir.appendingPathComponent("config.json"), watch: false),
                        frameWriter: writer, registersHotkeys: false)
        ticker = StillTicker(period: period)
        engine.ticker = ticker
        engine.config.appearance.minimap = false
        engine.status = .running
        engine.displays = [
            EngineDisplay(uuid: "A", cgID: 1, name: "A",
                          geometry: DisplayGeometry(frame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
                                                    usable: CGRect(x: 0, y: 39, width: 2056, height: 1290),
                                                    neighborRight: true)),
            EngineDisplay(uuid: "B", cgID: 2, name: "B",
                          geometry: DisplayGeometry(frame: CGRect(x: 2056, y: 0, width: 1920, height: 1080),
                                                    usable: CGRect(x: 2056, y: 25, width: 1920, height: 1055),
                                                    neighborLeft: true)),
        ]
        engine.activeSpaces = ["A": 1, "B": 2]
        let pid = Self.unusedPID()
        var strip = Strip()
        for id in ids {
            let info = WindowInfo(id: id, pid: pid, bundleID: "com.example.test", title: "W\(id)")
            strip.insert(info, width: .proportion(0.5), focus: true)
            engine.windows[id] = Engine.ManagedWindow(info: info, element: AXUIElementCreateApplication(pid),
                                                      state: .tiled, key: a, createdAt: 0)
        }
        strip.setFocus(ids[0])
        engine.strips[a] = strip
        engine.relayout(a, animate: false)
        // The applier writes on its own queues: wait until they are empty, so a test counts only its own frames.
        _ = engine.applier.settleAndWait(timeout: 2)
    }

    /// The first frame written to `id` after `count` frames: the kick frame, or, when an animation already runs
    /// (the link writes then, not the kick), the display refresh one period after `since`. A fixed time, so the
    /// frame does not depend on how long the test took.
    /// The applier queues are drained first: a kick frame that is still queued must not count as "no frame yet",
    /// else the extra tick would replace it with a later one.
    func firstFrame(_ id: WindowID, after count: Int, since: Double) -> CGRect? {
        _ = engine.applier.settleAndWait(timeout: 2)
        if ticker.isRunning, writer.frames(id).count == count { engine.tick(since + ticker.period) }
        return writer.waitForFrame(id, after: count)
    }

    func stop() {
        engine.status = .stopped
        engine.sessionSaveWork?.cancel()
    }

    /// A pid with no process, so `Focuser` and AX find nothing to act on.
    static func unusedPID() -> pid_t {
        var pid: pid_t = 99_000
        while kill(pid, 0) == 0 || errno != ESRCH { pid += 1 }
        return pid
    }

    func placed(_ id: WindowID) -> CGRect { engine.placements[id]!.frame }
}

private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat { hypot(a.minX - b.minX, a.minY - b.minY) }

/// Follow-up of the sub-ms frames work, the drop flash: `mouseUp` wrote a frame at the dragged window's old slot,
/// and only then moved its spring to where the user let go. These tests drive `finishDrag` (all of `mouseUp` after
/// its AX reads), so they also fail when the call order in the engine comes back.
@MainActor
@Suite struct EngineDropTests {
    @Test func aReorderDropStartsWhereTheUserLetGo() throws {
        let t = TestEngine()
        defer { t.stop() }
        let old = t.placed(2)
        let written = t.writer.frames(2).count
        let since = CACurrentMediaTime()
        let dropped = CGRect(x: 300, y: 200, width: old.width, height: old.height)
        // Drop window 2 over column 1: it moves to the first place.
        t.engine.finishDrag(.init(id: 2, resize: false), at: CGPoint(x: 100, y: 500), dropped: dropped)
        #expect(t.engine.strips[t.a]?.columns.first?.windows.first?.id == 2, "the drop reordered the strip")
        let first = try #require(t.firstFrame(2, after: written, since: since), "the drop wrote a frame")
        #expect(distance(first, dropped) < 60, "the first frame \(first) starts at the drop \(dropped)")
        #expect(distance(first, old) > 300, "the first frame \(first) is not the old slot \(old)")
        #expect(distance(t.placed(2), dropped) < 60)
    }

    @Test func aPutBackDropStartsWhereTheUserLetGo() throws {
        let t = TestEngine()
        defer { t.stop() }
        let old = t.placed(2)
        let written = t.writer.frames(2).count
        let since = CACurrentMediaTime()
        let dropped = CGRect(x: old.minX - 400, y: old.minY + 150, width: old.width, height: old.height)
        // Outside every display: the window goes back to its own slot.
        t.engine.finishDrag(.init(id: 2, resize: false), at: CGPoint(x: -500, y: -500), dropped: dropped)
        let first = try #require(t.firstFrame(2, after: written, since: since))
        #expect(distance(first, dropped) < 60, "the first frame \(first) starts at the drop \(dropped)")
    }

    /// The window is new in the strip of display B. When it was the last window of A, nothing animates on A, so
    /// the kick of B's strip wrote the first frame: without the fix, its target on B. With windows left on A, the
    /// kick of A starts the display link, and its next refresh writes the first frame on B. B's springs then start
    /// with no lead (`Engine.animationLead`), so that frame has one period of motion, not two.
    @Test(arguments: [[2], [1, 2, 3]] as [[WindowID]])
    func aDropOnAnotherDisplayStartsWhereTheUserLetGo(ids: [WindowID]) throws {
        let t = TestEngine(ids: ids)
        defer { t.stop() }
        let old = t.placed(2)
        let written = t.writer.frames(2).count
        let since = CACurrentMediaTime()
        let dropped = CGRect(x: 2600, y: 300, width: old.width, height: old.height)
        t.engine.finishDrag(.init(id: 2, resize: false), at: CGPoint(x: 2700, y: 400), dropped: dropped)
        #expect(t.engine.windows[2]?.key == t.b, "the window went to display B")
        let target = try #require(t.engine.animators[t.b]?.target(2))
        let first = try #require(t.firstFrame(2, after: written, since: since))
        #expect(distance(first, dropped) < 60, "the first frame \(first) starts at the drop \(dropped)")
        #expect(distance(first, target) > 300, "the first frame \(first) is not the target \(target)")
    }

    @Test func withAnimationsOffADropGoesStraightToTheSlot() throws {
        let t = TestEngine()
        defer { t.stop() }
        t.engine.config.animation.enabled = false
        t.engine.animators = [:]
        t.engine.relayout(t.a, animate: false)
        let old = t.placed(2)
        let dropped = CGRect(x: 300, y: 200, width: old.width, height: old.height)
        t.engine.finishDrag(.init(id: 2, resize: false), at: CGPoint(x: 100, y: 500), dropped: dropped)
        let target = try #require(t.engine.animators[t.a]?.target(2))
        #expect(t.engine.animators[t.a]?.frame(2, at: CACurrentMediaTime()) == target)
        #expect(!t.ticker.isRunning, "nothing animates")
    }
}

/// Follow-up of the sub-ms frames work, the first frame on a 120 Hz display: `relayout` takes the lead of an
/// animation from rest from the frame clock's period, not a fixed 1/60 s.
@MainActor
@Suite struct EngineLeadTests {
    /// The first step of `focus-right`-like scroll: the kick frame of a retarget from rest.
    func kickStep(period: Double) -> CGFloat {
        let t = TestEngine(period: period)
        defer { t.stop() }
        let before = t.placed(1)
        t.engine.strips[t.a]?.scroll += 400
        t.engine.relayout(t.a)
        return before.minX - t.placed(1).minX
    }

    @Test func theKickStepFollowsTheDisplayPeriod() {
        let slow = kickStep(period: 1.0 / 48)
        let normal = kickStep(period: 1.0 / 60)
        let fast = kickStep(period: 1.0 / 120)
        let fastest = kickStep(period: 1.0 / 240)
        #expect(fastest > 0.1, "the kick frame moved at 240 Hz")
        #expect(fastest < fast && fast < normal && normal < slow,
                "steps 48 Hz \(slow), 60 Hz \(normal), 120 Hz \(fast), 240 Hz \(fastest)")
    }
}
