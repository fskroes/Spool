import AppKit
import Foundation
import QuartzCore
import StripleCore

/// The AX queues record per-app write times here. The store is thread safe; this box only adds the bundle ID
/// of each pid, which the main thread keeps up to date.
final class MetricsSink: @unchecked Sendable {
    private let lock = NSLock()
    private var store: MetricsStore?
    private var bundles: [pid_t: String] = [:]

    func set(_ store: MetricsStore?) { lock.withLock { self.store = store } }
    func setBundle(_ bundleID: String, for pid: pid_t) {
        guard !bundleID.isEmpty else { return }
        lock.withLock { bundles[pid] = bundleID }
    }
    func forget(pid: pid_t) { lock.withLock { _ = bundles.removeValue(forKey: pid) } }
    func forgetAllApps() { lock.withLock { bundles.removeAll() } }
    func bundleID(for pid: pid_t) -> String? { lock.withLock { bundles[pid] } }

    /// Called on an AX queue for each window write.
    func record(write t: FrameApplier.WriteTiming) {
        let target = lock.withLock { store.flatMap { s in bundles[t.pid].map { (s, $0) } } }
        guard let (store, bundleID) = target else { return }
        store.recordAXWrite(bundleID: bundleID, ms: t.axMs, failed: t.failed)
    }
}

/// Logs failed AX frame writes, so the log tells why `axErrors` went up: the window, the app, the AX call and the
/// code. Only the first `limit` failures per app and code are logged, so an app that fails every frame does not
/// fill the log. Called on the AX queues; `clear` (when the engine forgets its windows) starts the counts again.
final class WriteFailureLog: @unchecked Sendable {
    static let limit = 3
    private struct Key: Hashable { let pid: pid_t; let code: Int32 }
    private let lock = NSLock()
    private var counts: [Key: Int] = [:]
    private let output: @Sendable (String) -> Void

    init(output: @escaping @Sendable (String) -> Void) { self.output = output }

    func record(_ t: FrameApplier.WriteTiming, bundleID: String?) {
        guard case .failed(_, let code) = t.result else { return }
        let n = lock.withLock { () -> Int in
            let k = Key(pid: t.pid, code: code)
            counts[k, default: 0] += 1
            return counts[k]!
        }
        if let line = Self.message(t, bundleID: bundleID, count: n) { output(line) }
    }

    func clear() { lock.withLock { counts.removeAll() } }

    /// The log line of the `count`th failure of this app with this code, nil when it is not logged.
    static func message(_ t: FrameApplier.WriteTiming, bundleID: String?, count: Int) -> String? {
        guard case .failed(let call, let code) = t.result, count <= limit else { return nil }
        let app = bundleID.map { "\($0) (pid \(t.pid))" } ?? "pid \(t.pid)"
        let more = count == limit ? "; more failures of this app with this code are not logged" : ""
        return "ax: frame write to window \(t.id) of \(app) failed: \(call.rawValue) \(code) (\(Policy.axErrorName(code)))\(more)"
    }
}

/// Local metrics (F24, docs/METRICS.md). The store is nil until `enableMetrics`. All record calls are cheap
/// and do no I/O. `MetricsFlusher` writes the files: once 60 s after the first change, for `striple report`,
/// and at quit; after a failed write it waits longer each time (MetricsFlushPlan).
extension Engine {
    /// Call once at launch. `make` creates the store when metrics are on now, or when the user turns them on later.
    public func enableMetrics(_ make: @escaping () -> MetricsStore) {
        makeMetricsStore = make
        guard config.metrics.enabled else { return }
        startMetrics()
        // What happened before the store existed: the config read at launch and the first shortcut registration.
        if configStore.fileHasError { metricsStore?.record(.configError) }
        if !refusedShortcuts.isEmpty { metricsStore?.record(.hotkeyRefused, count: refusedShortcuts.count) }
    }

    /// Call at quit, after `stop()`: the last flush, then the clean-exit marker.
    public func finishMetrics() {
        guard let store = metricsStore, store.isEnabled else { return }
        metricsFlusher?.flush(sync: true, force: true)
        store.markCleanExit()
    }

    /// `metrics.enabled` changed in the config. Applies at once (F23).
    func metricsSettingChanged() {
        if config.metrics.enabled {
            startMetrics()
        } else if let store = metricsStore, store.isEnabled {
            metricsFlusher?.flush(sync: true, force: true)
            store.markCleanExit()
            store.isEnabled = false
            metricsFlusher?.disconnect()
            metricsFlusher = nil
            metricsSink.set(nil)
            activeSince = nil
            costMeter = CostMeter()
            log.log("metrics: off")
        }
    }

    private func startMetrics() {
        if metricsStore?.isEnabled == true { return }
        guard let store = metricsStore ?? makeMetricsStore?() else { return }
        configStore.onLoadError = { [weak self] in self?.metricsStore?.record(.configError) }
        metricsStore = store
        let flusher = MetricsFlusher(store: store, log: { [weak self] in self?.log.log($0) })
        flusher.beforeWrite = { [weak self] in self?.recordRunningCost() }
        metricsFlusher = flusher
        store.isEnabled = true
        flusher.connect()
        metricsSink.set(store)
        for w in windows.values { metricsSink.setBundle(w.info.bundleID, for: w.info.pid) }
        if status == .running {
            costMeter.started(CostSample.current())
            activeSince = CACurrentMediaTime()
        }
        store.markRunning()
        log.log("metrics: on, files in \(store.directory.path)")
    }

    func metricsEngineStarted() {
        guard let store = metricsStore, store.isEnabled else { return }
        store.record(.engineStart)
        costMeter.started(CostSample.current())
        activeSince = CACurrentMediaTime()
    }

    /// Called by every tear-down (stop, restart, permission lost).
    func metricsEngineStopped() {
        accrueActiveTime()
        activeSince = nil
        if metricsStore?.isEnabled == true { costMeter.stopped(CostSample.current()) }
    }

    /// Records the running time since the last call.
    func accrueActiveTime() {
        guard let since = activeSince, let store = metricsStore else { return }
        let now = CACurrentMediaTime()
        store.recordActive(seconds: max(now - since, 0))
        activeSince = status == .running ? now : nil
    }

    /// Before each write: the running time, and the CPU time and wakeups of the running engine since the last write.
    private func recordRunningCost() {
        accrueActiveTime()
        guard let store = metricsStore, let cost = costMeter.take(CostSample.current()) else { return }
        store.recordCost(cpuSeconds: cost.cpuSeconds, wakeups: cost.wakeups, rssMB: cost.peakMB)
    }

    // MARK: Friction

    /// Friction that a command shows before it runs (it needs the focused window as it is now).
    func noteFriction(before command: Command) {
        guard let store = metricsStore, store.isEnabled else { return }
        let focused = focusedID.flatMap { windows[$0] }
        switch command {
        case .focusLeft, .focusRight, .focusUp, .focusDown, .focusFirst, .focusLast, .focusIndex, .focusWindow:
            store.noteFocusMove(command, bundleID: focused?.info.bundleID)
        case .wider, .narrower, .cycleWidth:
            guard let w = focused, w.state == .tiled, !w.info.bundleID.isEmpty else { return }
            store.noteWidthChange(bundleID: w.info.bundleID, windowCreatedAt: Self.wallClock(mediaTime: w.createdAt))
        default:
            break
        }
    }

    /// The friction of toggle-float on a window: floating a tiled window, or tiling a window that a rule or
    /// the smart check floated. Nil for a window the user floated, or one that floats because of its display.
    nonisolated static func floatFriction(state: ManagedWindow.State, userFloating: Bool, offDisplay: Bool) -> FrictionKind? {
        switch state {
        case .tiled: return .floatTiled
        case .floating where !userFloating && !offDisplay: return .unfloatAuto
        default: return nil
        }
    }

    /// `createdAt` is media time, 0 for windows that existed before Striple started (never "early").
    nonisolated static func wallClock(mediaTime: Double, now: Date = Date(), mediaNow: Double = CACurrentMediaTime()) -> Date {
        guard mediaTime > 0 else { return .distantPast }
        return now.addingTimeInterval(mediaTime - mediaNow)
    }

    // MARK: Marks

    /// Saves a mark folder: the note, the state without titles, the stats, today's metrics and the last minute of
    /// the engine log. The state is read here on the main thread; the files are written off it.
    func saveMark(note: String) {
        guard let store = metricsStore, store.isEnabled else {
            log.log("mark: metrics are off, no mark saved")
            NSSound.beep()
            return
        }
        store.record(.mark)
        let state = currentState()
        let stats = currentStats()
        let day = store.snapshot()
        let now = Date()
        let directory = StriplePaths.marksDirectory
        DispatchQueue.global(qos: .utility).async {
            let log = EngineLog.shared
            log.flush()
            let text = Self.logText(StriplePaths.logFile)
            do {
                let folder = try MetricsMark.write(note: note, state: state, stats: stats, day: day,
                                                   logLines: MetricsMark.logTail(text, now: now),
                                                   marksDirectory: directory, now: now)
                log.log("mark: saved in \(folder.path)")
            } catch {
                log.log("mark: could not save in \(directory.path): \(error)")
            }
        }
    }

    /// The end of the engine log and of the file before the last rotation: enough for the last minute.
    nonisolated static func logText(_ url: URL, maxBytes: Int = 512 * 1024) -> String {
        func tail(_ url: URL) -> String {
            guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
            let data = (try? h.readToEnd()) ?? Data()
            var text = String(decoding: data, as: UTF8.self)
            // A cut in the middle of a line: drop that part line.
            if size > UInt64(maxBytes), let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
            return text
        }
        return tail(url.appendingPathExtension("1")) + tail(url)
    }
}
