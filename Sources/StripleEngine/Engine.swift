import AppKit
import ApplicationServices
import Combine
import Foundation
import QuartzCore
import StripleCore

/// The public face of the window engine. The app owns one instance.
/// Everything runs on the main thread except AX frame writes, which run on per-app queues.
@MainActor
public final class Engine: ObservableObject {
    public enum Status: Equatable, Sendable {
        case stopped
        case running
        /// Accessibility permission is missing. The engine starts by itself once it is granted.
        case noPermission
    }

    @Published public private(set) var status: Status = .stopped
    /// Shortcuts that macOS refused because another app or the system already uses them.
    @Published public private(set) var refusedShortcuts: [KeyCombo] = []
    public let configStore: ConfigStore

    /// While true, global shortcuts are not registered, so the shortcut recorder can capture any combo.
    public var hotkeysSuspended = false {
        didSet { if hotkeysSuspended != oldValue { registerHotkeys() } }
    }

    // MARK: Parts

    let log = EngineLog.shared
    let writer: AXFrameWriter
    let applier: FrameApplier
    let overlays = Overlays()
    let recorder = StatsRecorder()
    var tracker: WindowTracker?
    var hotkeys: Hotkeys?
    var gestureTap: GestureTap?
    var ticker: Ticker?
    var mouseUpMonitor: Any?
    var mouseDownMonitor: Any?
    var mouseDraggedMonitor: Any?
    var healthObserver: NSObjectProtocol?
    var mouseMovedMonitor: Any?
    var cancellables: Set<AnyCancellable> = []
    var permissionTimer: Timer?
    var permissionObserver: NSObjectProtocol?

    // MARK: State

    struct StripKey: Hashable {
        var display: String
        var space: UInt64
    }

    struct ManagedWindow {
        enum State: Equatable { case tiled, floating, minimized, hidden, fullscreen }
        var info: WindowInfo
        var element: AXUIElement
        var state: State
        /// The strip the window is on, or was on before it left (minimized, hidden, fullscreen).
        var key: StripKey?
        /// 1-based column and width it had before it left the strip, so it comes back to the same place.
        var slot: Int?
        var width: ColumnWidth?
        /// When Striple first saw the window (media time). 0 for windows that existed before Striple started.
        var createdAt: Double
        /// Floated with toggle-float (kept in the session), not by a rule.
        var userFloating = false
        /// Where the window was parked when it left the strip (hidden or minimized while out of view).
        /// Stop moves it back into view from here.
        var parkedFrame: CGRect?
    }

    struct SwipeState {
        var key: StripKey
        /// Scroll without the rubber band; the strip shows `Policy.rubberBand(raw)`.
        var raw: Double
        var shown: Double
    }

    struct DragState {
        var id: WindowID
        var resize: Bool
    }

    var windows: [WindowID: ManagedWindow] = [:]
    var strips: [StripKey: Strip] = [:]
    var animators: [StripKey: FrameAnimator] = [:]
    var layouts: [StripKey: LayoutResult] = [:]
    /// Where each tiled window is on screen now (after parking), for overlays and focus-follows-mouse.
    var placements: [WindowID: Layout.Placement] = [:]
    var displays: [EngineDisplay] = []
    var activeSpaces: [String: UInt64] = [:]
    /// The config the engine runs with. `configStore.config` changes after the publisher fires, so keep our own copy.
    var config: Config
    var startedAt: Double = 0
    var restarts = 0
    var swipe: SwipeState?
    var drag: DragState?
    var pendingCommandStart: Double?
    var focusedID: WindowID?
    var floatingBorderFrame: CGRect?
    var suppressScrollFor: WindowID?
    var sessionSaveWork: DispatchWorkItem?
    var correctionWork: [WindowID: DispatchWorkItem] = [:]
    var corrections: [WindowID: [Double]] = [:]
    var lastFocusFollow: Double = 0
    /// Where the left button went down, and whether the mouse has moved far enough since to be a drag.
    var mouseDownAt: CGPoint?
    var mouseDragging = false
    /// Saved strips of Spaces that are not on screen, and saved floating windows not found yet.
    /// Restored when they appear; included in every save so they are not lost.
    var laterStrips: [SessionStrip] = []
    var laterFloating: [WindowInfo] = []
    /// When an app was last re-watched after its AX writes kept failing.
    var healedAt: [pid_t: Double] = [:]

    public init(configStore: ConfigStore) {
        self.configStore = configStore
        config = configStore.config
        let w = AXFrameWriter()
        writer = w
        applier = FrameApplier(writer: w)
        overlays.onTabClick = { [weak self] id in self?.perform(.focusWindow(id)) }
        configStore.$config
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] new in MainActor.assumeIsolated { self?.configChanged(new) } }
            .store(in: &cancellables)
        registerHotkeys()
    }

    // MARK: Lifecycle

    public func start() {
        guard status != .running else { return }
        guard Permissions.isTrusted else {
            status = .noPermission
            waitForPermission()
            return
        }
        stopWaitingForPermission()
        startedAt = CACurrentMediaTime()
        let tracker = WindowTracker(onEvent: { [weak self] in self?.handle($0) }, log: { [weak self] in self?.log.log($0) })
        WindowTracker.current = tracker
        self.tracker = tracker
        ticker = Ticker { [weak self] t in self?.tick(t) }
        status = .running
        refreshDisplays()
        tracker.start()
        scanAll(session: loadSession())
        startGestures()
        installMouseMonitors()
        startHealthChecks()
        relayoutAll(animate: false)
        syncFocusWithSystem()
        log.log("engine: started with \(windows.count) windows on \(strips.count) strips, \(displays.count) displays")
    }

    public func stop() {
        switch status {
        case .stopped: return
        case .noPermission:
            stopWaitingForPermission()
            status = .stopped
            return
        case .running: break
        }
        tearDown(release: true)
        status = .stopped
        log.log("engine: stopped")
    }

    /// Stops every input first, so no new frame starts. Then saves the session (synchronously: at quit the
    /// process ends right after) and, with `release`, moves parked windows back into view and waits for it.
    private func tearDown(release: Bool) {
        ticker?.stop()
        ticker = nil
        gestureTap?.stop()
        gestureTap = nil
        removeMouseMonitors()
        stopHealthChecks()
        tracker?.stop()
        WindowTracker.current = nil
        tracker = nil
        swipe = nil
        drag = nil
        saveSessionNow(sync: true)
        if release { releaseAll() }
        overlays.hideAll()
        clearState()
    }

    // MARK: Self-healing (F17)

    /// No timer: the check runs when an animation settles and when any app's Accessibility trust changes.
    private func startHealthChecks() {
        stopHealthChecks()
        healthObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { self?.checkHealth(trustChanged: true) } }
        }
    }

    private func stopHealthChecks() {
        if let o = healthObserver { DistributedNotificationCenter.default().removeObserver(o) }
        healthObserver = nil
    }

    /// Two failures the engine can repair without a restart:
    /// - The Accessibility permission was removed: every AX call fails. Stop and wait until it is back.
    ///   Checked when the trust notification comes, and when writes fail (macOS versions without the notification).
    /// - All writes to one app fail: its AX observer or elements are dead (the app restarted its AX server).
    ///   Watch it again and take fresh window elements. At most once per 30 s per app.
    func checkHealth(trustChanged: Bool = false) {
        guard status == .running else { return }
        let failing = applier.failingApps(threshold: 3)
        guard trustChanged || !failing.isEmpty else { return }
        if !Permissions.isTrusted {
            // Not inside the ticker callback that may have called this: tearDown releases the ticker.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.status == .running, !Permissions.isTrusted else { return }
                    self.log.log("engine: Accessibility permission was removed, waiting until it is given again")
                    self.tearDown(release: false)
                    self.status = .noPermission
                    self.waitForPermission()
                }
            }
            return
        }
        let now = CACurrentMediaTime()
        for pid in failing {
            applier.clearFailures(pid)
            guard now - (healedAt[pid] ?? -.infinity) > 30 else { continue }
            healedAt[pid] = now
            log.log("tracker: AX writes to pid \(pid) keep failing, watching the app again")
            healApp(pid)
        }
    }


    public func restart() {
        restarts += 1
        stop()
        start()
    }

    public func toggle() { status == .stopped ? start() : stop() }

    /// Forgets all windows. Does not move them.
    func clearState() {
        for id in windows.keys { writer.unregister(id) }
        for pid in Set(windows.values.map(\.info.pid)) { writer.unregisterApp(pid) }
        for w in correctionWork.values { w.cancel() }
        correctionWork.removeAll()
        corrections.removeAll()
        windows.removeAll()
        strips.removeAll()
        animators.removeAll()
        layouts.removeAll()
        placements.removeAll()
        applier.reset()
        swipe = nil
        drag = nil
        focusedID = nil
        floatingBorderFrame = nil
        suppressScrollFor = nil
        mouseDownAt = nil
        mouseDragging = false
        laterStrips.removeAll()
        laterFloating.removeAll()
        healedAt.removeAll()
    }

    private func waitForPermission() {
        guard permissionTimer == nil else { return }
        // The notification comes when any app's trust changes; the timer covers macOS versions that do not send it.
        permissionObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { self?.checkPermission() } }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPermission() }
        }
    }

    private func checkPermission() {
        guard status == .noPermission, Permissions.isTrusted else { return }
        log.log("engine: Accessibility permission granted")
        status = .stopped
        start()
    }

    private func stopWaitingForPermission() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let o = permissionObserver { DistributedNotificationCenter.default().removeObserver(o) }
        permissionObserver = nil
    }

    // MARK: Shortcuts

    func registerHotkeys() {
        if hotkeysSuspended {
            hotkeys?.unregisterAll()
            return
        }
        if hotkeys == nil {
            hotkeys = Hotkeys { [weak self] command in
                guard let self, !self.hotkeysSuspended else { return }
                self.perform(command)
            }
        }
        let failed = hotkeys?.register(config.bindings) ?? []
        // Carbon accepts combos that macOS itself uses, so those are reported too.
        let system = Hotkeys.systemShortcuts()
        let taken = Set(config.bindings.values.joined()).intersection(system)
        refusedShortcuts = Array(Set(failed).union(taken)).sorted { $0.usLabel < $1.usLabel }
        if !refusedShortcuts.isEmpty {
            log.log("hotkeys: macOS refused \(refusedShortcuts.map(\.usLabel).joined(separator: ", "))")
        }
    }

    // MARK: Commands

    /// Runs a command from a shortcut, the CLI, a URL or the menu.
    public func perform(_ command: Command) {
        switch command {
        case .start: start(); return
        case .stop: stop(); return
        case .toggleEngine: toggle(); return
        case .restart: restart(); return
        default: break
        }
        guard status == .running else { return }
        pendingCommandStart = CACurrentMediaTime()
        switch command {
        case .toggleFloat: toggleFloat()
        case .sendToNextDisplay: sendToNextDisplay()
        case .focusWindow(let id): focusFromCommand(id)
        default: runStripCommand(command)
        }
    }

    private func runStripCommand(_ command: Command) {
        guard let key = currentKey(), var strip = strips[key], let d = display(key.display) else { return }
        let metrics = d.geometry.metrics(config.layout)
        let before = strip
        guard case .changed(let focus) = strip.apply(command, settings: config.layout, metrics: metrics) else { return }
        if command != .centerColumn { strip.ensureFocusVisible(settings: config.layout, metrics: metrics) }
        strips[key] = strip
        relayout(key)
        if strip.scroll != before.scroll || strip.focusedColumn != before.focusedColumn { showMinimap(key) }
        if let focus, focus != focusedID { focusWindow(focus, scroll: true, fromCommand: true) }
        scheduleSessionSave()
    }

    private func focusFromCommand(_ id: WindowID) {
        guard let w = windows[id] else { return }
        if w.state == .tiled, let key = w.key, var strip = strips[key], let d = display(key.display) {
            strip.setFocus(id)
            strip.ensureFocusVisible(settings: config.layout, metrics: d.geometry.metrics(config.layout))
            strips[key] = strip
            relayout(key)
        }
        focusWindow(id, scroll: true, fromCommand: true)
    }

    /// Answers a CLI request.
    public func handle(_ request: IPCRequest) -> IPCResponse {
        if let query = request.query {
            switch query {
            case .ping: return IPCResponse(ok: true)
            case .state: return IPCResponse(ok: true, state: currentState())
            case .stats: return IPCResponse(ok: true, stats: currentStats())
            }
        }
        guard let command = request.command else { return IPCResponse(ok: false, error: "empty request") }
        switch command {
        case .start, .stop, .toggleEngine, .restart:
            perform(command)
            if status == .noPermission {
                return IPCResponse(ok: false, error: "Striple needs the Accessibility permission. It starts when you allow it.")
            }
            return IPCResponse(ok: true)
        case .focusWindow(let id) where status == .running && windows[id] == nil:
            return IPCResponse(ok: false, error: "No window \(id) in Striple. Run: striple state")
        default:
            guard status == .running else {
                let why = status == .noPermission ? "Striple needs the Accessibility permission" : "Striple is stopped (run: striple start)"
                return IPCResponse(ok: false, error: why)
            }
            perform(command)
            return IPCResponse(ok: true)
        }
    }

    // MARK: State and stats

    public func currentState() -> EngineState {
        let ds = displays.map { d -> EngineState.DisplayState in
            let space = activeSpaces[d.uuid] ?? 0
            let strip = strips[StripKey(display: d.uuid, space: space)] ?? Strip()
            return .init(id: d.uuid, name: d.name, enabled: !config.disabledDisplays.contains(d.uuid), spaceID: space,
                         focusedColumn: strip.focusedColumn, scroll: strip.scroll, columns: strip.columns.map(\.windows))
        }
        let floating = windows.values.filter { $0.state == .floating }.map(\.info).sorted { $0.id < $1.id }
        return EngineState(running: status == .running, accessibilityTrusted: Permissions.isTrusted,
                           focusedWindow: focusedID.flatMap { windows[$0]?.info }, displays: ds, floating: floating)
    }

    public func currentStats() -> EngineStats {
        let c = applier.stats
        let r = recorder.snapshot()
        return EngineStats(uptimeSeconds: status == .running ? CACurrentMediaTime() - startedAt : 0, framesWritten: r.batches,
                           windowWrites: c.windowWrites, skippedWrites: c.skipped, coalescedWrites: c.coalesced, axErrors: c.errors,
                           frameWriteP50: r.frameP50, frameWriteP95: r.frameP95, commandLatencyP50: r.commandP50,
                           commandLatencyP95: r.commandP95, restarts: restarts)
    }

    // MARK: Helpers

    func display(_ uuid: String) -> EngineDisplay? { displays.first { $0.uuid == uuid } }

    func display(containing point: CGPoint) -> EngineDisplay? {
        Policy.displayIndex(for: point, frames: displays.map(\.geometry.frame)).map { displays[$0] }
    }

    func isDisabled(_ uuid: String) -> Bool { config.disabledDisplays.contains(uuid) }

    /// The strip that is on screen on a display now.
    func activeKey(_ d: EngineDisplay) -> StripKey { StripKey(display: d.uuid, space: activeSpaces[d.uuid] ?? 0) }

    func isActive(_ key: StripKey) -> Bool { activeSpaces[key.display] == key.space && !isDisabled(key.display) }

    /// The strip commands act on: the focused tiled window's strip, else the strip under the mouse.
    func currentKey() -> StripKey? {
        if let id = focusedID, let w = windows[id], w.state == .tiled, let k = w.key, isActive(k) { return k }
        guard let d = display(containing: mouseLocation()) ?? displays.first, !isDisabled(d.uuid) else { return nil }
        return activeKey(d)
    }

    func mouseLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    func metrics(_ key: StripKey) -> StripMetrics? { display(key.display)?.geometry.metrics(config.layout) }
}

/// Timing samples, written from the AX queues and read on the main thread.
final class StatsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frame = SampleWindow()
    private var command = SampleWindow()
    private var batches = 0

    func record(frameMs: Double, commandStart: Double?) {
        let now = CACurrentMediaTime()
        lock.withLock {
            frame.add(frameMs)
            batches += 1
            if let commandStart { command.add((now - commandStart) * 1000) }
        }
    }

    func snapshot() -> (batches: Int, frameP50: Double, frameP95: Double, commandP50: Double, commandP95: Double) {
        lock.withLock { (batches, frame.percentile(50), frame.percentile(95), command.percentile(50), command.percentile(95)) }
    }
}
