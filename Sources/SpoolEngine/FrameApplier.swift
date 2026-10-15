import ApplicationServices
import CoreGraphics
import Dispatch
import Foundation
import SpoolCore

/// One window frame to write, in AX coordinates.
public struct FrameWrite: Equatable, Sendable {
    public var id: WindowID
    public var pid: pid_t
    public var frame: CGRect
    /// Write the size also when it did not change: the window may not have the size that was written last.
    public var resize: Bool

    public init(id: WindowID, pid: pid_t, frame: CGRect, resize: Bool = false) {
        self.id = id
        self.pid = pid
        self.frame = frame
        self.resize = resize
    }
}

/// The AX call of a frame write.
public enum AXCall: String, Equatable, Sendable {
    case size, position
}

/// What one frame write did.
public enum WriteResult: Equatable, Sendable {
    case written
    /// The window does not exist any more (kAXErrorInvalidUIElement, or Spool has no element for it): it closed
    /// after the frame was queued, before Spool heard of it. Not an AX error (docs/SPEC.md F2).
    case gone
    /// An AX call failed. `code` is the AXError raw value.
    case failed(call: AXCall, code: Int32)

    public var ok: Bool { self == .written }
}

/// Writes frames to real windows. The live version talks to AX; tests use a fake with a fixed delay.
/// Called on a per-app serial queue, never on the main thread.
public protocol FrameWriter: AnyObject, Sendable {
    /// Called once before a batch of writes to one app, and once after it.
    func beginBatch(pid: pid_t)
    func endBatch(pid: pid_t)
    /// Called when an animation has settled, after the app's last write.
    func settle(pid: pid_t)
    /// `previous` is the last frame Spool wrote to this window, nil if none.
    func write(_ write: FrameWrite, previous: CGRect?) -> WriteResult
}

public extension FrameWriter {
    func beginBatch(pid: pid_t) {}
    func endBatch(pid: pid_t) {}
    func settle(pid: pid_t) {}
}

/// Sends frames to windows as fast as the apps allow.
///
/// - Apps answer AX calls one at a time, but different apps answer in parallel. So each app gets its own
///   serial queue and a tick costs the slowest app, not the sum of all apps.
/// - A frame equal to the last written frame is skipped, unless the write has `resize`.
/// - When an app is still busy with the previous tick, the new frames wait and replace each other:
///   only the newest frame is written. A slow app never builds a queue of old frames.
public final class FrameApplier: @unchecked Sendable {
    public struct Counters: Equatable, Sendable {
        public var windowWrites = 0
        public var skipped = 0
        public var coalesced = 0
        public var errors = 0
        /// Writes to a window that had closed (`WriteResult.gone`). Not in `windowWrites` or `errors`.
        public var gone = 0
    }

    /// One window write, for the timing stats.
    /// The time of one `apply` call that wrote a frame.
    public struct FrameTiming: Equatable, Sendable {
        /// From the call until every frame of it was written: what `apply(_:completion:)` reports.
        public var wallMs: Double
        /// The largest time one app spent in AX calls (`beginBatch`, writes, `endBatch`) during the call.
        /// Apps write in parallel, so the wall time can not be shorter than this.
        public var axMs: Double
        /// `wallMs - axMs`: Spool's own part of the wall time (queue hops, locks, bookkeeping). It does not
        /// depend on how fast the apps answer.
        public var ownMs: Double { max(wallMs - axMs, 0) }

        public init(wallMs: Double, axMs: Double) {
            self.wallMs = wallMs
            self.axMs = axMs
        }
    }

    public struct WriteTiming: Equatable, Sendable {
        public var pid: pid_t
        /// The time of the AX calls for this window.
        public var axMs: Double
        /// From the `apply` call that queued this frame until it was written: the wait for the app plus `axMs`.
        public var latencyMs: Double
        public var id: WindowID = 0
        public var result: WriteResult = .written
        /// The AX write failed. A write to a closed window does not get a timing.
        public var failed: Bool { if case .failed = result { return true } else { return false } }
    }

    private struct Pending {
        var write: FrameWrite
        var queuedAt: UInt64
    }

    /// `run` gets true when the frames were dropped, and the app's AX clock (`AppState.axNanos`) at that time.
    private struct Waiter {
        let upTo: UInt64
        var dropped = false
        let run: @Sendable (Bool, UInt64) -> Void
    }

    /// A frame being written. `again` is set when a later `apply` wanted the same frame while it was in flight:
    /// that call was not queued, so a failed write queues `again` instead.
    /// `generation` is the app state whose drain writes it. After `forgetApp`, a new state for the same pid does
    /// not wait for that write: its drain may be idle and never wake the waiter.
    private struct InFlight {
        let frame: CGRect
        let token: UInt64
        let generation: UInt64
        var again: Pending?
    }

    private struct AppState {
        let queue: DispatchQueue
        /// Unique per state. A drain of a removed app can still run when a new app gets the same pid; it compares
        /// the generation and then does not touch the new app's state.
        let generation: UInt64
        var busy = false
        var pending: [WindowID: Pending] = [:]
        var pendingOrder: [WindowID] = []
        /// Each `apply` that queues a frame for this app increases `queued`. A batch takes every pending frame,
        /// so when it is written, `landed` becomes the `queued` value at the time it was taken.
        var queued: UInt64 = 0
        var landed: UInt64 = 0
        /// Run when `landed` reaches the number. The argument is true when the frames were dropped by `forgetApp`
        /// or `reset` and not written. `reset` sets `dropped` on every waiter it finds: a frame the waiter waits
        /// for is gone, also when a later batch of the same app makes `landed` reach the number.
        var waiters: [Waiter] = []
        /// Batches in a row in which every write failed. One success sets it to 0.
        var failedBatches = 0
        /// Set by `reset` while a batch runs: the state goes away when the app is idle. A new `apply` clears it.
        var retired = false
        /// The AX clock: the total time of all finished batches of this app, from `beginBatch` to the end of
        /// `endBatch`, and of its `settle` calls. `batchStart` is the start of the batch or settle that runs now. Only the clock's change during an
        /// `apply` call is used, so its start value does not matter.
        var axNanos: UInt64 = 0
        var batchStart: UInt64?

        /// The AX clock at `now`, with the part of the running batch that is done by then.
        func axClock(at now: UInt64) -> UInt64 { axNanos + (batchStart.map { now > $0 ? now - $0 : 0 } ?? 0) }
    }

    private let writer: FrameWriter
    private let onWrite: (@Sendable (WriteTiming) -> Void)?
    private let lock = NSLock()
    private var apps: [pid_t: AppState] = [:]
    private var written: [WindowID: CGRect] = [:]
    /// Frames taken out of `pending` that the app's queue is writing now.
    /// The frame being written to each window, with the token of that write. `forget` and `reset` drop the entry;
    /// a write whose token is gone then does not change `written` when it lands.
    private var inFlight: [WindowID: InFlight] = [:]
    private var nextToken: UInt64 = 0
    /// Counts `reset` calls. A batch taken before a reset reports no timings.
    private var resets: UInt64 = 0
    private var counters = Counters()
    private var nextGeneration: UInt64 = 0

    /// `onWrite` runs on the app's queue at the end of each batch, once per window write, and only while the app
    /// is not forgotten and no `reset` ran since the batch started. It runs with the applier's lock held: it must not call the applier.
    public init(writer: FrameWriter, onWrite: (@Sendable (WriteTiming) -> Void)? = nil) {
        self.writer = writer
        self.onWrite = onWrite
    }

    public var stats: Counters { lock.withLock { counters } }

    /// Apps the applier keeps state for (tests).
    var appCount: Int { lock.withLock { apps.count } }

    /// The last frame written to a window (what macOS has, as far as Spool knows).
    public func lastWritten(_ id: WindowID) -> CGRect? { lock.withLock { written[id] } }

    /// True when `frame` is one that Spool wrote or will write to the window, or the window is being written
    /// now (AX sets position and size one after the other, so a frame read meanwhile can be half of each).
    /// A move notification with such a frame is Spool's own write arriving, not the user.
    public func isOwnFrame(_ id: WindowID, _ frame: CGRect, tolerance: CGFloat = 2) -> Bool {
        lock.withLock {
            if inFlight[id] != nil { return true }
            let pending = apps.values.lazy.compactMap { $0.pending[id]?.write.frame }.first
            return [written[id], inFlight[id]?.frame, pending].contains { Policy.same(frame, $0, tolerance: tolerance) }
        }
    }

    /// Forget a window, for example after it closed or the user moved it by hand.
    public func forget(_ id: WindowID) {
        lock.withLock {
            written.removeValue(forKey: id)
            inFlight.removeValue(forKey: id)
        }
    }

    public func forgetApp(_ pid: pid_t) {
        let waiters = lock.withLock { apps.removeValue(forKey: pid)?.waiters ?? [] }
        for w in waiters { w.run(true, 0) }
    }

    /// Apps whose last `threshold` batches all failed: their AX elements or observer are probably dead.
    public func failingApps(threshold: Int) -> [pid_t] {
        lock.withLock { apps.filter { $0.value.failedBatches >= threshold }.map(\.key).sorted() }
    }

    public func clearFailures(_ pid: pid_t) { lock.withLock { apps[pid]?.failedBatches = 0 } }

    /// Tells every app (or only `pids`) that the animation is over, after its last write. Returns at once.
    public func settle(pids: Set<pid_t>? = nil, completion: (@Sendable () -> Void)? = nil) {
        let group = DispatchGroup()
        let queues = lock.withLock {
            apps.filter { pids?.contains($0.key) ?? true }.map { ($0.key, $0.value.queue, $0.value.generation) }
        }
        for (pid, queue, generation) in queues {
            group.enter()
            queue.async { [self] in
                // The settle call is AX time too: a batch queued behind it waits for it (Chrome can take tens of
                // ms to turn AXEnhancedUserInterface on again). It runs on the app's queue, so no batch runs now.
                lock.withLock { if apps[pid]?.generation == generation { apps[pid]!.batchStart = DispatchTime.now().uptimeNanoseconds } }
                writer.settle(pid: pid)
                let end = DispatchTime.now().uptimeNanoseconds
                lock.withLock {
                    guard apps[pid]?.generation == generation, let begin = apps[pid]!.batchStart else { return }
                    apps[pid]!.axNanos &+= end &- begin
                    apps[pid]!.batchStart = nil
                }
                group.leave()
            }
        }
        if let completion { group.notify(queue: .global(qos: .userInteractive), execute: completion) }
    }

    /// Like `settle`, but waits. Returns false on timeout.
    @discardableResult
    public func settleAndWait(timeout: Double, pids: Set<pid_t>? = nil) -> Bool {
        let done = DispatchSemaphore(value: 0)
        settle(pids: pids) { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Forgets all windows and apps, for example when the engine stops. A batch that runs now still ends, but
    /// does not change what is remembered and reports no timings. Its app's state goes away when it is idle.
    public func reset() {
        let waiters: [@Sendable () -> Void] = lock.withLock {
            written.removeAll()
            inFlight.removeAll()
            resets += 1
            var run: [@Sendable () -> Void] = []
            for (pid, state) in apps {
                if state.busy {
                    apps[pid]!.pending.removeAll()
                    apps[pid]!.pendingOrder.removeAll()
                    apps[pid]!.failedBatches = 0
                    apps[pid]!.retired = true
                    for i in apps[pid]!.waiters.indices { apps[pid]!.waiters[i].dropped = true }
                } else {
                    run += state.waiters.map { w -> @Sendable () -> Void in { w.run(true, 0) } }
                    apps.removeValue(forKey: pid)
                }
            }
            return run
        }
        for w in waiters { w() }
    }

    /// Queues the writes and returns at once. `completion` runs on an unspecified queue when every frame of this
    /// call is written, or replaced by a newer frame that is written, with the wall time in milliseconds.
    /// A frame merged into an app that was already busy is waited for too, but frames of later calls are not.
    /// The time is nil when `forgetApp` or `reset` dropped a frame of this call, or when no frame of this call
    /// needed a write (each one equal to the frame the window has): it is not a frame-write time.
    /// Returns true when a frame of this call was queued or is in flight (this call waits for a window write).
    @discardableResult
    public func apply(_ writes: [FrameWrite], completion: (@Sendable (Double?) -> Void)? = nil) -> Bool {
        applyTimed(writes, completion: completion.map { c in { @Sendable timing in c(timing?.wallMs) } })
    }

    /// `apply`, with the AX part of the wall time. The timing is nil when `apply` would report nil.
    @discardableResult
    public func applyTimed(_ writes: [FrameWrite], completion: (@Sendable (FrameTiming?) -> Void)?) -> Bool {
        let dropped = Flag()
        let ax = MaxBox()
        let start = DispatchTime.now().uptimeNanoseconds
        let group = DispatchGroup()
        var toStart: [(pid_t, DispatchQueue, UInt64)] = []
        var queuedFor = Set<pid_t>()
        lock.withLock {
            for w in writes {
                let pendingSame = apps[w.pid]?.pending[w.id]
                // Compare with the newest frame the window will have: the one in flight, else the written one.
                // A frame equal to an older written frame must still be written after the one in flight.
                if pendingSame == nil, !w.resize, let f = inFlight[w.id], f.frame == w.frame,
                   apps[w.pid]?.generation == f.generation {
                    // Already being written: not written twice, but this call waits for it, and a failed write
                    // is queued again for this call (else the window could keep a wrong frame).
                    counters.skipped += 1
                    inFlight[w.id]!.again = Pending(write: w, queuedAt: start)
                    queuedFor.insert(w.pid)
                    continue
                }
                if pendingSame == nil, !w.resize, inFlight[w.id] == nil, written[w.id] == w.frame {
                    counters.skipped += 1
                    continue
                }
                if apps[w.pid] == nil {
                    nextGeneration += 1
                    apps[w.pid] = AppState(queue: DispatchQueue(label: "spool.ax.\(w.pid)", qos: .userInteractive),
                                           generation: nextGeneration)
                }
                apps[w.pid]!.retired = false
                var w = w
                // A newer frame replaces a waiting one, but not its `resize`.
                if pendingSame?.write.resize == true { w.resize = true }
                if apps[w.pid]!.pending.updateValue(Pending(write: w, queuedAt: start), forKey: w.id) == nil {
                    apps[w.pid]!.pendingOrder.append(w.id)
                } else {
                    counters.coalesced += 1
                }
                queuedFor.insert(w.pid)
            }
            for pid in queuedFor { apps[pid]!.queued += 1 }
            for (pid, state) in apps where !state.busy && !state.pending.isEmpty {
                apps[pid]!.busy = true
                toStart.append((pid, state.queue, state.generation))
            }
            guard completion != nil else { return }
            // A frame in flight belongs to a batch taken at or before the current `queued`, so waiting for
            // `queued` covers it.
            // The AX time of an app during this call is the change of its AX clock until the frames land.
            for pid in queuedFor {
                guard let state = apps[pid], state.landed < state.queued else { continue }
                let clockAtStart = state.axClock(at: start)
                group.enter()
                apps[pid]!.waiters.append(Waiter(upTo: state.queued) { wasDropped, clock in
                    if wasDropped { dropped.set() } else { ax.max(Self.axDelta(clock, since: clockAtStart)) }
                    group.leave()
                })
            }
        }
        for (pid, queue, generation) in toStart {
            queue.async { [self] in drain(pid, generation) }
        }
        guard let completion else { return !queuedFor.isEmpty }
        guard !queuedFor.isEmpty else {
            DispatchQueue.global(qos: .userInteractive).async { completion(nil) }
            return false
        }
        group.notify(queue: .global(qos: .userInteractive)) {
            guard !dropped.isSet else { return completion(nil) }
            completion(FrameTiming(wallMs: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
                                   axMs: Double(ax.value) / 1_000_000))
        }
        return true
    }

    /// The AX time of one app during an `apply` call. `start` is read before the lock and the end of a batch
    /// before the lock of `drain`, so a batch can end before the call starts: then the clock at the start is
    /// later than the clock at the end, and the app did no AX work for this call.
    static func axDelta(_ end: UInt64, since start: UInt64) -> UInt64 { end > start ? end - start : 0 }

    private final class MaxBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt64 = 0
        func max(_ v: UInt64) { lock.withLock { stored = Swift.max(stored, v) } }
        var value: UInt64 { lock.withLock { stored } }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// Like `apply`, but waits. Returns the wall time in milliseconds (also when a frame was dropped or nothing
    /// needed a write), or nil
    /// after `timeout` seconds (an app that does not answer). Not for the main thread in a live tick.
    @discardableResult
    public func applyAndWait(_ writes: [FrameWrite], timeout: Double = .infinity) -> Double? {
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        let start = DispatchTime.now().uptimeNanoseconds
        apply(writes) { ms in
            box.value = ms ?? Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            done.signal()
        }
        if timeout.isFinite {
            guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        } else {
            done.wait()
        }
        return box.value
    }

    private final class Box: @unchecked Sendable { var value = 0.0 }

    /// Runs on the app's queue. Writes everything pending, then anything that arrived meanwhile.
    /// Stops touching the app's state when `forgetApp` removed it (its waiters ran there already).
    private func drain(_ pid: pid_t, _ generation: UInt64) {
        while true {
            var idle: [@Sendable () -> Void] = []
            let taken: (batch: [(Pending, CGRect?, UInt64)], upTo: UInt64, resets: UInt64)? = lock.withLock {
                guard var state = apps[pid], state.generation == generation, !state.pending.isEmpty else {
                    // Nothing left: everything queued is written or was dropped by `reset`.
                    if let state = apps[pid], state.generation == generation {
                        let clock = state.axNanos
                        idle = state.waiters.map { w -> @Sendable () -> Void in { w.run(w.dropped, clock) } }
                        if state.retired {
                            apps.removeValue(forKey: pid)
                        } else {
                            apps[pid]!.busy = false
                            apps[pid]!.landed = state.queued
                            apps[pid]!.waiters.removeAll()
                        }
                    }
                    return nil
                }
                let items = state.pendingOrder.compactMap { id -> (Pending, CGRect?, UInt64)? in
                    guard let p = state.pending[id] else { return nil }
                    nextToken += 1
                    inFlight[id] = InFlight(frame: p.write.frame, token: nextToken, generation: generation)
                    return (p, written[id], nextToken)
                }
                state.pending.removeAll(keepingCapacity: true)
                state.pendingOrder.removeAll(keepingCapacity: true)
                state.batchStart = DispatchTime.now().uptimeNanoseconds
                apps[pid] = state
                return (items, state.queued, resets)
            }
            guard let (batch, upTo, resetsAtTake) = taken else {
                for run in idle { run() }
                return
            }
            writer.beginBatch(pid: pid)
            var results: [(id: WindowID, frame: CGRect, result: WriteResult, token: UInt64)] = []
            var timings: [WriteTiming] = []
            results.reserveCapacity(batch.count)
            for (p, previous, token) in batch {
                let before = DispatchTime.now().uptimeNanoseconds
                let result = writer.write(p.write, previous: previous)
                let after = DispatchTime.now().uptimeNanoseconds
                results.append((p.write.id, p.write.frame, result, token))
                // A closed window is not an app that is slow or failing: its write is left out of the timings.
                if result != .gone {
                    timings.append(WriteTiming(pid: pid, axMs: Double(after - before) / 1_000_000,
                                               latencyMs: Double(after - p.queuedAt) / 1_000_000, id: p.write.id, result: result))
                }
            }
            writer.endBatch(pid: pid)
            let batchEnd = DispatchTime.now().uptimeNanoseconds
            let done: [@Sendable () -> Void] = lock.withLock {
                for r in results {
                    switch r.result {
                    case .written: counters.windowWrites += 1
                    case .failed: counters.windowWrites += 1; counters.errors += 1
                    case .gone: counters.gone += 1
                    }
                    // `forget` or `reset` ran during the write: what the window has is not known any more.
                    guard let f = inFlight[r.id], f.token == r.token else { continue }
                    inFlight.removeValue(forKey: r.id)
                    if r.result.ok {
                        written[r.id] = r.frame
                    } else if r.result == .gone {
                        // No retry: a closed window does not come back. Its remove follows the destroyed notification.
                        written.removeValue(forKey: r.id)
                    } else {
                        written.removeValue(forKey: r.id)
                        if let again = f.again, apps[pid]?.generation == generation, apps[pid]!.pending[r.id] == nil {
                            apps[pid]!.pending[r.id] = again
                            apps[pid]!.pendingOrder.append(r.id)
                        }
                    }
                }
                guard apps[pid]?.generation == generation else { return [] }
                if let batchStart = apps[pid]!.batchStart {
                    apps[pid]!.axNanos &+= batchEnd &- batchStart
                    apps[pid]!.batchStart = nil
                }
                if let onWrite, resets == resetsAtTake { timings.forEach(onWrite) }
                // A gone write counts as not written here: when an app restarts its AX server, every element of it
                // is invalid, and only this count makes `Engine.checkHealth` take fresh elements.
                if results.contains(where: \.result.ok) { apps[pid]!.failedBatches = 0 } else { apps[pid]!.failedBatches += 1 }
                apps[pid]!.landed = max(apps[pid]!.landed, upTo)
                let landed = apps[pid]!.landed
                let clock = apps[pid]!.axNanos
                let ready = apps[pid]!.waiters.filter { $0.upTo <= landed }.map { w -> @Sendable () -> Void in { w.run(w.dropped, clock) } }
                apps[pid]!.waiters.removeAll { $0.upTo <= landed }
                return ready
            }
            for run in done { run() }
        }
    }
}

/// Writes frames with AX. Holds the AX element of every managed window.
final class AXFrameWriter: FrameWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [WindowID: AXUIElement] = [:]
    private var appElements: [pid_t: AXUIElement] = [:]
    private var enhancedUI: [pid_t: Bool] = [:]

    func register(_ id: WindowID, element: AXUIElement, pid: pid_t) {
        lock.withLock {
            elements[id] = element
            if appElements[pid] == nil { appElements[pid] = AX.app(pid) }
        }
    }

    func unregister(_ id: WindowID) { lock.withLock { _ = elements.removeValue(forKey: id) } }

    func unregisterApp(_ pid: pid_t) {
        lock.withLock {
            appElements.removeValue(forKey: pid)
            enhancedUI.removeValue(forKey: pid)
        }
    }

    /// Some apps (Chrome, Electron, Office) animate every AX move while AXEnhancedUserInterface is on, which makes
    /// tiling slow and wobbly. Turn it off at the first batch of an animation and back on when it settles: one
    /// read and two writes per app per animation, not per frame.
    func beginBatch(pid: pid_t) {
        guard let app = lock.withLock({ enhancedUI[pid] == nil ? appElements[pid] : nil }) else { return }
        let on = AX.bool(app, "AXEnhancedUserInterface") == true
        if on { AX.set(app, "AXEnhancedUserInterface", false) }
        lock.withLock { enhancedUI[pid] = on }
    }

    func settle(pid: pid_t) {
        let restore = lock.withLock { enhancedUI.removeValue(forKey: pid) ?? false }
        guard restore, let app = lock.withLock({ appElements[pid] }) else { return }
        AX.set(app, "AXEnhancedUserInterface", true)
    }

    func write(_ w: FrameWrite, previous: CGRect?) -> WriteResult {
        guard let e = lock.withLock({ elements[w.id] }) else { return .gone }
        let steps = Self.steps(w, previous: previous)
        var results: [(AXCall, AXError)] = []
        if steps.size { results.append((.size, AX.setSize(e, w.frame.size))) }
        if steps.position { results.append((.position, AX.setPosition(e, w.frame.origin))) }
        if steps.sizeAgain { AX.setSize(e, w.frame.size) }
        return Policy.writeResult(results)
    }

    /// The AX calls of one write, in this order: size, position, size. The first size keeps a large window from
    /// being pushed back by the display edge when it moves; the last one applies the size the app may have refused
    /// at the old position. The size is written when it changed or the write has `resize`.
    struct Steps: Equatable {
        var size: Bool
        var position: Bool
        var sizeAgain: Bool { size && position }
    }

    static func steps(_ w: FrameWrite, previous: CGRect?) -> Steps {
        Steps(size: w.resize || previous.map { $0.size != w.frame.size } ?? true,
              position: previous.map { $0.origin != w.frame.origin } ?? true)
    }
}
