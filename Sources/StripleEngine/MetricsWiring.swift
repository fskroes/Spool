import Foundation
import StripleCore

// The decisions of the engine's metrics wiring (F24), as pure values without AppKit, AX or timers, so tests
// can drive them. Engine+Metrics.swift connects them to the engine.

/// The start of the command that waits for its first frame, and of the command whose animation runs.
/// Feeds command latency and settle (`striple stats` and the metrics). Only a command that moves a window gives
/// a sample: a command that changes nothing, a command during a swipe, and a swipe give none.
struct CommandClock: Equatable {
    /// Waits for the first tick that moves a window.
    private(set) var pending: Double?
    /// Set when that tick queues its write; read when the animation settles.
    private(set) var settling: Double?
    /// The start that waited before this command, back in `pending` when this command changes nothing.
    private(set) var beforeCommand: Double?

    /// What a tick gives its write: the command start for the latency, and whether the settle is recorded when
    /// the write lands (the animation ends on this same tick, for example with animations off).
    struct TickStart: Equatable {
        let start: Double
        let settleAtWrite: Bool
    }

    /// A command starts. During a swipe the swipe's frames are not the command's: no sample.
    mutating func commandStarted(at t: Double, swiping: Bool) {
        beforeCommand = pending
        guard !swiping else { return }
        pending = t
    }

    /// The end of `perform`. A command that changed no target frame (focus-left at the first column, a move at an
    /// edge, toggle-float without a window) has no latency, also while an animation runs: the start must not go to
    /// a later or older animation. The start of a command before it that still waits stays, and so does the
    /// settle of the command before it.
    mutating func performEnded(changedTargets: Bool) {
        if !changedTargets { pending = beforeCommand }
        beforeCommand = nil
    }

    /// Before a tick's write. `moved` is true when a frame of this tick differs from where Striple placed the window
    /// before (`Engine.tickStep`). A tick that moves nothing does not take the start: the first tick of a command
    /// at rest has dt = 0, and a frame equal to one still in flight is the old frame, not the command's.
    /// `settles` is true when the animation ends on this tick.
    func tickStart(moved: Bool, settles: Bool) -> TickStart? {
        guard moved, let start = pending else { return nil }
        return TickStart(start: start, settleAtWrite: settles)
    }

    /// After the tick's write: `queued` is the result of `FrameApplier.apply`. When the settle comes with the
    /// write, `settled(at:)` gives none for this command.
    mutating func ticked(_ taken: TickStart?, queued: Bool) {
        guard let taken, queued else { return }
        pending = nil
        settling = taken.settleAtWrite ? nil : taken.start
    }

    /// The animation settled at `t`: the settle time in ms of the command whose frames were queued, once.
    /// A command start that no tick took is dropped: it moved no window.
    mutating func settled(at t: Double) -> Double? {
        pending = nil
        guard let start = settling else { return nil }
        settling = nil
        return max(t - start, 0) * 1000
    }

    /// A swipe takes over the strip: the command's animation does not end on its own, so it has no settle time.
    mutating func swipeBegan() {
        pending = nil
        settling = nil
    }

    mutating func reset() { self = CommandClock() }
}

/// When to write the day file: one flush `delay` after the first unsaved change, no timer while the store is
/// clean, and a growing wait after a failed write (2 min, 4 min, ... 1 h; back to 60 s after a success).
struct MetricsFlushPlan: Equatable {
    static let delay: TimeInterval = 60
    static let maxDelay: TimeInterval = 3600

    private(set) var scheduled = false
    /// Writes started and not ended yet.
    private(set) var writes = 0
    /// Unsaved changes came while a write ran: decide after the write.
    private(set) var wanted = false
    private(set) var failures = 0
    private(set) var lastError: String?

    /// The wait before the next flush after `failures` failed writes in a row.
    static func delay(failures: Int) -> TimeInterval {
        guard failures > 0 else { return delay }
        return min(delay * pow(2, Double(min(failures, 16))), maxDelay)
    }

    /// The store went from saved to unsaved: the delay of the flush to schedule, or nil. `dirty` is the store's
    /// `hasUnsavedChanges` now: the callback comes late, maybe after a forced write saved the change.
    mutating func changed(dirty: Bool) -> TimeInterval? {
        guard dirty else { return nil }
        if writes > 0 {
            wanted = true
            return nil
        }
        guard !scheduled else { return nil }
        scheduled = true
        return Self.delay(failures: failures)
    }

    /// The scheduled flush runs now.
    mutating func fired() { scheduled = false }

    mutating func writeStarted() { writes += 1 }

    /// A write ended. `log` is true for the first failure with this error since the last success.
    /// `schedule` is the delay of the next flush when changes came during the write (also the data a failed write
    /// kept in memory) and none is scheduled.
    mutating func writeEnded(error: String?, dirty: Bool) -> (log: Bool, schedule: TimeInterval?) {
        writes = max(writes - 1, 0)
        var log = false
        if let error {
            failures += 1
            log = error != lastError
            lastError = error
        } else {
            failures = 0
            lastError = nil
        }
        guard wanted, writes == 0 else { return (log, nil) }
        wanted = false
        return (log, changed(dirty: dirty))
    }
}

/// The process cost while the engine runs. CPU time and wakeups between an engine stop and the next start are
/// not counted, so `cpu-while-active` divides the CPU time of the running engine by its running time.
struct CostMeter: Equatable {
    /// The sample at the start of the running part not counted yet. Nil while the engine is stopped.
    private(set) var since: CostSample?
    private(set) var cpuSeconds = 0.0
    private(set) var wakeups = 0

    /// A second start without a stop counts the running part before it.
    mutating func started(_ sample: CostSample?) {
        add(sample)
        since = sample
    }

    mutating func stopped(_ sample: CostSample?) {
        add(sample)
        since = nil
    }

    /// At a flush: the cost since the last flush (only the running parts) and the memory peak now.
    mutating func take(_ sample: CostSample?) -> (cpuSeconds: Double, wakeups: Int, peakMB: Double)? {
        guard let sample else { return nil }
        if since != nil {
            add(sample)
            since = sample
        }
        defer { cpuSeconds = 0; wakeups = 0 }
        return (cpuSeconds, wakeups, sample.peakMB.isFinite ? max(sample.peakMB, 0) : 0)
    }

    private mutating func add(_ sample: CostSample?) {
        guard let sample, let since else { return }
        let d = sample.delta(since: since)
        cpuSeconds += d.cpuSeconds
        wakeups = wakeups.addingReportingOverflow(d.wakeups).overflow ? .max : wakeups + d.wakeups
    }
}

/// The column count of each strip at its last record: `columnsPerStrip` gets a sample only when it changes
/// (or the strip is new), not on every layout pass.
struct ColumnCounts<Key: Hashable> {
    private var counts: [Key: Int] = [:]

    /// True when `count` is new for `key`; remembers it.
    mutating func changed(_ key: Key, to count: Int) -> Bool {
        counts.updateValue(count, forKey: key) != count
    }

    mutating func forget(_ key: Key) { counts[key] = nil }
    mutating func reset() { counts.removeAll() }
}

extension Engine {
    /// The decision of one tick. `moved` is true when a frame of `placed` differs from where Striple placed that
    /// window before (a window not placed yet moves). It reads `placements` before it stores the new ones there.
    /// `ends` is true when every animation settled and no swipe runs.
    nonisolated static func tickStep(_ placed: [(WindowID, Layout.Placement)],
                                     placements: inout [WindowID: Layout.Placement],
                                     settled: Bool, swiping: Bool) -> (moved: Bool, ends: Bool) {
        let moved = placed.contains { placements[$0.0]?.frame != $0.1.frame }
        for (id, p) in placed { placements[id] = p }
        return (moved, settled && !swiping)
    }

    /// True when a tick writes a new size while the window is not at its final position yet. The size is held
    /// during the animation (`FrameAnimator.writeFrame`), so the frames after it only move the window. But the app
    /// or macOS can refuse a part of a size at a position (a window may not reach past the display edge there):
    /// the window would keep the smaller size. So the last frame of the animation writes that size again.
    nonisolated static func sizedAway(previous: CGRect?, write: CGRect, final: CGRect) -> Bool {
        previous?.size != write.size && write.origin != final.origin
    }

    /// The last tick of an animation: the writes of marked windows (`sizedAway`) get `resize`, and lose their mark.
    /// A window without a write now (dragged, or on a strip that is not on screen) keeps its mark for the end of a
    /// later animation, unless it is gone.
    nonisolated static func resizeMarked(_ writes: inout [FrameWrite], marks: inout Set<WindowID>,
                                         exists: (WindowID) -> Bool) {
        guard !marks.isEmpty else { return }
        for i in writes.indices where marks.remove(writes[i].id) != nil { writes[i].resize = true }
        marks = marks.filter(exists)
    }

    /// True when `frames` are not the targets the strip's animator has now: the layout pass moves a window.
    nonisolated static func targetsChange(_ anim: FrameAnimator?, to frames: [WindowID: CGRect]) -> Bool {
        guard let anim, anim.windowIDs.count == frames.count else { return true }
        return frames.contains { anim.target($0.key) != $0.value }
    }

    /// Commands recorded before the running check: they work also when the engine is stopped.
    nonisolated static func recordsWhenStopped(_ command: Command) -> Bool {
        switch command {
        case .start, .stop, .toggleEngine, .restart, .mark: return true
        default: return false
        }
    }

    /// The friction of a mouse drag of a tiled window that ended. A resize always is. A drag is friction only
    /// when Striple put the window back: with drag-to-reorder off, or a drop outside a managed display.
    /// A reorder or a move to another display is what the user wanted.
    nonisolated static func dragFriction(resize: Bool, dragToReorder: Bool, drop: Policy.DropKind?) -> FrictionKind? {
        if resize { return .userResize }
        if !dragToReorder { return .userDrag }
        return drop == .putBack ? .userDrag : nil
    }
}

extension Ticker {
    /// The display period in ms of a CADisplayLink step: the time to the next frame when the link gives it
    /// (it follows ProMotion and adaptive refresh), else the nominal duration, else 60 Hz.
    nonisolated static func periodMs(timestamp: Double, targetTimestamp: Double, duration: Double) -> Double {
        let next = targetTimestamp - timestamp
        if next.isFinite, next > 0 { return next * 1000 }
        if duration.isFinite, duration > 0 { return duration * 1000 }
        return 1000 / 60
    }

    /// The nominal period in ms of a CVDisplayLink (`CVDisplayLinkGetNominalOutputVideoRefreshPeriod`), else 60 Hz.
    nonisolated static func periodMs(timeValue: Int64, timeScale: Int32, indefinite: Bool) -> Double {
        guard !indefinite, timeValue > 0, timeScale > 0 else { return 1000 / 60 }
        return Double(timeValue) / Double(timeScale) * 1000
    }
}

/// Writes the day file by `MetricsFlushPlan`. The timer and the queues are injected, so tests run without them.
@MainActor
final class MetricsFlusher {
    typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    typealias MainHop = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    let store: MetricsStore
    private let schedule: Scheduler
    /// Runs a file write: a utility queue in the app.
    private let background: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let toMain: MainHop
    private let log: (String) -> Void
    /// Records what must go into each write (running time, cost). Runs on main before the write.
    var beforeWrite: () -> Void = {}
    private(set) var plan = MetricsFlushPlan()

    init(store: MetricsStore,
         schedule: @escaping Scheduler = { delay, body in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { body() } }
         },
         background: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
             DispatchQueue.global(qos: .utility).async(execute: $0)
         },
         toMain: @escaping MainHop = { body in DispatchQueue.main.async { MainActor.assumeIsolated { body() } } },
         log: @escaping (String) -> Void) {
        self.store = store
        self.schedule = schedule
        self.background = background
        self.toMain = toMain
        self.log = log
    }

    /// Asks the store to call back at its first unsaved change.
    func connect() {
        let toMain = self.toMain
        store.onFirstChange = { [weak self] in
            guard let self else { return }
            toMain { self.changed() }
        }
    }

    func disconnect() { store.onFirstChange = nil }

    /// The store has unsaved changes.
    func changed() {
        if let delay = plan.changed(dirty: store.hasUnsavedChanges) { scheduleFlush(after: delay) }
    }

    private func scheduleFlush(after delay: TimeInterval) {
        schedule(delay) { [weak self] in
            guard let self else { return }
            plan.fired()
            flush(sync: false)
        }
    }

    /// Writes the day file. Without unsaved changes it does nothing, so an idle app does not wake up to write
    /// (SPEC idle rule), unless `force` (quit, metrics off, `striple report`): then it also records the running
    /// time and cost first. `sync` writes before it returns; else the write runs off the main thread.
    func flush(sync: Bool, force: Bool = false) {
        guard store.isEnabled, force || store.hasUnsavedChanges else { return }
        // Started first: a change that `beforeWrite` makes goes into this write, not into a new timer.
        plan.writeStarted()
        beforeWrite()
        let store = self.store
        if sync {
            writeEnded(Self.write(store))
            return
        }
        let toMain = self.toMain
        background { [self] in
            let error = Self.write(store)
            toMain { self.writeEnded(error) }
        }
    }

    nonisolated static func write(_ store: MetricsStore) -> String? {
        do {
            try store.flush()
            return nil
        } catch {
            return describe(error)
        }
    }

    /// A stable text for an error: the same failure gives the same text (no object addresses), so it is logged once.
    nonisolated static func describe(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.domain) \(e.code): \(e.localizedDescription)"
    }

    private func writeEnded(_ error: String?) {
        let wasFailing = plan.failures > 0
        let result = plan.writeEnded(error: error, dirty: store.hasUnsavedChanges)
        if let error, result.log {
            log("metrics: could not save the day file, next try in \(Int(MetricsFlushPlan.delay(failures: plan.failures))) s: \(error)")
        } else if error == nil, wasFailing {
            log("metrics: saved the day file again")
        }
        if let delay = result.schedule { scheduleFlush(after: delay) }
    }
}
