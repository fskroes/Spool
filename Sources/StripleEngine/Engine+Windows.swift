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
    func scanAll(session: Session?) {
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
        guard let session, !session.strips.isEmpty || !session.floating.isEmpty else {
            for c in fresh { adopt(c, isNew: false) }
            return
        }
        var byID: [WindowID: Candidate] = [:]
        var live: [WindowInfo] = []
        for c in fresh {
            if case .tile = c.decision {
                byID[c.info.id] = c
                live.append(c.info)
            } else {
                adopt(c, isNew: false)
            }
        }
        let restored = session.restore(live: live)
        for saved in restored.strips {
            guard let first = saved.strip.allWindows.first, let c = byID[first.id] else { continue }
            guard let key = stripKey(for: first.id, element: c.element, preferredDisplay: saved.displayID) else {
                for w in saved.strip.allWindows { if let c = byID[w.id] { adopt(c, isNew: false) } }
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
            if let c = byID[info.id] { adopt(c, isNew: false) }
        }
        log.log("session: restored \(restored.strips.count) strips, \(restored.unmatched.count) new windows")
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

    /// Starts managing a window as its rules say.
    func adopt(_ c: Candidate, isNew: Bool) {
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
            if isNew {
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
                applier.apply([FrameWrite(id: id, pid: w.info.pid, frame: Policy.bringIntoView(frame, area: area))])
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
            applier.apply([FrameWrite(id: id, pid: w.info.pid, frame: frame)])
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
            let target = activeKey(main)
            for key in Array(strips.keys) where !live.contains(key.display) {
                guard let orphan = strips.removeValue(forKey: key) else { continue }
                animators[key] = nil
                layouts[key] = nil
                var strip = strips[target] ?? Strip()
                strip.columns += orphan.columns
                strips[target] = strip
                for w in orphan.allWindows { windows[w.id]?.key = target }
                log.log("displays: moved \(orphan.allWindows.count) windows from a removed display to \(main.name)")
            }
        }
        overlays.hideAll()
        scanAll(session: nil)
        for (key, var strip) in strips {
            guard let m = metrics(key) else { continue }
            strip.ensureFocusVisible(settings: config.layout, metrics: m)
            strips[key] = strip
        }
        relayoutAll(animate: false)
        syncFocusWithSystem()
    }

    /// Moves windows into view on their display. Used when Striple stops, so no window stays parked at an edge.
    func releaseWindows(_ ids: [WindowID]) {
        var writes: [FrameWrite] = []
        for id in ids {
            guard let w = windows[id], let key = w.key, let d = display(key.display),
                  let f = applier.lastWritten(id) ?? AX.frame(w.element) else { continue }
            let r = Policy.bringIntoView(f, area: d.geometry.usable)
            if r != f { writes.append(FrameWrite(id: id, pid: w.info.pid, frame: r)) }
        }
        guard !writes.isEmpty else { return }
        applier.applyAndWait(writes)
    }
}
