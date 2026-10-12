import AppKit
import ApplicationServices
import Foundation
import QuartzCore
import StripleCore

extension Engine {
    // MARK: Discovery

    struct Candidate {
        var element: AXUIElement
        var info: WindowInfo
        var decision: WindowDecision
    }

    func classify(_ element: AXUIElement, pid: pid_t) -> Candidate? {
        guard let app = NSRunningApplication(processIdentifier: pid), WindowTracker.isManageable(app),
              let id = AX.windowID(element), id != 0 else { return nil }
        let bundle = app.bundleIdentifier ?? ""
        let traits = AX.traits(element, bundleID: bundle, isOwnApp: false)
        let info = WindowInfo(id: id, pid: pid, bundleID: bundle, title: AX.string(element, kAXTitleAttribute) ?? "")
        return Candidate(element: element, info: info, decision: WindowRules.decide(traits, config: config))
    }

    /// Finds every window of every app. With a session, puts known windows back in their saved places.
    /// Without one, restores the saved strips that were waiting for their Space (or for the screen to unlock).
    func scanAll(session explicit: Session?) {
        var session = explicit
        if session == nil, !laterStrips.isEmpty || !laterFloating.isEmpty {
            session = Session(strips: laterStrips, floating: laterFloating)
            laterStrips = []
            laterFloating = []
        }
        // While the screen is locked AX shows no windows, so nothing would match. Keep the session until it unlocks.
        if let s = session, ScreenLock.isLocked {
            laterStrips = s.strips
            laterFloating = s.floating
            session = nil
            log.log("session: screen is locked, restoring after it unlocks")
        }
        var fresh: [Candidate] = []
        for app in WindowTracker.manageableApps() {
            let pid = app.processIdentifier
            tracker?.watch(pid)
            for element in AX.elements(AX.app(pid), kAXWindowsAttribute) {
                guard let c = classify(element, pid: pid), windows[c.info.id] == nil else { continue }
                fresh.append(c)
            }
        }
        let alive = WindowList.allWindowIDs()
        if !alive.isEmpty {
            for id in Array(windows.keys) where !alive.contains(id) { remove(id) }
        }
        if let s = session {
            let known = Set(Spaces.all().values.joined())
            let split = s.partition(visible: Set(activeSpaces.values), known: known)
            laterStrips = split.later
            session = split.now
        }
        guard let session, !session.strips.isEmpty || !session.floating.isEmpty else {
            for c in fresh { adopt(c, isNew: false, inScan: true) }
            return
        }
        var byID: [WindowID: Candidate] = [:]
        var live: [WindowInfo] = []
        for c in fresh {
            if case .tile = c.decision {
                byID[c.info.id] = c
                live.append(c.info)
            } else {
                adopt(c, isNew: false, inScan: true)
            }
        }
        let restored = session.restore(live: live)
        for saved in restored.strips {
            guard let first = saved.strip.allWindows.first, let c = byID[first.id] else { continue }
            guard let key = stripKey(for: first.id, element: c.element, preferredDisplay: saved.displayID) else {
                for w in saved.strip.allWindows { if let c = byID[w.id] { adopt(c, isNew: false, inScan: true) } }
                continue
            }
            var strip = strips[key] ?? Strip()
            if strip.isEmpty { strip = saved.strip } else { strip.columns += saved.strip.columns }
            strips[key] = strip
            for w in saved.strip.allWindows {
                guard let c = byID[w.id] else { continue }
                register(c, state: .tiled, key: key, createdAt: 0)
            }
        }
        for id in restored.floating {
            guard let c = byID[id] else { continue }
            register(c, state: .floating, key: nil, createdAt: 0)
            windows[id]?.userFloating = true
        }
        for info in restored.unmatched {
            if let c = byID[info.id] { adopt(c, isNew: false, inScan: true) }
        }
        // A saved floating window that still exists is on a Space not on screen. One that is gone is dropped.
        laterFloating = restored.unmatchedFloating.filter { alive.isEmpty || alive.contains($0.id) }
        log.log("session: restored \(restored.strips.count) strips, \(restored.unmatched.count) new windows, \(laterStrips.count) strips wait for their Space")
    }

    /// Finds new windows of one app (after launch, or when its observer came up late).
    func scanApp(_ pid: pid_t) {
        guard pid != getpid() else { return }
        tracker?.watch(pid)
        for element in AX.elements(AX.app(pid), kAXWindowsAttribute) {
            guard let c = classify(element, pid: pid), windows[c.info.id] == nil else { continue }
            adopt(c, isNew: true)
        }
    }

    /// The strip a window belongs to: its display (by its centre, or the saved one) and its Space.
    /// nil when the display is disabled.
    func stripKey(for id: WindowID, element: AXUIElement, preferredDisplay: String? = nil) -> StripKey? {
        let d: EngineDisplay?
        if let preferredDisplay, let saved = display(preferredDisplay) {
            d = saved
        } else if let f = AX.frame(element) {
            d = display(containing: CGPoint(x: f.midX, y: f.midY))
        } else {
            d = displays.first
        }
        guard let d = d ?? displays.first, !isDisabled(d.uuid) else { return nil }
        let active = activeSpaces[d.uuid] ?? 0
        // Without Space information (private calls missing, or one Space for all displays) use one strip per display.
        guard active != 0 else { return StripKey(display: d.uuid, space: 0) }
        let spaces = Spaces.spaces(of: id)
        let space = spaces.contains(active) ? active : (spaces.first ?? active)
        return StripKey(display: d.uuid, space: space)
    }

    /// Starts managing a window as its rules say. `inScan`: part of `scanAll`, whose caller lays out all strips once.
    func adopt(_ c: Candidate, isNew: Bool, inScan: Bool = false) {
        let now = isNew ? CACurrentMediaTime() : 0
        switch c.decision {
        case .ignore:
            // Minimized or fullscreen windows still get observed, so they are adopted when they come back.
            tracker?.observe(window: c.element, pid: c.info.pid)
            if isNew { recheckSoon(c.element, pid: c.info.pid) }
        case .float:
            register(c, state: .floating, key: nil, createdAt: now)
            if isNew { recheckSoon(c.element, pid: c.info.pid) }
        case .tile(let slot):
            guard let key = stripKey(for: c.info.id, element: c.element) else {
                register(c, state: .floating, key: nil, createdAt: now)
                return
            }
            register(c, state: .tiled, key: key, createdAt: now)
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == c.info.pid
            let focus = isNew && (frontmost || !config.behavior.preventFocusStealing)
            var strip = strips[key] ?? Strip()
            strip.insert(c.info, width: .proportion(config.layout.defaultWidth), slot: slot, focus: focus)
            if focus, let m = metrics(key) { strip.ensureFocusVisible(settings: config.layout, metrics: m) }
            strips[key] = strip
            if !inScan {
                relayout(key)
                if focus { showMinimap(key) }
                scheduleSessionSave()
            }
        }
    }

    func register(_ c: Candidate, state: ManagedWindow.State, key: StripKey?, createdAt: Double) {
        windows[c.info.id] = ManagedWindow(info: c.info, element: c.element, state: state, key: key, createdAt: createdAt)
        writer.register(c.info.id, element: c.element, pid: c.info.pid)
        tracker?.observe(window: c.element, pid: c.info.pid)
    }

    /// Some apps create a window first and set its role or subrole a moment later. Look again once.
    private func recheckSoon(_ element: AXUIElement, pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.status == .running, let c = self.classify(element, pid: pid), case .tile = c.decision else { return }
                if let w = self.windows[c.info.id] {
                    guard w.state == .floating, !w.userFloating, self.config.rule(for: c.info.bundleID) == nil else { return }
                    self.windows[c.info.id] = nil
                }
                self.adopt(c, isNew: true)
            }
        }
    }

    /// The managed window behind an AX element. Destroyed elements may no longer report their ID.
    func windowID(of element: AXUIElement, pid: pid_t) -> WindowID? {
        if let id = AX.windowID(element), windows[id] != nil { return id }
        return windows.first { $0.value.info.pid == pid && CFEqual($0.value.element, element) }?.key
    }

    /// Watches an app again and takes fresh AX elements for its windows. Used when all writes to it fail.
    func healApp(_ pid: pid_t) {
        guard NSRunningApplication(processIdentifier: pid) != nil else { return removeApp(pid) }
        tracker?.rewatch(pid)
        var fresh: [WindowID: AXUIElement] = [:]
        for e in AX.elements(AX.app(pid), kAXWindowsAttribute) {
            if let id = AX.windowID(e) { fresh[id] = e }
        }
        let managed = windows.filter { $0.value.info.pid == pid }.mapValues(\.element)
        let plan = Policy.healPlan(managed: managed, fresh: fresh)
        // rewatch dropped every window notification, so all managed windows are observed again. A window that
        // AXWindows does not list may be on another Space; it keeps its old element.
        for (id, e) in plan.observe {
            tracker?.observe(window: e, pid: pid)
            guard plan.renewed.contains(id) else { continue }
            windows[id]?.element = e
            writer.register(id, element: e, pid: pid)
            applier.forget(id)
        }
        let renewed = plan.renewed.count
        scanApp(pid)
        relayoutAll(animate: false)
        log.log("tracker: pid \(pid) watched again, \(renewed) window elements renewed")
    }

    // MARK: Tracker events

    func handle(_ event: TrackerEvent) {
        guard status == .running else { return }
        switch event {
        case .appLaunched(let pid):
            scanApp(pid)
        case .appTerminated(let pid):
            removeApp(pid)
        case .appActivated(let pid), .focusedWindowChanged(let pid):
            focusChanged(pid: pid)
        case .appHidden(let pid):
            for (id, w) in windows where w.info.pid == pid && w.state == .tiled { takeOff(id, as: .hidden) }
        case .appShown(let pid):
            for (id, w) in windows where w.info.pid == pid && w.state == .hidden { putBack(id, focus: false) }
        case .windowCreated(let element, let pid):
            if let c = classify(element, pid: pid), windows[c.info.id] == nil { adopt(c, isNew: true) }
        case .windowDestroyed(let element, let pid):
            if let id = windowID(of: element, pid: pid) { remove(id, focusNeighbor: true) }
        case .windowMoved(let element, let pid):
            geometryChanged(element, pid: pid, resized: false)
        case .windowResized(let element, let pid):
            geometryChanged(element, pid: pid, resized: true)
        case .windowMinimized(let element, let pid):
            if let id = windowID(of: element, pid: pid) { takeOff(id, as: .minimized) }
        case .windowDeminimized(let element, let pid):
            if let id = windowID(of: element, pid: pid), windows[id]?.state == .minimized {
                putBack(id, focus: true)
            } else if let c = classify(element, pid: pid), windows[c.info.id] == nil {
                adopt(c, isNew: true)
            }
        case .titleChanged(let element, let pid):
            titleChanged(element, pid: pid)
        case .spaceChanged:
            spacesChanged()
        case .displaysChanged, .didWake:
            displaysChanged()
        case .sessionResumed:
            sessionResumed()
        }
    }

    /// Windows that existed while the screen was locked were invisible to AX. Find them now.
    private func sessionResumed() {
        let before = windows.count
        refreshDisplays()
        for app in WindowTracker.manageableApps() { tracker?.watch(app.processIdentifier) }
        scanAll(session: nil)
        relayoutAll(animate: false)
        syncFocusWithSystem()
        log.log("session resumed: \(windows.count - before) windows found")
    }

    private func titleChanged(_ element: AXUIElement, pid: pid_t) {
        guard let id = windowID(of: element, pid: pid), var w = windows[id] else { return }
        let title = AX.string(element, kAXTitleAttribute) ?? ""
        guard title != w.info.title else { return }
        w.info.title = title
        windows[id] = w
        if let key = w.key, var strip = strips[key], strip.contains(id) {
            strip.update(w.info)
            strips[key] = strip
            if let m = display(key.display) {
                layouts[key] = Layout.compute(strip, display: m.geometry, settings: config.layout)
            }
            updateOverlays()
        }
    }

    // MARK: Focus

    /// The window that has keyboard focus in the whole system.
    func systemFocusedWindow() -> (id: WindowID, element: AXUIElement, pid: pid_t)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard pid != getpid(), let el = AX.element(AX.app(pid), kAXFocusedWindowAttribute), let id = AX.windowID(el) else { return nil }
        return (id, el, pid)
    }

    func syncFocusWithSystem() {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { focusChanged(pid: pid) }
    }

    /// The focused window of an app changed, or another app came to the front.
    func focusChanged(pid: pid_t) {
        guard pid != getpid(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let el = AX.element(AX.app(pid), kAXFocusedWindowAttribute), let id = AX.windowID(el) else {
            return
        }
        if windows[id] == nil, let c = classify(el, pid: pid) { adopt(c, isNew: false) }
        guard let w = windows[id] else {
            focusedID = nil
            updateFocusOverlays()
            return
        }
        if id != focusedID, config.behavior.preventFocusStealing, let prev = focusedID, let pw = windows[prev],
           pw.info.pid != pid, pw.state == .tiled || pw.state == .floating, w.createdAt > 0 {
            let now = CACurrentMediaTime()
            let launched = NSRunningApplication(processIdentifier: pid)?.launchDate.map { -$0.timeIntervalSinceNow }
            if Policy.isFocusSteal(windowAge: now - w.createdAt, secondsSinceInput: secondsSinceInput(), appAge: launched) {
                log.log("focus: \(w.info.bundleID) took focus without input, giving it back")
                focusWindow(prev, scroll: false, fromCommand: false)
                return
            }
        }
        focusedID = id
        if w.state == .tiled, let key = w.key, var strip = strips[key] {
            let before = strip
            strip.setFocus(id)
            if suppressScrollFor != id, let m = metrics(key) { strip.ensureFocusVisible(settings: config.layout, metrics: m) }
            if strip != before {
                strips[key] = strip
                relayout(key)
                if strip.scroll != before.scroll { showMinimap(key) }
                scheduleSessionSave()
            }
        }
        suppressScrollFor = nil
        floatingBorderFrame = w.state == .floating ? AX.frame(w.element) : nil
        updateFocusOverlays()
    }

    func focusWindow(_ id: WindowID, scroll: Bool, fromCommand: Bool) {
        guard let w = windows[id] else { return }
        if !scroll { suppressScrollFor = id }
        focusedID = id
        Focuser.focus(window: id, pid: w.info.pid, element: w.element)
        updateFocusOverlays()
        if fromCommand, config.behavior.mouseFollowsFocus { warpMouse(to: id) }
    }

    private func warpMouse(to id: WindowID) {
        guard let w = windows[id] else { return }
        let target: CGRect?
        if w.state == .tiled, let key = w.key { target = animators[key]?.target(id).flatMap { f in display(key.display).map { Layout.physical(f, display: $0.geometry, settings: config.layout).frame } } } else { target = AX.frame(w.element) }
        guard let f = target, !f.contains(mouseLocation()) else { return }
        CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: f.midY))
    }

    /// Seconds since the last key press, click or scroll.
    func secondsSinceInput() -> Double {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }

    // MARK: Leaving and joining the strip

    /// Takes a tiled window off its strip (minimized, hidden, fullscreen or floated) and remembers its place.
    func takeOff(_ id: WindowID, as state: ManagedWindow.State) {
        guard var w = windows[id], w.state == .tiled else { return }
        if let key = w.key, var strip = strips[key], let (c, _) = strip.locate(id) {
            w.slot = c + 1
            w.width = strip.columns[c].width
            strip.remove(id)
            if let m = metrics(key) { strip.ensureFocusVisible(settings: config.layout, metrics: m) }
            strips[key] = strip
            w.state = state
            if let p = placements[id], p.hidden { w.parkedFrame = p.frame }
            windows[id] = w
            placements[id] = nil
            relayout(key)
        } else {
            w.state = state
            windows[id] = w
        }
        applier.forget(id)
        scheduleSessionSave()
    }

    /// Puts a window back on the strip of its display, in the place it had.
    func putBack(_ id: WindowID, focus: Bool) {
        guard var w = windows[id], w.state != .tiled else { return }
        let key: StripKey
        if let old = w.key, let d = display(old.display), !isDisabled(d.uuid) {
            key = activeKey(d)
        } else if let k = stripKey(for: id, element: w.element) {
            key = k
        } else {
            return
        }
        var strip = strips[key] ?? Strip()
        strip.insert(w.info, width: w.width ?? .proportion(config.layout.defaultWidth), slot: w.slot, focus: focus)
        if focus, let m = metrics(key) { strip.ensureFocusVisible(settings: config.layout, metrics: m) }
        strips[key] = strip
        w.state = .tiled
        w.key = key
        w.userFloating = false
        w.parkedFrame = nil
        windows[id] = w
        applier.forget(id)
        relayout(key)
        scheduleSessionSave()
    }

    func remove(_ id: WindowID, focusNeighbor: Bool = false) {
        guard let w = windows.removeValue(forKey: id) else { return }
        tracker?.forget(window: w.element, pid: w.info.pid)
        writer.unregister(id)
        applier.forget(id)
        placements[id] = nil
        correctionWork.removeValue(forKey: id)?.cancel()
        corrections[id] = nil
        if drag?.id == id { drag = nil }
        let wasFocused = focusedID == id
        if wasFocused { focusedID = nil }
        if w.state == .tiled, let key = w.key, var strip = strips[key] {
            let next = strip.remove(id)
            if let m = metrics(key) { strip.ensureFocusVisible(settings: config.layout, metrics: m) }
            strips[key] = strip
            relayout(key)
            if focusNeighbor, wasFocused, let next, isActive(key) { focusWindow(next, scroll: true, fromCommand: false) }
        }
        updateFocusOverlays()
        scheduleSessionSave()
    }

    func removeApp(_ pid: pid_t) {
        for (id, w) in windows where w.info.pid == pid { remove(id) }
        writer.unregisterApp(pid)
        applier.forgetApp(pid)
        tracker?.unwatch(pid)
    }

    // MARK: Float and displays

    func toggleFloat() {
        guard let id = systemFocusedWindow()?.id ?? focusedID, let w = windows[id] else { return }
        switch w.state {
        case .tiled:
            let shown = placements[id]
            takeOff(id, as: .floating)
            windows[id]?.userFloating = true
            // A parked window that starts to float must come back into view.
            if let key = w.key, let d = display(key.display), let p = shown {
                let area = d.geometry.usable
                let frame = p.hidden ? CGRect(x: area.midX - p.frame.width / 2, y: area.midY - p.frame.height / 2,
                                              width: p.frame.width, height: p.frame.height) : p.frame
                applyOnce(FrameWrite(id: id, pid: w.info.pid, frame: Policy.bringIntoView(frame, area: area)))
            }
            floatingBorderFrame = AX.frame(w.element)
        case .floating:
            guard let key = stripKey(for: id, element: w.element) else { return }
            windows[id]?.key = key
            windows[id]?.slot = nil
            putBack(id, focus: true)
            focusWindow(id, scroll: true, fromCommand: true)
        default:
            return
        }
        updateFocusOverlays()
        scheduleSessionSave()
    }

    /// One write outside an animation. A tick settles the apps when its animation ends; after this write
    /// nothing else would, and AXEnhancedUserInterface would stay off (VoiceOver loses web content).
    func applyOnce(_ write: FrameWrite) {
        applier.apply([write]) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.ticker?.isRunning != true else { return }
                    self.applier.settle(pids: [write.pid])
                }
            }
        }
    }

    func sendToNextDisplay() {
        guard displays.count > 1, let id = focusedID ?? systemFocusedWindow()?.id, let w = windows[id] else { return }
        let frames = displays.map(\.geometry.frame)
        let fromIndex: Int
        if let key = w.key, w.state == .tiled, let i = displays.firstIndex(where: { $0.uuid == key.display }) {
            fromIndex = i
        } else if let f = AX.frame(w.element), let i = Policy.displayIndex(for: CGPoint(x: f.midX, y: f.midY), frames: frames) {
            fromIndex = i
        } else {
            return
        }
        guard let toIndex = Policy.nextDisplay(after: fromIndex, frames: frames) else { return }
        let from = displays[fromIndex], to = displays[toIndex]
        if w.state == .tiled, let key = w.key, !isDisabled(to.uuid) {
            var source = strips[key] ?? Strip()
            let width = source.locate(id).map { source.columns[$0.column].width }
            source.remove(id)
            if let m = metrics(key) { source.ensureFocusVisible(settings: config.layout, metrics: m) }
            strips[key] = source
            let target = activeKey(to)
            var strip = strips[target] ?? Strip()
            strip.insert(w.info, width: width ?? .proportion(config.layout.defaultWidth), focus: true)
            strip.ensureFocusVisible(settings: config.layout, metrics: to.geometry.metrics(config.layout))
            strips[target] = strip
            windows[id]?.key = target
            relayout(key)
            relayout(target)
            focusWindow(id, scroll: true, fromCommand: true)
        } else {
            if w.state == .tiled { takeOff(id, as: .floating) }
            guard let f = AX.frame(w.element) else { return }
            let frame = Policy.translate(f, from: from.geometry.usable, to: to.geometry.usable)
            applier.forget(id)
            applyOnce(FrameWrite(id: id, pid: w.info.pid, frame: frame))
            floatingBorderFrame = frame
            focusWindow(id, scroll: false, fromCommand: true)
        }
        scheduleSessionSave()
    }

    // MARK: Spaces and displays

    func refreshDisplays() {
        displays = DisplayGeometryBuilder.current()
        var spaces: [String: UInt64] = [:]
        for d in displays { spaces[d.uuid] = Spaces.current(displayUUID: d.uuid) }
        activeSpaces = spaces
    }

    func spacesChanged() {
        let before = activeSpaces
        refreshDisplays()
        guard before != activeSpaces else { return }
        overlays.hideAll()
        scanAll(session: nil)
        reconcileSpaces()
        relayoutAll(animate: false)
        syncFocusWithSystem()
    }

    /// Moves windows whose Space changed (for example dragged in Mission Control) to the right strip.
    private func reconcileSpaces() {
        for (id, w) in windows where w.state == .tiled {
            guard let key = w.key, let active = activeSpaces[key.display], active != 0 else { continue }
            let spaces = Spaces.spaces(of: id)
            guard !spaces.isEmpty, !spaces.contains(key.space) else { continue }
            let target = StripKey(display: key.display, space: spaces.contains(active) ? active : spaces[0])
            var source = strips[key] ?? Strip()
            let width = source.locate(id).map { source.columns[$0.column].width }
            source.remove(id)
            strips[key] = source
            var strip = strips[target] ?? Strip()
            strip.insert(w.info, width: width ?? .proportion(config.layout.defaultWidth), focus: false)
            strips[target] = strip
            windows[id]?.key = target
        }
    }

    func displaysChanged() {
        refreshDisplays()
        let live = Set(displays.map(\.uuid))
        if let main = displays.first {
            let known = Spaces.all()
            for key in Array(strips.keys) where !live.contains(key.display) {
                guard let orphan = strips.removeValue(forKey: key) else { continue }
                animators[key] = nil
                layouts[key] = nil
                // Each column goes to the display and Space macOS moved its first window to.
                for column in orphan.columns {
                    let target = orphanTarget(column, main: main, known: known)
                    var strip = strips[target] ?? Strip()
                    strip.columns.append(column)
                    strips[target] = strip
                    for w in column.windows { windows[w.id]?.key = target }
                }
                log.log("displays: moved \(orphan.allWindows.count) windows from a removed display")
            }
        }
        overlays.hideAll()
        scanAll(session: nil)
        reconcileSpaces()
        for (key, var strip) in strips {
            guard let m = metrics(key) else { continue }
            strip.ensureFocusVisible(settings: config.layout, metrics: m)
            strips[key] = strip
        }
        relayoutAll(animate: false)
        syncFocusWithSystem()
    }

    /// The strip for a column whose display was removed. A Space that macOS has not put on a live display
    /// would hide the column on a strip nobody shows, so that falls back to the display's current Space.
    private func orphanTarget(_ column: Column, main: EngineDisplay, known: [String: Set<UInt64>]) -> StripKey {
        guard let first = column.windows.first, let w = windows[first.id],
              let key = stripKey(for: first.id, element: w.element), let d = display(key.display) else { return activeKey(main) }
        return Policy.spaceExists(key.space, onDisplay: key.display, known: known) ? key : activeKey(d)
    }

    /// Moves every window Striple parked back into view and waits until the apps have done it (at most
    /// `timeout` seconds), then gives the apps back their AXEnhancedUserInterface setting. Used by stop and rebuild,
    /// so no window stays parked at an edge.
    func releaseAll(timeout: Double = Engine.releaseWait) {
        var writes: [FrameWrite] = []
        for (id, w) in windows {
            let target: CGRect?
            let known: CGRect?
            switch w.state {
            case .tiled:
                if let key = w.key, isActive(key), let f = layouts[key]?.frames[id] {
                    target = f
                    known = nil
                } else {
                    target = nil
                    known = placements[id]?.frame ?? applier.lastWritten(id) ?? AX.frame(w.element)
                }
            case .hidden, .minimized:
                target = nil
                known = w.parkedFrame
            case .floating, .fullscreen:
                // Never parked: a floating window that left the strip was brought into view then. Writing an old
                // frame back would undo where the user put it.
                continue
            }
            let disp = w.key.flatMap { display($0.display) }
                ?? known.flatMap { display(containing: CGPoint(x: $0.midX, y: $0.midY)) } ?? displays.first
            guard let d = disp,
                  let r = Policy.releaseFrame(target: target, known: known, display: d.geometry, settings: config.layout) else { continue }
            writes.append(FrameWrite(id: id, pid: w.info.pid, frame: r))
        }
        if !writes.isEmpty, applier.applyAndWait(writes, timeout: timeout) == nil {
            log.log("release: an app did not answer within \(timeout) s, some windows may stay parked")
        }
        if !applier.settleAndWait(timeout: Engine.settleWait) { log.log("release: an app did not answer the settle call") }
    }

    /// The longest `releaseAll` waits for the apps. `IPCClient.lifecycleTimeout` must stay above the sum.
    nonisolated public static let releaseWait: Double = 2
    nonisolated public static let settleWait: Double = 1
}
