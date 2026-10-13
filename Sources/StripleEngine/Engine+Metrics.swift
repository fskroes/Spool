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

    /// Called on an AX queue for each window write.
    func record(write t: FrameApplier.WriteTiming) {
        let target = lock.withLock { store.flatMap { s in bundles[t.pid].map { (s, $0) } } }
        guard let (store, bundleID) = target else { return }
        store.recordAXWrite(bundleID: bundleID, ms: t.axMs, failed: t.failed)
    }
}

/// Local metrics (F24, docs/METRICS.md). The store is nil until `enableMetrics`. All record calls are cheap
/// and do no I/O; files are written by one flush 60 s after the first change, by `striple report`, and at quit.
extension Engine {
    /// Seconds from the first unsaved change to the flush.
    static let metricsFlushDelay: TimeInterval = 60

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
        flushMetrics(sync: true, final: true)
        store.markCleanExit()
    }

    /// `metrics.enabled` changed in the config. Applies at once (F23).
    func metricsSettingChanged() {
        if config.metrics.enabled {
            startMetrics()
        } else if let store = metricsStore, store.isEnabled {
            flushMetrics(sync: true, final: true)
            store.markCleanExit()
            store.isEnabled = false
            metricsSink.set(nil)
            activeSince = nil
            costBaseline = nil
            log.log("metrics: off")
        }
    }

    private func startMetrics() {
        if metricsStore?.isEnabled == true { return }
        guard let store = metricsStore ?? makeMetricsStore?() else { return }
        configStore.onLoadError = { [weak self] in self?.metricsStore?.record(.configError) }
        store.isEnabled = true
        store.onFirstChange = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleMetricsFlush() } }
        }
        metricsStore = store
        metricsSink.set(store)
        for w in windows.values { metricsSink.setBundle(w.info.bundleID, for: w.info.pid) }
        costBaseline = CostSample.current()
        activeSince = status == .running ? CACurrentMediaTime() : nil
        store.markRunning()
        log.log("metrics: on, files in \(store.directory.path)")
    }

    func metricsEngineStarted() {
        guard let store = metricsStore else { return }
        store.record(.engineStart)
        if store.isEnabled { activeSince = CACurrentMediaTime() }
    }

    /// Called by every tear-down (stop, restart, permission lost).
    func metricsEngineStopped() {
        accrueActiveTime()
        activeSince = nil
    }

    /// Records the running time since the last call.
    func accrueActiveTime() {
        guard let since = activeSince, let store = metricsStore else { return }
        let now = CACurrentMediaTime()
        store.recordActive(seconds: max(now - since, 0))
        activeSince = status == .running ? now : nil
    }

    private func recordCost() {
        guard let store = metricsStore, let now = CostSample.current() else { return }
        if let base = costBaseline {
            let d = now.delta(since: base)
            store.recordCost(cpuSeconds: d.cpuSeconds, wakeups: d.wakeups, rssMB: d.rssMB)
        }
        costBaseline = now
    }

    /// One flush, `metricsFlushDelay` after the first change since the last flush. No repeating timer.
    func scheduleMetricsFlush() {
        guard !metricsFlushScheduled, metricsStore?.isEnabled == true else { return }
        metricsFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.metricsFlushDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.metricsFlushScheduled = false
                self?.flushMetrics(sync: false)
            }
        }
    }

    /// Records the running time and the process cost since the last flush, then writes the day file.
    /// Without unsaved changes it does nothing, so an idle app does not wake up to write (SPEC idle rule):
    /// the time and cost then go into the next flush. `final` (quit, metrics off) always writes them.
    /// `sync` writes before it returns (quit, `striple report`); else the write runs off the main thread.
    func flushMetrics(sync: Bool, final: Bool = false) {
        guard let store = metricsStore, store.isEnabled, final || store.hasUnsavedChanges else { return }
        accrueActiveTime()
        recordCost()
        let write: @Sendable () -> Void = {
            do { try store.flush() } catch { EngineLog.shared.log("metrics: could not save the day file: \(error)") }
        }
        if sync { write() } else { DispatchQueue.global(qos: .utility).async(execute: write) }
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
