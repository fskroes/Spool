import Foundation
import Testing
@testable import StripleCore
@testable import StripleEngine

// The engine side of the local metrics (F24). Pure: no AX, no window, no process. Files only in a temp folder.

@Suite struct EngineMetricsHelperTests {
    @Test func floatFriction() {
        #expect(Engine.floatFriction(state: .tiled, userFloating: false, offDisplay: false) == .floatTiled)
        // Floated by a rule or the smart check: tiling it is friction.
        #expect(Engine.floatFriction(state: .floating, userFloating: false, offDisplay: false) == .unfloatAuto)
        // The user floated it, or it floats because its display is off: no friction.
        #expect(Engine.floatFriction(state: .floating, userFloating: true, offDisplay: false) == nil)
        #expect(Engine.floatFriction(state: .floating, userFloating: false, offDisplay: true) == nil)
        for state: Engine.ManagedWindow.State in [.minimized, .hidden, .fullscreen] {
            #expect(Engine.floatFriction(state: state, userFloating: false, offDisplay: false) == nil)
        }
    }

    @Test func wallClockOfAMediaTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Engine.wallClock(mediaTime: 95, now: now, mediaNow: 100) == now.addingTimeInterval(-5))
        // A window from before Striple started is never "early".
        #expect(Engine.wallClock(mediaTime: 0, now: now, mediaNow: 100) == .distantPast)
    }

    @Test func logTextReadsTheRotatedFileFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-metrics-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("engine.log")
        #expect(Engine.logText(log) == "")
        try Data("old 1\nold 2\n".utf8).write(to: log.appendingPathExtension("1"))
        try Data("new 1\n".utf8).write(to: log)
        #expect(Engine.logText(log) == "old 1\nold 2\nnew 1\n")
        // A long file: only the end, from the first whole line.
        try Data("aaaa\nbbbb\ncccc\n".utf8).write(to: log)
        #expect(Engine.logText(log, maxBytes: 8) == "old 2\ncccc\n")
    }
}

/// Uses `MetricsStore`: needs the Core metrics types.
@Suite struct MetricsSinkTests {
    @Test func recordsWritesOfKnownApps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-metrics-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MetricsStore(directory: dir, appVersion: "test")
        let sink = MetricsSink()
        let write = FrameApplier.WriteTiming(pid: 42, axMs: 3, latencyMs: 4)
        sink.record(write: write)
        #expect(store.snapshot().apps.isEmpty)
        sink.set(store)
        sink.record(write: write)
        #expect(store.snapshot().apps.isEmpty, "a pid without a bundle ID is not recorded")
        sink.setBundle("", for: 42)
        sink.record(write: write)
        #expect(store.snapshot().apps.isEmpty)
        sink.setBundle("com.example.app", for: 42)
        sink.record(write: write)
        var failed = write
        failed.failed = true
        sink.record(write: failed)
        let app = try #require(store.snapshot().apps["com.example.app"])
        #expect(app.axWrite.count == 2)
        #expect(app.axErrors == 1)
        sink.forget(pid: 42)
        sink.record(write: write)
        #expect(store.snapshot().apps["com.example.app"]?.axWrite.count == 2)
        sink.setBundle("com.example.app", for: 42)
        sink.set(nil)
        sink.record(write: write)
        #expect(store.snapshot().apps["com.example.app"]?.axWrite.count == 2)
    }

    @Test func recordTickFeedsTheStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-metrics-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MetricsStore(directory: dir, appVersion: "test")
        let recorder = StatsRecorder()
        Engine.recordTick(recorder, metrics: store, commandStart: nil)(2.5)
        Engine.recordTick(recorder, metrics: store, commandStart: 0)(3)
        Engine.recordTick(recorder, metrics: store, commandStart: 0)(nil)
        let day = store.snapshot()
        #expect(day.frameWrite.count == 2)
        #expect(day.commandLatency.count == 1)
        #expect(recorder.snapshot().batches == 2)
    }

    /// F3: a write on the tick that ends the animation records the settle with the latency value; a dropped
    /// write records neither.
    @Test func aSettleAtWriteIsTheLatency() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-metrics-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MetricsStore(directory: dir, appVersion: "test")
        let recorder = StatsRecorder()
        Engine.recordTick(recorder, metrics: store, commandStart: 10, settleAtWrite: true, now: { 10.0625 })(3)
        Engine.recordTick(recorder, metrics: store, commandStart: 10, settleAtWrite: true, now: { 10.0625 })(nil)
        Engine.recordTick(recorder, metrics: store, commandStart: 10, settleAtWrite: false, now: { 10.0625 })(3)
        let day = store.snapshot()
        #expect(day.commandLatency.count == 2)
        #expect(day.commandSettle.count == 1)
        #expect(day.commandSettle.sum == 62.5)
        #expect(day.commandSettle.max == 62.5)
    }
}

extension CommandClock {
    /// One tick: the decision before the write, then the write's result.
    @discardableResult
    mutating func tick(moved: Bool = true, queued: Bool = true, settles: Bool = false) -> TickStart? {
        let taken = tickStart(moved: moved, settles: settles)
        ticked(taken, queued: queued)
        return taken
    }
}

/// D1, D8, E1 to E3, F1 to F3: latency and settle come only from a command that moves a window.
@Suite struct CommandClockTests {
    @Test func aCommandThatChangedNothingHasNoLatency() {
        var clock = CommandClock()
        clock.commandStarted(at: 10, swiping: false)
        // focus-left at the first column: no target changed.
        clock.performEnded(changedTargets: false)
        // Minutes later a new window opens: its frames are not the command's.
        clock.tick()
        let settle = clock.settled(at: 200)
        #expect(clock.pending == nil)
        #expect(settle == nil)
    }

    @Test func fromRestTheFirstLinkTickTakesTheStart() {
        var clock = CommandClock()
        clock.commandStarted(at: 10, swiping: false)
        // The kick tick inside perform has dt = 0: every frame is where Striple placed the window.
        clock.tick(moved: false)
        clock.performEnded(changedTargets: true)
        #expect(clock.pending == 10)
        #expect(clock.settling == nil)
        // The first display link tick (dt > 0) moves the windows.
        clock.tick()
        #expect(clock.pending == nil)
        #expect(clock.settling == 10)
        clock.tick()
        let settle = clock.settled(at: 10.25)
        let later = clock.settled(at: 11)
        #expect(settle == 250)
        #expect(later == nil, "a later animation does not inherit the settle")
    }

    /// F1: a slow app still writes the last frame of the animation before. The kick tick gives the same frame:
    /// `apply` waits for that write, but it is the old frame, not the command's.
    @Test func aFrameEqualToTheOneInFlightDoesNotTakeTheStart() {
        var clock = CommandClock()
        clock.commandStarted(at: 10, swiping: false)
        let kick = clock.tick(moved: false, queued: true)
        clock.performEnded(changedTargets: true)
        #expect(kick == nil)
        #expect(clock.pending == 10)
        let link = clock.tick(moved: true, queued: true)
        #expect(link == CommandClock.TickStart(start: 10, settleAtWrite: false))
        #expect(clock.settling == 10)
    }

    @Test func aMoveThatTheApplierDidNotQueueKeepsTheStart() {
        var clock = CommandClock()
        clock.commandStarted(at: 10, swiping: false)
        clock.performEnded(changedTargets: true)
        clock.tick(moved: true, queued: false)
        #expect(clock.pending == 10)
        #expect(clock.settling == nil)
    }

    /// F2: command B that changes nothing comes while the start of command A waits for its first link tick.
    @Test func aNoOpCommandKeepsTheStartThatWaits() {
        var clock = CommandClock()
        clock.commandStarted(at: 10, swiping: false)
        clock.tick(moved: false)
        clock.performEnded(changedTargets: true)
        clock.commandStarted(at: 10.25, swiping: false)
        clock.performEnded(changedTargets: false)
        #expect(clock.pending == 10)
        clock.tick()
        let settle = clock.settled(at: 10.5)
        #expect(settle == 500)
    }

    /// F3: with animations off, the first tick writes the targets and the animation ends on the same tick.
    @Test func aSettleOnTheTickOfTheFirstWriteComesWithTheWrite() {
        var clock = CommandClock()
        clock.commandStarted(at: 10, swiping: false)
        let taken = clock.tick(moved: true, queued: true, settles: true)
        clock.performEnded(changedTargets: true)
        let settle = clock.settled(at: 10)
        #expect(taken == CommandClock.TickStart(start: 10, settleAtWrite: true))
        #expect(settle == nil, "the write's completion records it, not this ~0 ms value")
        #expect(clock.pending == nil)
        #expect(clock.settling == nil)
    }

    @Test func anAnimationThatSettlesWithoutAWriteGivesNoSample() {
        var clock = CommandClock()
        clock.commandStarted(at: 10, swiping: false)
        clock.tick(moved: false)
        clock.performEnded(changedTargets: true)
        clock.tick(moved: false)
        let settle = clock.settled(at: 10.1)
        #expect(settle == nil)
        #expect(clock.pending == nil)
        // The next animation (a new window, no command) does not take the old start.
        clock.tick()
        #expect(clock.settling == nil)
    }

    @Test func aNoOpCommandDuringAnAnimationKeepsTheSettleOfTheCommandBeforeIt() {
        var clock = CommandClock()
        clock.commandStarted(at: 10, swiping: false)
        clock.performEnded(changedTargets: true)
        clock.tick()
        // focus-left at the first column while the scroll animates.
        clock.commandStarted(at: 10.1, swiping: false)
        clock.performEnded(changedTargets: false)
        clock.tick()
        #expect(clock.pending == nil)
        let settle = clock.settled(at: 10.5)
        #expect(settle == 500)
    }

    @Test func aCommandThatMovesDuringAnAnimationTakesOver() {
        var clock = CommandClock()
        clock.commandStarted(at: 10, swiping: false)
        clock.performEnded(changedTargets: true)
        clock.tick()
        clock.commandStarted(at: 12, swiping: false)
        clock.performEnded(changedTargets: true)
        clock.tick()
        let settle = clock.settled(at: 12.5)
        #expect(settle == 500)
    }

    @Test func aCommandDuringASwipeHasNoSample() {
        var clock = CommandClock()
        clock.swipeBegan()
        clock.commandStarted(at: 10, swiping: true)
        clock.performEnded(changedTargets: true)
        clock.tick()
        let settle = clock.settled(at: 12)
        #expect(clock.pending == nil)
        #expect(settle == nil)
    }

    @Test func aSwipeDropsTheCommandBeforeIt() {
        var clock = CommandClock()
        clock.commandStarted(at: 10, swiping: false)
        clock.performEnded(changedTargets: true)
        clock.tick()
        clock.commandStarted(at: 11, swiping: false)
        clock.performEnded(changedTargets: true)
        clock.swipeBegan()
        #expect(clock.pending == nil)
        // The swipe's own animation (no command): no latency and no settle sample.
        clock.tick()
        let settle = clock.settled(at: 30)
        #expect(settle == nil)
    }
}

/// D2: one flush after the first change, nothing while clean, a growing wait after a failed write.
@Suite struct MetricsFlushPlanTests {
    @Test func delays() {
        let minutes = (0...8).map { MetricsFlushPlan.delay(failures: $0) / 60 }
        #expect(minutes == [1, 2, 4, 8, 16, 32, 60, 60, 60])
        #expect(MetricsFlushPlan.delay(failures: .max) == 3600)
    }

    @Test func oneFlushPerChange() {
        var plan = MetricsFlushPlan()
        let a = plan.changed(dirty: true)
        let b = plan.changed(dirty: true)
        plan.fired()
        plan.writeStarted()
        let end = plan.writeEnded(error: nil, dirty: true)
        let c = plan.changed(dirty: true)
        #expect(a == 60)
        #expect(b == nil)
        #expect(end.log == false && end.schedule == nil)
        #expect(c == 60)
    }

    @Test func aFailureWaitsLongerAndLogsEachErrorOnce() {
        var plan = MetricsFlushPlan()
        var ends: [(log: Bool, schedule: TimeInterval?)] = []
        _ = plan.changed(dirty: true)
        plan.fired()
        plan.writeStarted()
        // The store kept the data and called back during the write.
        let during = plan.changed(dirty: true)
        ends.append(plan.writeEnded(error: "disk full", dirty: true))
        for error in ["disk full", "no permission"] {
            plan.fired()
            plan.writeStarted()
            _ = plan.changed(dirty: true)
            ends.append(plan.writeEnded(error: error, dirty: true))
        }
        plan.fired()
        plan.writeStarted()
        ends.append(plan.writeEnded(error: nil, dirty: true))
        let after = plan.changed(dirty: true)
        #expect(during == nil)
        #expect(ends.map(\.log) == [true, false, true, false])
        #expect(ends.map(\.schedule) == [120, 240, 480, nil])
        #expect(plan.failures == 0)
        #expect(after == 60)
    }

    @Test func aLateCallbackForSavedDataSchedulesNothing() {
        var plan = MetricsFlushPlan()
        let late = plan.changed(dirty: false)
        let next = plan.changed(dirty: true)
        #expect(late == nil)
        #expect(next == 60, "nothing stuck: the next real change schedules")
        var during = MetricsFlushPlan()
        during.writeStarted()
        _ = during.changed(dirty: true)
        let end = during.writeEnded(error: nil, dirty: false)
        #expect(end.schedule == nil)
        #expect(during.changed(dirty: true) == 60)
    }

    @Test func aSyncFailureSchedulesWhenTheCallbackComes() {
        var plan = MetricsFlushPlan()
        plan.writeStarted()
        let end = plan.writeEnded(error: "x", dirty: true)
        let next = plan.changed(dirty: true)
        #expect(end.log == true && end.schedule == nil)
        #expect(next == 120)
    }
}

/// D2, D9: the flusher with a fake timer, inline queues and a real store in a temp folder.
@Suite @MainActor struct MetricsFlusherTests {
    final class Timers {
        var pending: [@MainActor () -> Void] = []
        var delays: [TimeInterval] = []
        @MainActor func fire() {
            let all = pending
            pending = []
            for body in all { body() }
        }
    }

    final class LogBox { var lines: [String] = [] }

    final class HopBox: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [@MainActor @Sendable () -> Void] = []
        func add(_ body: @escaping @MainActor @Sendable () -> Void) { lock.withLock { bodies.append(body) } }
        @MainActor func run() {
            let all = lock.withLock { let b = bodies; bodies = []; return b }
            for body in all { body() }
        }
    }

    struct Rig {
        let store: MetricsStore
        let flusher: MetricsFlusher
        let timers: Timers
        let logs: LogBox
    }

    static func rig(_ dir: URL) -> Rig {
        let store = MetricsStore(directory: dir, appVersion: "test")
        let timers = Timers()
        let logs = LogBox()
        let flusher = MetricsFlusher(store: store,
                                     schedule: { delay, body in timers.delays.append(delay); timers.pending.append(body) },
                                     background: { $0() },
                                     toMain: { body in MainActor.assumeIsolated { body() } },
                                     log: { logs.lines.append($0) })
        flusher.connect()
        return Rig(store: store, flusher: flusher, timers: timers, logs: logs)
    }

    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("striple-metrics-test-\(UUID().uuidString)")
    }

    static func dayFiles(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }
    }

    @Test func oneFlushAfterTheFirstChangeAndNoneWhileClean() {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Self.rig(dir)
        #expect(r.timers.delays.isEmpty)
        r.store.record(command: .focusLeft, source: .hotkey)
        r.store.record(command: .focusRight, source: .cli)
        #expect(r.timers.delays == [60])
        r.timers.fire()
        #expect(Self.dayFiles(dir).count == 1)
        #expect(!r.store.hasUnsavedChanges)
        // Clean: the timer does not come back.
        #expect(r.timers.pending.isEmpty)
        r.flusher.flush(sync: false)
        #expect(r.timers.delays == [60])
        r.store.record(command: .focusLeft, source: .hotkey)
        #expect(r.timers.delays == [60, 60])
    }

    @Test func aFailedWriteWaitsLongerAndLogsOnce() throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A plain file where the folder must be: every write fails.
        try Data().write(to: dir)
        let r = Self.rig(dir)
        r.store.record(command: .focusLeft, source: .hotkey)
        r.timers.fire()
        r.timers.fire()
        r.timers.fire()
        #expect(r.timers.delays == [60, 120, 240, 480])
        #expect(r.logs.lines.count == 1)
        #expect(r.logs.lines.first?.contains("could not save the day file, next try in 120 s") == true)
        try FileManager.default.removeItem(at: dir)
        r.timers.fire()
        #expect(Self.dayFiles(dir).count == 1)
        #expect(r.timers.pending.isEmpty)
        #expect(r.logs.lines.last == "metrics: saved the day file again")
        r.store.record(command: .focusLeft, source: .hotkey)
        #expect(r.timers.delays.last == 60)
    }

    @Test func theErrorTextIsStable() {
        let a = NSError(domain: NSCocoaErrorDomain, code: 516, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 17)])
        let b = NSError(domain: NSCocoaErrorDomain, code: 516, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 17)])
        #expect(MetricsFlusher.describe(a) == MetricsFlusher.describe(b))
        #expect(MetricsFlusher.describe(a).hasPrefix("NSCocoaErrorDomain 516: "))
        #expect(!MetricsFlusher.describe(a).contains("0x"))
    }

    /// E4: in the app the callback comes on a later main queue pass, after a forced sync write saved the change.
    @Test func aForcedSyncFlushLeavesNoTimer() {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MetricsStore(directory: dir, appVersion: "test")
        let timers = Timers()
        let hops = HopBox()
        let flusher = MetricsFlusher(store: store,
                                     schedule: { delay, body in timers.delays.append(delay); timers.pending.append(body) },
                                     background: { $0() },
                                     toMain: { body in hops.add(body) },
                                     log: { _ in })
        flusher.connect()
        flusher.beforeWrite = { store.recordActive(seconds: 5) }
        flusher.flush(sync: true, force: true)
        hops.run()
        #expect(Self.dayFiles(dir).count == 1)
        #expect(!store.hasUnsavedChanges)
        #expect(timers.delays.isEmpty)
        store.record(command: .focusLeft, source: .hotkey)
        hops.run()
        #expect(timers.delays == [60])
    }

    @Test func offRecordsAndWritesNothing() {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Self.rig(dir)
        r.store.isEnabled = false
        var before = 0
        r.flusher.beforeWrite = { before += 1 }
        r.store.record(command: .focusLeft, source: .hotkey)
        r.store.record(.swipe)
        r.flusher.flush(sync: true, force: true)
        #expect(r.timers.delays.isEmpty)
        #expect(before == 0)
        #expect(Self.dayFiles(dir).isEmpty)
        #expect(r.store.snapshot().commands.isEmpty)
    }

    @Test func aForcedFlushRecordsTheRunningCostAlsoWhenClean() {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Self.rig(dir)
        var before = 0
        r.flusher.beforeWrite = { before += 1; r.store.recordActive(seconds: 5) }
        r.flusher.flush(sync: true)
        #expect(before == 0, "a normal flush of a clean store does nothing")
        r.flusher.flush(sync: true, force: true)
        #expect(before == 1)
        #expect(Self.dayFiles(dir).count == 1)
        #expect(!r.store.hasUnsavedChanges)
        #expect(r.timers.delays.isEmpty, "the cost that beforeWrite records goes into this write, not a new timer")
    }
}

/// D10: CPU time and wakeups only while the engine runs.
@Suite struct CostMeterTests {
    static func sample(_ cpu: Double, _ wakeups: UInt64, _ peak: Double = 50) -> CostSample {
        CostSample(cpuSeconds: cpu, wakeups: wakeups, peakMB: peak)
    }

    @Test func countsOnlyTheRunningParts() throws {
        var meter = CostMeter()
        meter.started(Self.sample(1, 10))
        meter.stopped(Self.sample(3, 30))
        // Stopped from cpu 3 to cpu 10: not counted.
        let first = meter.take(Self.sample(10, 100, 60))
        meter.started(Self.sample(10, 100))
        let second = meter.take(Self.sample(11, 105))
        let third = meter.take(Self.sample(11.5, 106))
        let none = meter.take(nil)
        let a = try #require(first)
        let b = try #require(second)
        let c = try #require(third)
        #expect(a.cpuSeconds == 2)
        #expect(a.wakeups == 20)
        #expect(a.peakMB == 60)
        #expect(b.cpuSeconds == 1)
        #expect(b.wakeups == 5)
        #expect(c.cpuSeconds == 0.5)
        #expect(c.wakeups == 1)
        #expect(none == nil)
    }

    @Test func aSecondStartKeepsTheRunningPart() throws {
        var meter = CostMeter()
        meter.started(Self.sample(1, 10))
        meter.started(Self.sample(4, 40))
        let taken = meter.take(Self.sample(5, 50))
        let a = try #require(taken)
        #expect(a.cpuSeconds == 4)
        #expect(a.wakeups == 40)
    }

    @Test func neverStartedCountsNothing() throws {
        var meter = CostMeter()
        let taken = meter.take(Self.sample(10, 100))
        let a = try #require(taken)
        #expect(a.cpuSeconds == 0)
        #expect(a.wakeups == 0)
    }
}

/// D5, D6, D7 and the record points of `perform`.
@Suite struct MetricsDecisionTests {
    @Test func columnsOnlyWhenTheCountChanges() {
        var counts = ColumnCounts<String>()
        var seen: [Bool] = []
        seen.append(counts.changed("a", to: 3))
        seen.append(counts.changed("a", to: 3))
        seen.append(counts.changed("b", to: 3))
        seen.append(counts.changed("a", to: 4))
        counts.forget("a")
        seen.append(counts.changed("a", to: 4))
        counts.reset()
        seen.append(counts.changed("b", to: 3))
        #expect(seen == [true, false, true, true, true, true])
    }

    @Test func tickMoves() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 1, y: 0, width: 100, height: 100)
        let placed: [WindowID: CGRect] = [1: a, 2: b]
        let at = { (id: WindowID) in placed[id] }
        #expect(!Engine.tickMoves([FrameWrite(id: 1, pid: 9, frame: a), FrameWrite(id: 2, pid: 9, frame: b)], placedBefore: at))
        #expect(Engine.tickMoves([FrameWrite(id: 1, pid: 9, frame: a), FrameWrite(id: 2, pid: 9, frame: a)], placedBefore: at))
        #expect(Engine.tickMoves([FrameWrite(id: 3, pid: 9, frame: a)], placedBefore: at), "a window not placed yet moves")
        #expect(!Engine.tickMoves([], placedBefore: at))
    }

    @Test func targetsChange() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 100, y: 0, width: 100, height: 100)
        #expect(Engine.targetsChange(nil, to: [1: a]))
        var anim = FrameAnimator(response: 0.3, enabled: true)
        anim.setTargets([1: a, 2: b], at: 0, animate: true)
        #expect(!Engine.targetsChange(anim, to: [1: a, 2: b]), "the same targets move nothing")
        #expect(Engine.targetsChange(anim, to: [1: b, 2: a]))
        #expect(Engine.targetsChange(anim, to: [1: a]))
        #expect(Engine.targetsChange(anim, to: [1: a, 3: b]))
    }

    @Test func dragFriction() {
        #expect(Engine.dragFriction(resize: true, dragToReorder: true, drop: nil) == .userResize)
        #expect(Engine.dragFriction(resize: true, dragToReorder: false, drop: nil) == .userResize)
        #expect(Engine.dragFriction(resize: false, dragToReorder: false, drop: nil) == .userDrag)
        #expect(Engine.dragFriction(resize: false, dragToReorder: true, drop: .putBack) == .userDrag)
        #expect(Engine.dragFriction(resize: false, dragToReorder: true, drop: .reorder) == nil)
        #expect(Engine.dragFriction(resize: false, dragToReorder: true, drop: .otherDisplay) == nil)
    }

    @Test func displayPeriod() {
        // ProMotion at 120 Hz: the time to the next frame, not the nominal 60 Hz duration.
        #expect(abs(Ticker.periodMs(timestamp: 1, targetTimestamp: 1 + 1.0 / 120, duration: 1.0 / 60) - 1000.0 / 120) < 1e-9)
        #expect(abs(Ticker.periodMs(timestamp: 1, targetTimestamp: 1, duration: 1.0 / 60) - 1000.0 / 60) < 1e-9)
        #expect(abs(Ticker.periodMs(timestamp: 1, targetTimestamp: .nan, duration: 0) - 1000.0 / 60) < 1e-9)
        #expect(Ticker.periodMs(timeValue: 1, timeScale: 120, indefinite: false) == 1000.0 / 120)
        #expect(Ticker.periodMs(timeValue: 1, timeScale: 120, indefinite: true) == 1000.0 / 60)
        #expect(Ticker.periodMs(timeValue: 0, timeScale: 0, indefinite: false) == 1000.0 / 60)
    }

    @Test func commandsRecordedWhenStopped() {
        let always: Set<Command> = [.start, .stop, .toggleEngine, .restart, .mark]
        for command in Command.bindable + [.focusWindow(7)] {
            #expect(Engine.recordsWhenStopped(command) == always.contains(command), "\(command.name)")
        }
    }
}
