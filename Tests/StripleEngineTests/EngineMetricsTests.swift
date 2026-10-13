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
        failed.result = .failed(call: .size, code: -25200)
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
        Engine.recordTick(recorder, metrics: store, commandStart: nil)(.init(wallMs: 2.5, axMs: 2))
        Engine.recordTick(recorder, metrics: store, commandStart: 0)(.init(wallMs: 3, axMs: 2.75))
        Engine.recordTick(recorder, metrics: store, commandStart: 0)(nil)
        let day = store.snapshot()
        #expect(day.frameWrite.count == 2)
        #expect(day.frameWrite.sum == 5.5)
        #expect(day.frameOwn.count == 2)
        #expect(day.frameOwn.sum == 0.75)
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
        let timing = FrameApplier.FrameTiming(wallMs: 3, axMs: 2)
        Engine.recordTick(recorder, metrics: store, commandStart: 10, settleAtWrite: true, now: { 10.0625 })(timing)
        Engine.recordTick(recorder, metrics: store, commandStart: 10, settleAtWrite: true, now: { 10.0625 })(nil)
        Engine.recordTick(recorder, metrics: store, commandStart: 10, settleAtWrite: false, now: { 10.0625 })(timing)
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
        // A kick tick inside perform that moves nothing: every frame is where Striple placed the window. From rest
        // the kick tick moves (`Engine.animationStart`); the clock must still work when it does not.
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

    /// G1: `moved` compares with the placements from before this tick, then the tick stores the new ones.
    @Test func tickStep() {
        let a = Layout.Placement(frame: CGRect(x: 0, y: 0, width: 100, height: 100), hidden: false)
        let b = Layout.Placement(frame: CGRect(x: 1, y: 0, width: 100, height: 100), hidden: false)
        var placements: [WindowID: Layout.Placement] = [1: a, 2: b]
        let same = Engine.tickStep([(1, a), (2, b)], placements: &placements, settled: false, swiping: false)
        #expect(!same.moved)
        #expect(!same.ends)
        #expect(placements == [1: a, 2: b])
        let changed = Engine.tickStep([(1, a), (2, a)], placements: &placements, settled: true, swiping: false)
        #expect(changed.moved)
        #expect(changed.ends)
        #expect(placements == [1: a, 2: a])
        let new = Engine.tickStep([(3, b)], placements: &placements, settled: true, swiping: true)
        #expect(new.moved, "a window not placed yet moves")
        #expect(!new.ends, "a swipe keeps the animation")
        #expect(placements == [1: a, 2: a, 3: b])
        let none = Engine.tickStep([], placements: &placements, settled: true, swiping: false)
        #expect(!none.moved)
        #expect(none.ends)
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

/// F2: the first frame of a command is written in the key handler, and it already moves the windows.
@Suite struct AnimationStartTests {
    private static let rest: (Double) -> Bool = { _ in true }

    @Test func fromRestTheSpringsStartOneFrameEarlier() {
        #expect(Engine.animationStart(now: 10, velocityX: nil, settled: Self.rest) == 10 - Engine.defaultFramePeriod)
        #expect(Engine.defaultFramePeriod == 1.0 / 60)
        #expect(Engine.animationStart(now: 10, velocityX: nil, lead: 1.0 / 120, settled: Self.rest) == 10 - 1.0 / 120)
    }

    /// During an animation the springs continue from where they are: a start in the past would make them jump.
    @Test func duringAnAnimationTheSpringsStartNow() {
        #expect(Engine.animationStart(now: 10, velocityX: nil, settled: { _ in false }) == 10)
    }

    /// A swipe's release speed applies from the release.
    @Test func afterASwipeTheSpringsStartNow() {
        #expect(Engine.animationStart(now: 10, velocityX: 1200, settled: Self.rest) == 10)
        #expect(Engine.animationStart(now: 10, velocityX: 0, settled: Self.rest) == 10)
    }

    /// Rest is checked at the early start time: settled at `now` but not one lead before it starts at `now`.
    @Test func restIsCheckedAtTheEarlyStart() {
        var asked: [Double] = []
        let start = Engine.animationStart(now: 10, velocityX: nil, settled: { t in asked.append(t); return t >= 10 })
        #expect(start == 10)
        #expect(asked == [10 - Engine.defaultFramePeriod])
    }

    /// Round 3 critic: a shrink 800 -> 400 settles, and a few ms later a command sets 600. The springs were settled at
    /// `now` but not at `now - lead`, so the retarget read the old held width (800) and the window went
    /// 400 -> 800 -> 600 on screen. The frame after the retarget must keep 400 (the size on screen) or show 600.
    @Test func aRetargetJustAfterASettleKeepsTheSizeOnScreen() {
        let wide = CGRect(x: 0, y: 0, width: 800, height: 600)
        let narrow = CGRect(x: 0, y: 0, width: 400, height: 600)
        let middle = CGRect(x: 0, y: 0, width: 600, height: 600)
        var anim = FrameAnimator()
        anim.setTargets([1: wide], at: 0, animate: false)
        anim.setTargets([1: narrow], at: 1, animate: true)
        var settledAt = 1.0
        while !anim.isSettled(at: settledAt) { settledAt += 0.0005 }
        #expect(anim.writeFrame(1, at: settledAt)!.width == 400, "the settle frame wrote the target")
        #expect(!anim.isSettled(at: settledAt + 0.005 - Engine.defaultFramePeriod), "the gap the bug needs")

        for gap in [0.001, 0.005, 0.010, 0.016, 0.017, 0.030] {
            var a = anim
            let now = settledAt + gap
            a.setTargets([1: middle], at: Engine.animationStart(now: now, velocityX: nil, settled: { a.isSettled(at: $0) }),
                         animate: true)
            var t = now
            while !a.isSettled(at: t) {
                let w = a.writeFrame(1, at: t)!.width
                #expect(w == 400 || w == 600, "gap \(gap) s, t \(t): width \(w)")
                t += 1.0 / 120
            }
        }
    }

    /// The kick tick at `now` writes a frame that moved: without the lead it would be the start frame (dt = 0),
    /// and the first moved frame would wait for the next display refresh.
    @Test func theKickFrameHasMoved() {
        let from = CGRect(x: 0, y: 0, width: 100, height: 100)
        let to = CGRect(x: 600, y: 0, width: 100, height: 100)
        var anim = FrameAnimator()
        anim.setTargets([1: from], at: 0, animate: true)
        let now = 5.0
        anim.setTargets([1: to], at: Engine.animationStart(now: now, velocityX: nil, settled: { anim.isSettled(at: $0) }),
                        animate: true)
        let first = anim.writeFrame(1, at: now)!
        #expect(first.minX > 0.5, "the first frame moved")
        #expect(first.minX < 100, "and it is a small step, not a jump")
        #expect(!anim.isSettled(at: now))

        var noLead = FrameAnimator()
        noLead.setTargets([1: from], at: 0, animate: true)
        noLead.setTargets([1: to], at: now, animate: true)
        #expect(noLead.writeFrame(1, at: now)!.minX == 0)
    }

    @Test func theLeadIsOneDisplayPeriod() {
        #expect(Engine.firstFrameLead(period: 1.0 / 60) == 1.0 / 60)
        #expect(Engine.firstFrameLead(period: 1.0 / 120) == 1.0 / 120)
        #expect(Engine.firstFrameLead(period: 1.0 / 144) == 1.0 / 144)
        #expect(Engine.firstFrameLead(period: 1.0 / 1000) == 1.0 / 240, "clamped: no display refreshes faster")
        #expect(Engine.firstFrameLead(period: 1) == 1.0 / 30, "clamped: a slow link must not start an animation 1 s back")
        for bad in [0, -1, Double.nan, .infinity] {
            #expect(Engine.firstFrameLead(period: bad) == 1.0 / 60, "\(bad)")
        }
    }

    /// While the link runs, `kick` writes nothing and the next refresh writes the strip's first frame, so a lead
    /// would add one period to that step. From rest with the link stopped, the lead is one display period.
    @Test func noLeadWhileTheLinkRuns() {
        #expect(Engine.animationLead(period: 1.0 / 120, linkRunning: false) == 1.0 / 120)
        #expect(Engine.animationLead(period: 1.0 / 120, linkRunning: true) == 0)
        #expect(Engine.animationStart(now: 10, velocityX: nil, lead: Engine.animationLead(period: 1.0 / 60, linkRunning: true),
                                      settled: { _ in true }) == 10)
    }

    /// The frames a command from rest writes on a display with refresh period `period`: the kick tick at `now`,
    /// then the display link one period apart, until the springs settle.
    static func xFrames(period: Double, lead: Double) -> [Double] {
        let from = CGRect(x: 0, y: 0, width: 800, height: 600)
        let to = CGRect(x: 816, y: 0, width: 800, height: 600)
        var anim = FrameAnimator()
        anim.setTargets([1: from], at: 0, animate: true)
        let now = 5.0
        anim.setTargets([1: to], at: Engine.animationStart(now: now, velocityX: nil, lead: lead,
                                                           settled: { anim.isSettled(at: $0) }), animate: true)
        var xs: [Double] = [0]
        var t = now
        while xs.count < 400 {
            xs.append(Double(anim.writeFrame(1, at: t)!.minX))
            if anim.isSettled(at: t) { break }
            t += period
        }
        return xs
    }

    /// Follow-up of the sub-ms frames work: the lead was 1/60 s on every display. On a fast display the kick frame
    /// then holds several refreshes of motion, and the window jumps, then slows down. With a lead of one period the
    /// kick frame moves, frames never go back, and the steps from rest grow: the kick step is the smallest step of
    /// the speed-up, as on a display link that started one period earlier.
    @Test(arguments: [48.0, 60, 120, 144, 240])
    func theKickFrameFitsTheDisplayRate(hz: Double) {
        let period = 1 / hz
        let xs = Self.xFrames(period: period, lead: Engine.firstFrameLead(period: period))
        #expect(xs.last == 816, "\(hz) Hz: it settles at the target")
        let steps = zip(xs.dropFirst(), xs).map { $0 - $1 }
        #expect(steps[0] > 0.5, "\(hz) Hz: the kick frame moved")
        #expect(steps.allSatisfy { $0 >= 0 }, "\(hz) Hz: no frame goes back")
        #expect(steps[0] <= steps[1], "\(hz) Hz: kick step \(steps[0]) is larger than the next \(steps[1])")
    }

    /// The test above fails with the old fixed lead on a 240 Hz display: it does catch the bug.
    @Test func aFixedSixtyHertzLeadJumpsOnAFastDisplay() {
        let xs = Self.xFrames(period: 1.0 / 240, lead: 1.0 / 60)
        #expect(xs[1] - xs[0] > xs[2] - xs[1], "the kick step is larger than the step after it")
    }
}

/// Follow-up of the sub-ms frames work: after a drag, `mouseUp` wrote a frame at the window's old slot, then moved the
/// spring to where the user let go. The window flashed back to its old slot for one frame.
@Suite struct DropFlashTests {
    let oldSlot = CGRect(x: 824, y: 47, width: 800, height: 1274)
    let newSlot = CGRect(x: 8, y: 47, width: 800, height: 1274)
    let dropped = CGRect(x: 300, y: 120, width: 800, height: 1274)

    /// The animator as it was during the drag: settled at the old slot (the tick skips the dragged window).
    func atRest() -> FrameAnimator {
        var anim = FrameAnimator()
        anim.setTargets([1: oldSlot, 2: newSlot], at: 0, animate: false)
        return anim
    }

    @Test func theFirstFrameAfterADropStartsWhereTheUserLetGo() {
        var anim = atRest()
        let now = 10.0
        let start = Engine.animationStart(now: now, velocityX: nil, settled: { anim.isSettled(at: $0) })
        Engine.retarget(&anim, to: [1: newSlot, 2: oldSlot], at: start, animate: true, velocityX: nil, from: [1: dropped])
        var t = now
        var previous = dropped
        repeat {
            let f = anim.writeFrame(1, at: t)!
            #expect(abs(f.minX - oldSlot.minX) > 100, "t \(t): the window is back in its old slot (x \(f.minX))")
            #expect(f.minX <= previous.minX && f.minX >= newSlot.minX, "t \(t): x \(f.minX) is not on the way from the drop")
            previous = f
            t += 1.0 / 60
        } while !anim.isSettled(at: t)
        let first = anim.writeFrame(1, at: now)!
        #expect(abs(first.minX - dropped.minX) < 30 && abs(first.minY - dropped.minY) < 10, "first frame \(first)")
        #expect(anim.writeFrame(1, at: t) == newSlot)
    }

    /// The old order: the first frame was written before `setCurrent`, at the old slot.
    @Test func theOldOrderWroteTheOldSlotFirst() {
        var anim = atRest()
        let now = 10.0
        anim.setTargets([1: newSlot, 2: oldSlot], at: now - Engine.defaultFramePeriod, animate: true)
        let first = anim.writeFrame(1, at: now)!
        #expect(abs(first.minX - oldSlot.minX) < 100, "one frame of motion from the old slot, x \(first.minX)")
        #expect(abs(first.minX - dropped.minX) > 400, "far from where the user let go")
    }

    /// While the strip still moves, the springs start at `now`: the first frame is the drop frame itself.
    @Test func duringAnAnimationTheFirstFrameIsTheDropFrame() {
        var anim = atRest()
        anim.setTargets([1: oldSlot, 2: CGRect(x: 1640, y: 47, width: 800, height: 1274)], at: 9.95, animate: true)
        let now = 10.0
        let start = Engine.animationStart(now: now, velocityX: nil, settled: { anim.isSettled(at: $0) })
        #expect(start == now)
        Engine.retarget(&anim, to: [1: newSlot, 2: oldSlot], at: start, animate: true, velocityX: nil, from: [1: dropped])
        #expect(anim.writeFrame(1, at: now) == dropped)
    }

    /// Animations off: the window goes straight to its new slot. Before, the drop started an animation even then.
    @Test func withAnimationsOffTheWindowGoesStraightToItsSlot() {
        var anim = FrameAnimator(enabled: false)
        anim.setTargets([1: oldSlot, 2: newSlot], at: 0, animate: false)
        Engine.retarget(&anim, to: [1: newSlot, 2: oldSlot], at: 10, animate: true, velocityX: nil, from: [1: dropped])
        #expect(anim.writeFrame(1, at: 10) == newSlot)
        #expect(anim.isSettled(at: 10))
    }

    /// A window moved to another display is new in that strip's animator: it starts where the user let go, not at
    /// its target. A `from` window that is not in the targets is ignored.
    @Test func aWindowNewInTheStripStartsWhereTheUserLetGo() {
        var anim = FrameAnimator()
        let start = Engine.animationStart(now: 10, velocityX: nil, settled: { anim.isSettled(at: $0) })
        Engine.retarget(&anim, to: [1: newSlot], at: start, animate: true, velocityX: nil, from: [1: dropped, 9: oldSlot])
        let first = anim.writeFrame(1, at: 10)!
        #expect(abs(first.minX - dropped.minX) < 30, "first frame \(first)")
        #expect(anim.writeFrame(9, at: 10) == nil)
    }
}


@Suite struct SizedAwayTests {
    private let final = CGRect(x: 8, y: 0, width: 2040, height: 1000)

    @Test func aNewSizeAwayFromTheFinalPositionIsMarked() {
        let old = CGRect(x: 1200, y: 0, width: 800, height: 1000)
        #expect(Engine.sizedAway(previous: old, write: CGRect(x: 1190, y: 0, width: 2040, height: 1000), final: final))
        #expect(Engine.sizedAway(previous: nil, write: CGRect(x: 1190, y: 0, width: 2040, height: 1000), final: final))
    }

    @Test func aMoveOrASizeAtTheFinalPositionIsNotMarked() {
        let held = CGRect(x: 1190, y: 0, width: 2040, height: 1000)
        #expect(!Engine.sizedAway(previous: held, write: CGRect(x: 600, y: 0, width: 2040, height: 1000), final: final),
                "a move only: the size is not written")
        #expect(!Engine.sizedAway(previous: CGRect(x: 20, y: 0, width: 2100, height: 1000), write: final, final: final),
                "the write applies the size at the final position")
        #expect(!Engine.sizedAway(previous: nil, write: final, final: final))
    }

    /// The bug of the first E2E run with held sizes: a growing window got its new size on the first frame, at its
    /// old position, where the system cut it at the display edge. The later frames only moved it, so it kept the cut
    /// size (E2E scenario d: width 711, want 1016).
    @Test func aGrowingWindowGetsItsFullSizeAtTheEnd() {
        let fixed = simulateGrow(resizeAtEnd: true)
        let unfixed = simulateGrow(resizeAtEnd: false)
        #expect(fixed == final)
        #expect(unfixed.width < final.width, "the model must show the bug without the last resize")
    }

    /// Runs the steps of `Engine.tick` for one window at 60 Hz, against a window that cannot reach past x = 2056.
    /// The marks and the AX calls are the production helpers: `sizedAway`, `resizeMarked`, `AXFrameWriter.steps`.
    private func simulateGrow(resizeAtEnd: Bool) -> CGRect {
        let start = CGRect(x: 1200, y: 0, width: 800, height: 1000)
        var anim = FrameAnimator(response: 0.22)
        anim.setTargets([1: start], at: 0, animate: false)
        anim.setTargets([1: final], at: 0, animate: true)
        var window = ClampingWindow(edge: 2056, frame: start)
        var placed: CGRect? = start
        var written: CGRect? = start
        var marks: Set<WindowID> = []
        var t = 0.0
        while t < 5 {
            t += 1.0 / 60
            guard let f = anim.writeFrames(at: t)[1] else { break }
            if Engine.sizedAway(previous: placed, write: f, final: final) { marks.insert(1) }
            placed = f
            let ends = anim.isSettled(at: t)
            var writes = [FrameWrite(id: 1, pid: 1, frame: f)]
            if ends && resizeAtEnd { Engine.resizeMarked(&writes, marks: &marks, exists: { _ in true }) }
            if writes[0].frame != written || writes[0].resize {
                window.write(writes[0], previous: written)
                written = writes[0].frame
            }
            if ends { break }
        }
        return window.frame
    }
}

@Suite struct ResizeMarkedTests {
    @Test func markedWindowsWithAWriteGetResizeAndLoseTheirMark() {
        var writes = [FrameWrite(id: 1, pid: 1, frame: .zero), FrameWrite(id: 2, pid: 1, frame: .zero)]
        var marks: Set<WindowID> = [1]
        Engine.resizeMarked(&writes, marks: &marks, exists: { _ in true })
        #expect(writes.map(\.resize) == [true, false])
        #expect(marks.isEmpty)
    }

    /// A dragged window, or one on a strip that went off screen, has no write on the last tick: it must keep its
    /// mark, else it keeps a size that the system cut (critic round 1).
    @Test func aMarkedWindowWithoutAWriteKeepsItsMarkWhileItExists() {
        var writes = [FrameWrite(id: 1, pid: 1, frame: .zero)]
        var marks: Set<WindowID> = [1, 2, 3]
        Engine.resizeMarked(&writes, marks: &marks, exists: { $0 != 3 })
        #expect(writes.map(\.resize) == [true])
        #expect(marks == [2], "2 waits for a later write, 3 is gone")
    }
}

/// A window whose app cuts its width at a display edge. It gets the AX calls of `AXFrameWriter.steps`.
private struct ClampingWindow {
    let edge: CGFloat
    var frame: CGRect

    mutating func setSize(_ s: CGSize) { frame.size = CGSize(width: min(s.width, edge - frame.minX), height: s.height) }

    mutating func write(_ w: FrameWrite, previous: CGRect?) {
        let steps = AXFrameWriter.steps(w, previous: previous)
        if steps.size { setSize(w.frame.size) }
        if steps.position { frame.origin = w.frame.origin }
        if steps.sizeAgain { setSize(w.frame.size) }
    }
}

@Suite struct AXStepsTests {
    private let a = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test func onlyWhatChangedIsWritten() {
        #expect(AXFrameWriter.steps(FrameWrite(id: 1, pid: 1, frame: a.offsetBy(dx: 5, dy: 0)), previous: a)
                == .init(size: false, position: true))
        #expect(AXFrameWriter.steps(FrameWrite(id: 1, pid: 1, frame: CGRect(x: 0, y: 0, width: 90, height: 100)), previous: a)
                == .init(size: true, position: false))
        #expect(AXFrameWriter.steps(FrameWrite(id: 1, pid: 1, frame: a), previous: nil) == .init(size: true, position: true))
    }

    @Test func resizeWritesTheSizeAlsoWhenItDidNotChange() {
        let moved = FrameWrite(id: 1, pid: 1, frame: a.offsetBy(dx: 5, dy: 0), resize: true)
        #expect(AXFrameWriter.steps(moved, previous: a) == .init(size: true, position: true))
        #expect(AXFrameWriter.steps(moved, previous: a).sizeAgain)
        #expect(AXFrameWriter.steps(FrameWrite(id: 1, pid: 1, frame: a, resize: true), previous: a)
                == .init(size: true, position: false))
    }
}
