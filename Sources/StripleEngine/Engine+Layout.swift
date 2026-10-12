import AppKit
import ApplicationServices
import Foundation
import QuartzCore
import StripleCore

extension Engine {
    // MARK: Layout pass

    /// Computes the strip's target frames and starts the animation toward them.
    func relayout(_ key: StripKey, animate: Bool = true, velocityX: Double? = nil) {
        guard isActive(key), let d = display(key.display) else { return }
        guard let strip = strips[key], !strip.isEmpty else {
            animators[key] = nil
            layouts[key] = nil
            return
        }
        let result = Layout.compute(strip, display: d.geometry, settings: config.layout)
        layouts[key] = result
        var anim = animators[key] ?? FrameAnimator(response: config.animation.response, enabled: config.animation.enabled)
        let now = CACurrentMediaTime()
        anim.setTargets(result.frames, at: now, animate: animate, velocityX: velocityX)
        animators[key] = anim
        kick(now)
    }

    func relayoutAll(animate: Bool) {
        for key in strips.keys where isActive(key) { relayout(key, animate: animate) }
        updateFocusOverlays()
    }

    /// Writes the first frame now (lowest latency for a command) and lets the display link do the rest.
    /// While the link runs, it alone writes, so frames never pile up faster than the display refreshes.
    func kick(_ now: Double) {
        guard let ticker else { return }
        if !ticker.isRunning { tick(now) }
    }

    /// One display refresh: writes the animated frames of every visible strip.
    func tick(_ t: Double) {
        guard status == .running else { ticker?.stop(); return }
        var writes: [FrameWrite] = []
        var settled = true
        for (key, anim) in animators where isActive(key) {
            guard let d = display(key.display) else { continue }
            for (id, f) in anim.frames(at: t) {
                guard let w = windows[id], w.state == .tiled, drag?.id != id else { continue }
                let p = Layout.physical(f, display: d.geometry, settings: config.layout)
                placements[id] = p
                writes.append(FrameWrite(id: id, pid: w.info.pid, frame: p.frame))
            }
            if !anim.isSettled(at: t) { settled = false }
        }
        if !writes.isEmpty {
            let start = pendingCommandStart
            pendingCommandStart = nil
            let recorder = self.recorder
            applier.apply(writes) { ms in recorder.record(frameMs: ms, commandStart: start) }
        }
        updateOverlays()
        if settled && swipe == nil {
            ticker?.stop()
        } else if ticker?.isRunning == false {
            ticker?.start()
        }
    }

    // MARK: Overlays

    /// Border and tab bars follow the windows on every frame.
    func updateOverlays() {
        let a = config.appearance
        if a.focusBorder, let id = focusedID, let w = windows[id] {
            if w.state == .tiled, let p = placements[id], !p.hidden {
                overlays.showBorder(around: p.frame, windowID: id, appearance: a)
            } else if w.state == .floating, let f = floatingBorderFrame {
                overlays.showBorder(around: f, windowID: id, appearance: a)
            } else {
                overlays.hideBorder()
            }
        } else {
            overlays.hideBorder()
        }
        let barHeight = CGFloat(config.layout.tabBarHeight)
        var bars: [(frame: CGRect, bar: LayoutResult.TabBar, focusedWindow: WindowID?)] = []
        for (key, result) in layouts where isActive(key) {
            for bar in result.tabBars {
                guard let active = bar.windows[safe: bar.activeIndex], let p = placements[active.id], !p.hidden else { continue }
                bars.append((CGRect(x: p.frame.minX, y: p.frame.minY - barHeight, width: p.frame.width, height: barHeight), bar, focusedID))
            }
        }
        overlays.updateTabBars(bars)
    }

    /// Dimming changes only with focus, not on every frame.
    func updateFocusOverlays() {
        let a = config.appearance
        if a.dimInactive {
            var focused: (window: WindowID, display: String)?
            if let id = focusedID, let w = windows[id] {
                if let key = w.key, w.state == .tiled {
                    focused = (id, key.display)
                } else if let f = floatingBorderFrame, let d = display(containing: CGPoint(x: f.midX, y: f.midY)) {
                    focused = (id, d.uuid)
                }
            }
            overlays.updateDim(displays: displays, focused: focused, appearance: a)
        } else {
            overlays.hideDim()
        }
        updateOverlays()
    }

    func showMinimap(_ key: StripKey) {
        guard config.appearance.minimap, let d = display(key.display), let strip = strips[key], strip.columns.count > 1 else { return }
        let model = MinimapModel.make(strip: strip, display: d.geometry, settings: config.layout)
        overlays.showMinimap(model, on: d, seconds: config.appearance.minimapSeconds)
    }

    // MARK: Moves and resizes

    /// A window moved or changed size. It can be the user dragging it, an app moving itself, a native fullscreen
    /// switch, or Striple's own write arriving.
    func geometryChanged(_ element: AXUIElement, pid: pid_t, resized: Bool) {
        guard let id = windowID(of: element, pid: pid), let w = windows[id] else {
            // A window that left fullscreen (or was ignored before) may need to be adopted now.
            if resized, let c = classify(element, pid: pid), windows[c.info.id] == nil, case .tile = c.decision { adopt(c, isNew: false) }
            return
        }
        switch w.state {
        case .tiled:
            if resized, AX.bool(element, "AXFullScreen") == true {
                takeOff(id, as: .fullscreen)
                return
            }
            if NSEvent.pressedMouseButtons & 1 != 0, swipe == nil {
                guard let f = AX.frame(element), !Policy.same(f, applier.lastWritten(id)) else { return }
                if drag?.id != id { drag = DragState(id: id, resize: false) }
                if let last = applier.lastWritten(id), abs(f.width - last.width) > 2 || abs(f.height - last.height) > 2 {
                    drag?.resize = true
                }
                return
            }
            scheduleCorrection(id)
        case .fullscreen:
            if resized, AX.bool(element, "AXFullScreen") != true {
                // Leaving fullscreen animates; put the window back once the frame is final.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    MainActor.assumeIsolated { self?.putBack(id, focus: true) }
                }
            }
        case .floating:
            if focusedID == id { floatingBorderFrame = AX.frame(element); updateOverlays() }
        default:
            break
        }
    }

    /// An app moved or resized a tiled window by itself. Put it back, unless it keeps refusing (a minimum size).
    private func scheduleCorrection(_ id: WindowID) {
        correctionWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.correct(id) }
        }
        correctionWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func correct(_ id: WindowID) {
        correctionWork[id] = nil
        guard status == .running, drag == nil, swipe == nil, let w = windows[id], w.state == .tiled else { return }
        if ticker?.isRunning == true { scheduleCorrection(id); return }
        guard let f = AX.frame(w.element), let last = applier.lastWritten(id), !Policy.same(f, last) else { return }
        let now = CACurrentMediaTime()
        let recent = (corrections[id] ?? []).filter { now - $0 < 5 }
        guard recent.count < 2 else { return }
        corrections[id] = recent + [now]
        log.log("correct: window \(id) of \(w.info.bundleID) moved by its app, putting it back")
        applier.forget(id)
        tick(now)
    }

    func mouseUp() {
        guard let d = drag else { return }
        drag = nil
        guard let w = windows[d.id], w.state == .tiled, let key = w.key, var strip = strips[key],
              let disp = display(key.display) else { return }
        let m = disp.geometry.metrics(config.layout)
        let dropped = AX.frame(w.element)
        applier.forget(d.id)
        if d.resize {
            if let f = dropped, let (c, _) = strip.locate(d.id) {
                strip.columns[c].width = Policy.adoptedWidth(f.width, metrics: m)
                strip.setFocus(d.id)
                strip.ensureFocusVisible(settings: config.layout, metrics: m)
            }
            strips[key] = strip
        } else if config.behavior.dragToReorder {
            let p = mouseLocation()
            if let target = display(containing: p), target.uuid != key.display, !isDisabled(target.uuid) {
                let width = strip.locate(d.id).map { strip.columns[$0.column].width }
                strip.remove(d.id)
                strip.ensureFocusVisible(settings: config.layout, metrics: m)
                strips[key] = strip
                let tkey = activeKey(target)
                let tm = target.geometry.metrics(config.layout)
                var ts = strips[tkey] ?? Strip()
                let area = target.geometry.workArea(config.layout)
                let gap = ts.dropGap(atStripX: Double(p.x - area.minX) + ts.scroll, metrics: tm)
                ts.insert(w.info, width: width ?? .proportion(config.layout.defaultWidth), slot: gap + 1, focus: true)
                ts.ensureFocusVisible(settings: config.layout, metrics: tm)
                strips[tkey] = ts
                windows[d.id]?.key = tkey
                relayout(key)
                relayout(tkey)
                if let f = dropped { animators[tkey]?.setCurrent(d.id, frame: f, at: CACurrentMediaTime()) }
                focusWindow(d.id, scroll: true, fromCommand: false)
                scheduleSessionSave()
                return
            }
            let area = disp.geometry.workArea(config.layout)
            let gap = strip.dropGap(atStripX: Double(p.x - area.minX) + strip.scroll, metrics: m)
            strip.moveWindow(d.id, toGap: gap)
            strip.setFocus(d.id)
            strip.ensureFocusVisible(settings: config.layout, metrics: m)
            strips[key] = strip
        }
        relayout(key)
        // Animate from where the user let go, not from the old slot.
        if let f = dropped {
            animators[key]?.setCurrent(d.id, frame: f, at: CACurrentMediaTime())
            if ticker?.isRunning == false { ticker?.start() }
        }
        scheduleSessionSave()
    }

    // MARK: Mouse

    func installMouseMonitors() {
        if mouseUpMonitor == nil {
            mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseUp() }
            }
        }
        updateFocusFollowsMouse()
    }

    func removeMouseMonitors() {
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseMovedMonitor { NSEvent.removeMonitor(m) }
        mouseUpMonitor = nil
        mouseMovedMonitor = nil
    }

    /// The mouse-moved monitor runs only while focus-follows-mouse is on: it is the busiest event there is.
    func updateFocusFollowsMouse() {
        let want = status == .running && config.behavior.focusFollowsMouse
        if want, mouseMovedMonitor == nil {
            mouseMovedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseMoved() }
            }
        } else if !want, let m = mouseMovedMonitor {
            NSEvent.removeMonitor(m)
            mouseMovedMonitor = nil
        }
    }

    private func mouseMoved() {
        let now = CACurrentMediaTime()
        guard now - lastFocusFollow > 0.05, swipe == nil, drag == nil, NSEvent.pressedMouseButtons == 0,
              ticker?.isRunning != true else { return }
        lastFocusFollow = now
        let p = mouseLocation()
        guard let id = topWindow(at: p), id != focusedID, let w = windows[id], w.state == .tiled || w.state == .floating else { return }
        focusWindow(id, scroll: false, fromCommand: false)
    }

    /// The front-most normal window under a point, from the window server's list (front to back).
    private func topWindow(at p: CGPoint) -> WindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let own = getpid()
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != own,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.contains(p),
                  let n = info[kCGWindowNumber as String] as? UInt32 else { continue }
            return n
        }
        return nil
    }

    // MARK: Swipes

    func startGestures() {
        guard config.gestures.fingers != .off else { return }
        let tap = GestureTap(fingers: config.gestures.fingers.rawValue,
                             onEvent: { [weak self] in self?.swipeEvent($0) },
                             log: { [weak self] in self?.log.log($0) })
        if !tap.start() { log.log("gestures: trackpad swipes are off (event tap refused)") }
        gestureTap = tap
    }

    func swipeEvent(_ event: SwipeTracker.Event) {
        guard status == .running else { return }
        switch event {
        case .began:
            guard let d = display(containing: mouseLocation()), !isDisabled(d.uuid) else { return }
            let key = activeKey(d)
            guard let strip = strips[key], !strip.isEmpty else { return }
            swipe = SwipeState(key: key, raw: strip.scroll, shown: strip.scroll)
        case .changed(let dx):
            guard var s = swipe, var strip = strips[s.key], let m = metrics(s.key) else { return }
            s.raw += Policy.scrollDelta(dx: dx, viewWidth: m.usableWidth, settings: config.gestures)
            let b = Policy.scrollBounds(strip, settings: config.layout, metrics: m)
            s.shown = Policy.rubberBand(s.raw, lower: b.lower, upper: b.upper, dimension: m.usableWidth * 0.25)
            swipe = s
            strip.scroll = s.shown
            strips[s.key] = strip
            relayout(s.key, animate: false)
            if ticker?.isRunning == false { ticker?.start() }
            showMinimap(s.key)
        case .ended(let velocity):
            guard let s = swipe else { return }
            swipe = nil
            guard var strip = strips[s.key], let m = metrics(s.key) else { return }
            let v = Policy.scrollDelta(dx: velocity, viewWidth: m.usableWidth, settings: config.gestures)
            let snap = strip.snappedScroll(from: s.shown, velocity: v, settings: config.layout, metrics: m)
            strip.scroll = snap.scroll
            strip.focusedColumn = snap.column
            strips[s.key] = strip
            pendingCommandStart = CACurrentMediaTime()
            // Windows move opposite to the scroll, so they start with the fingers' speed.
            relayout(s.key, animate: true, velocityX: -v)
            showMinimap(s.key)
            if let id = strip.focusedWindow?.id, id != focusedID { focusWindow(id, scroll: false, fromCommand: false) }
            scheduleSessionSave()
        }
    }

    // MARK: Session

    func sessionSnapshot() -> Session {
        let saved = strips.filter { !$0.value.isEmpty }
            .map { SessionStrip(displayID: $0.key.display, spaceID: $0.key.space, strip: $0.value) }
            .sorted { ($0.displayID, $0.spaceID) < ($1.displayID, $1.spaceID) }
        let floating = windows.values.filter { $0.state == .floating && $0.userFloating }.map(\.info).sorted { $0.id < $1.id }
        return Session(strips: saved, floating: floating)
    }

    func scheduleSessionSave() {
        sessionSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveSessionNow() } }
        sessionSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveSessionNow() {
        sessionSaveWork?.cancel()
        sessionSaveWork = nil
        guard status == .running, let data = try? JSONEncoder().encode(sessionSnapshot()) else { return }
        let url = StriplePaths.sessionFile
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    func loadSession() -> Session? {
        guard let data = try? Data(contentsOf: StriplePaths.sessionFile) else { return nil }
        do {
            return try JSONDecoder().decode(Session.self, from: data)
        } catch {
            log.log("session: could not read \(StriplePaths.sessionFile.path): \(error)")
            return nil
        }
    }

    // MARK: Config

    func configChanged(_ new: Config) {
        let old = config
        config = new
        if old.bindings != new.bindings { registerHotkeys() }
        guard status == .running else { return }
        if old.gestures.fingers != new.gestures.fingers {
            if new.gestures.fingers == .off {
                gestureTap?.stop()
                gestureTap = nil
            } else if let tap = gestureTap {
                tap.fingers = new.gestures.fingers.rawValue
            } else {
                startGestures()
            }
        }
        if old.animation != new.animation {
            for key in animators.keys {
                animators[key]?.response = new.animation.response
                animators[key]?.enabled = new.animation.enabled
            }
        }
        if old.behavior.focusFollowsMouse != new.behavior.focusFollowsMouse { updateFocusFollowsMouse() }
        if old.rules != new.rules || old.disabledDisplays != new.disabledDisplays {
            rebuild()
            return
        }
        if old.layout != new.layout {
            for (key, var strip) in strips {
                guard let m = metrics(key) else { continue }
                strip.ensureFocusVisible(settings: new.layout, metrics: m)
                strips[key] = strip
            }
            relayoutAll(animate: true)
        }
        if old.appearance != new.appearance {
            if !new.appearance.minimap { overlays.hideMinimaps() }
            updateFocusOverlays()
        }
    }

    /// Starts over with the current windows in their current places (after rule or display changes).
    func rebuild() {
        let session = sessionSnapshot()
        let wasTiled = windows.values.filter { $0.state == .tiled }
        releaseWindows(wasTiled.map(\.info.id))
        overlays.hideAll()
        clearState()
        scanAll(session: session)
        relayoutAll(animate: true)
        syncFocusWithSystem()
        log.log("engine: rebuilt after a rule or display change")
    }
}
