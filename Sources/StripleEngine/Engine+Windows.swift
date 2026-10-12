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
        /// Minimized, and tiled when it comes back. A session restore puts it back in its saved slot.
        var minimizedTile = false
        /// Tiled now, or when it comes back from the Dock.
        var tiles: Bool {
            if case .tile = decision { return true }
            return minimizedTile
        }
    }

    /// With `onlyNew`, a window that is already managed gives nil before the trait reads (about 8 AX calls).
    func classify(_ element: AXUIElement, pid: pid_t, onlyNew: Bool = false) -> Candidate? {
        guard let app = NSRunningApplication(processIdentifier: pid), WindowTracker.isManageable(app),
              let id = AX.windowID(element), id != 0 else { return nil }
        if onlyNew, windows[id] != nil { return nil }
        let bundle = app.bundleIdentifier ?? ""
        let traits = AX.traits(element, bundleID: bundle, isOwnApp: false)
        let info = WindowInfo(id: id, pid: pid, bundleID: bundle, title: AX.string(element, kAXTitleAttribute) ?? "")
        var c = Candidate(element: element, info: info, decision: WindowRules.decide(traits, config: config))
        if traits.isMinimized {
            var shown = traits
            shown.isMinimized = false
            if case .tile = WindowRules.decide(shown, config: config) { c.minimizedTile = true }
        }
        return c
    }

    /// Finds every window of every app. With a session, puts known windows back in their saved places.
    /// Without one, restores the saved strips that were waiting for their Space (or for the screen to unlock).
    func scanAll(session explicit: Session?) {
        // Every caller lays out all strips after the scan.
        defer { takeOffWindowsOfHiddenApps(relayoutNow: false) }
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
        // Apps that do not answer. Their windows are found when they answer (a watch retry, or a rescan).
        var quiet: [pid_t: String] = [:]
        var answered = Set<String>()
        for app in WindowTracker.manageableApps() {
            let pid = app.processIdentifier
            tracker?.watch(pid)
            if tracker?.isWaiting(for: pid) == true {
                quiet[pid] = app.bundleIdentifier ?? ""
                continue
            }
            guard let elements = AX.windows(of: pid) else {
                quiet[pid] = app.bundleIdentifier ?? ""
                scheduleQuietRescan(pid)
                continue
            }
            if let bundle = app.bundleIdentifier { answered.insert(bundle) }
            for element in elements {
                guard let c = classify(element, pid: pid, onlyNew: true) else { continue }
                fresh.append(c)
            }
        }
        // Windows of apps that did not answer an earlier restore go back to their places now.
        fresh = placeHeld(fresh, byApp: true, inScan: true)
        // Two copies of one app: held windows wait while either one does not answer.
        defer { releaseHeldSoon(bundles: answered.subtracting(quiet.values)) }
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
            } else if c.minimizedTile {
                byID[c.info.id] = c
                live.append(c.info)
            } else {
                adopt(c, isNew: false, inScan: true)
            }
        }
        // Saved windows of apps that do not answer keep their place until the app answers.
        let restored = session.restore(live: live, waitingFor: Set(quiet.values))
        var restoredInto: [StripKey: StripKey] = [:]
        for saved in restored.strips {
            guard let first = saved.strip.allWindows.first, let c = byID[first.id] else { continue }
            guard let key = stripKey(for: first.id, element: c.element, preferredDisplay: saved.displayID) else {
                for w in saved.strip.allWindows { if let c = byID[w.id] { adopt(c, isNew: false, inScan: true) } }
                continue
            }
            strips[key] = Policy.restoredStrip(saved.strip, into: strips[key], settings: config.layout, metrics: metrics(key))
            restoredInto[StripKey(display: saved.displayID, space: saved.spaceID)] = key
            for w in saved.strip.allWindows {
                guard let c = byID[w.id] else { continue }
                register(c, state: .tiled, key: key, createdAt: 0)
            }
            // A minimized window keeps its slot: it goes back there when it is shown again.
            for w in saved.strip.allWindows where byID[w.id]?.minimizedTile == true {
                takeOff(w.id, as: .minimized, relayoutNow: false)
            }
        }
        // Held windows wait in the strip their saved strip was restored to.
        let pidOf = Dictionary(quiet.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        let known = Set(Spaces.all().values.joined())
        let fallback = displays.first { !isDisabled($0.uuid) }?.uuid
        heldWindows += restored.held.map { h in
            var h = h
            h.info.pid = pidOf[h.info.bundleID] ?? h.info.pid
            if h.floats { return h }
            let k = Policy.heldKey(saved: StripKey(display: h.displayID, space: h.spaceID), restoredInto: restoredInto,
                                   activeSpaces: activeSpaces, knownSpaces: known, fallbackDisplay: fallback)
            h.displayID = k.display
            h.spaceID = k.space
            return h
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
        log.log("session: restored \(restored.strips.count) strips, \(restored.unmatched.count) new windows, \(laterStrips.count) strips wait for their Space, \(heldWindows.count) windows wait for their app")
    }

    /// Finds new windows of one app (after launch, or when its observer came up late). A window that a restore
    /// held for this app goes back to its saved place.
    /// `release`: start the wait after which held windows of the app that no window took are dropped.
    func scanApp(_ pid: pid_t, release: Bool = true) {
        guard pid != getpid() else { return }
        tracker?.watch(pid)
        if tracker?.isWaiting(for: pid) == true { return }
        guard let elements = AX.windows(of: pid) else { return scheduleQuietRescan(pid) }
        quietRescans[pid] = nil
        staleApps.remove(pid)
        // An observer that came up late (a retry after a hang) has no window notifications yet. observe skips
        // windows it already has.
        for w in windows.values where w.info.pid == pid { tracker?.observe(window: w.element, pid: pid) }
        let found = elements.compactMap { classify($0, pid: pid, onlyNew: true) }
        for c in placeHeld(found, byApp: true, inScan: false) { adopt(c, isNew: true) }
        if release, let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier { releaseHeldSoon(bundles: [bundle]) }
        takeOffWindowsOfHiddenApps(pid: pid, relayoutNow: true)
    }

    /// Puts the candidates that are held windows back in their places. Returns the other candidates.
    /// `byApp`: the candidates are all windows of their apps, so a held window with no exact match takes one.
    func placeHeld(_ candidates: [Candidate], byApp: Bool, inScan: Bool) -> [Candidate] {
        guard !heldWindows.isEmpty else { return candidates }
        var pairs = HeldWindow.take(&heldWindows, for: candidates.filter(\.tiles).map(\.info), byApp: byApp, fits: heldWindowFits())
        guard !pairs.isEmpty else { return candidates }
        HeldWindow.passOnNewIDs(&pairs, held: &heldWindows)
        var byID: [WindowID: Candidate] = [:]
        for c in candidates { byID[c.info.id] = c }
        for p in pairs { if let c = byID[p.live.id] { putHeld(c, p.held, inScan: inScan) } }
        let done = Set(pairs.map(\.live.id))
        return candidates.filter { !done.contains($0.info.id) }
    }

    /// Whether a live window can take a held slot by title or by app: it must be on the held window's Space.
    private func heldWindowFits() -> (HeldWindow, WindowInfo) -> Bool {
        var cache: [WindowID: [UInt64]] = [:]
        return { h, w in
            if h.floats || h.spaceID == 0 { return true }
            let spaces = cache[w.id] ?? Spaces.spaces(of: w.id)
            cache[w.id] = spaces
            return Policy.heldWindowFits(heldSpace: h.spaceID, floats: h.floats, windowSpaces: spaces)
        }
    }

    /// Puts a window that the restore held back where it was: floating, or in its saved slot.
    private func putHeld(_ c: Candidate, _ h: HeldWindow, inScan: Bool) {
        guard h.floats else { return putInHeldSlot(c, h, inScan: inScan) }
        register(c, state: .floating, key: nil, createdAt: 0)
        windows[c.info.id]?.userFloating = true
        if !inScan { scheduleSessionSave() }
    }

    /// Puts a window that the restore held back into its saved place, without focus.
    private func putInHeldSlot(_ c: Candidate, _ h: HeldWindow, inScan: Bool) {
        HeldWindow.rename(&heldWindows, from: h.info.id, to: c.info.id)
        guard let key = stripKey(for: c.info.id, element: c.element, preferredDisplay: h.displayID) else {
            return adopt(c, isNew: false, inScan: inScan)
        }
        var strip = strips[key] ?? Strip()
        // A window that is taken off at once (minimized, or its app is hidden) only keeps its slot: no scroll change.
        if c.minimizedTile || NSRunningApplication(processIdentifier: c.info.pid)?.isHidden == true {
            strip.insert(c.info, width: h.width, slot: h.slot(in: strip), focus: false)
        } else {
            strip.insertKeepingView(c.info, width: h.width, slot: h.slot(in: strip), settings: config.layout, metrics: metrics(key))
        }
        strips[key] = strip
        register(c, state: .tiled, key: key, createdAt: 0)
        // A minimized window keeps the place: it goes back there when it is shown again.
        if c.minimizedTile { takeOff(c.info.id, as: .minimized, relayoutNow: false) }
        if !inScan {
            relayout(key)
            scheduleSessionSave()
        }
    }

    /// The apps answered and listed their windows. A held window of them that no live window took is closed,
    /// so it is dropped. One on a Space that is not on screen waits: macOS lists only the windows of the Spaces
    /// on screen. While the screen is locked AX lists no windows, so nothing is dropped then.
    /// A copy of the app that still does not answer keeps the held windows: they can be its windows.
    func releaseHeld(bundles: Set<String>) {
        guard !heldWindows.isEmpty, !bundles.isEmpty, !ScreenLock.isLocked else { return }
        let bundles = bundles.subtracting(bundlesWithAQuietCopy(bundles))
        let onScreen = Set(activeSpaces.values)
        // A floating window has no Space here. One that still exists (a hung app) can be on a Space not on screen.
        let alive = heldWindows.contains { $0.floats && bundles.contains($0.info.bundleID) } ? WindowList.allWindowIDs() : []
        heldWindows.removeAll { h in
            guard bundles.contains(h.info.bundleID) else { return false }
            if h.floats { return alive.isEmpty || !alive.contains(h.info.id) }
            return onScreen.isEmpty || onScreen.contains(h.spaceID)
        }
    }

    /// Many apps answer before they make their windows again (Chrome, Electron apps). So held windows of apps that
    /// answered wait `Policy.heldGraceDelay`. In that time a new window of the app takes a held slot by app (its
    /// title is often still empty). Then the apps are scanned once more and what is left is released.
    func releaseHeldSoon(bundles: Set<String>) {
        let start = bundles.filter { b in heldGrace[b] == nil && heldWindows.contains { $0.info.bundleID == b } }
        guard !start.isEmpty else { return }
        heldGraceSerial += 1
        let token = heldGraceSerial
        for b in start { heldGrace[b] = token }
        DispatchQueue.main.asyncAfter(deadline: .now() + Policy.heldGraceDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.status == .running else { return }
                let mine = Set(start.filter { self.heldGrace[$0] == token })
                for b in mine { self.heldGrace[b] = nil }
                guard !mine.isEmpty else { return }
                for app in NSWorkspace.shared.runningApplications where mine.contains(app.bundleIdentifier ?? "") {
                    self.scanApp(app.processIdentifier, release: false)
                }
                self.releaseHeld(bundles: mine)
            }
        }
    }

    private func bundlesWithAQuietCopy(_ bundles: Set<String>) -> Set<String> {
        var out = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            guard let b = app.bundleIdentifier, bundles.contains(b) else { continue }
            let pid = app.processIdentifier
            if tracker?.isWaiting(for: pid) == true || quietRescans[pid] != nil || staleApps.contains(pid) { out.insert(b) }
        }
        return out
    }

    /// A watched app did not answer a scan. Scan it again later, with the watch retry delays. After the last
    /// attempt, the app is scanned again when it is activated.
    func scheduleQuietRescan(_ pid: pid_t) {
        let n = (quietRescans[pid] ?? 0) + 1
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            quietRescans[pid] = nil
            return
        }
        guard let delay = Policy.watchRetryDelay(attempt: n) else {
            quietRescans[pid] = nil
            staleApps.insert(pid)
            return
        }
        quietRescans[pid] = n
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.status == .running, self.quietRescans[pid] == n else { return }
                self.scanApp(pid)
            }
        }
    }

    /// AX lists the windows of a hidden (⌘H) app, but they are not on screen. Take them off the strip, as the
    /// appHidden event does, so they get no empty column. appShown puts them back in the same place.
    func takeOffWindowsOfHiddenApps(pid: pid_t? = nil, relayoutNow: Bool) {
        var tiled: [WindowID: pid_t] = [:]
        for (id, w) in windows where w.state == .tiled && (pid == nil || w.info.pid == pid) { tiled[id] = w.info.pid }
        let hidden = Set(Set(tiled.values).filter { NSRunningApplication(processIdentifier: $0)?.isHidden == true })
        for id in Policy.windowsToHide(tiled: tiled, hiddenApps: hidden) { takeOff(id, as: .hidden, relayoutNow: relayoutNow) }
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
        let spaces = (activeSpaces[d.uuid] ?? 0) == 0 ? [] : Spaces.spaces(of: id)
        let key = Policy.stripKey(display: d.uuid, activeSpaces: activeSpaces, windowSpaces: spaces, allSpaces: Spaces.all)
        return isDisabled(key.display) ? nil : key
    }

    /// Starts managing a window as its rules say. `inScan`: part of `scanAll`, whose caller lays out all strips once.
    func adopt(_ c: Candidate, isNew: Bool, inScan: Bool = false) {
        // A held window that comes by another path (focus, a new window event) still goes back to its place.
        if !heldWindows.isEmpty, c.tiles,
           let p = HeldWindow.take(&heldWindows, for: [c.info], byApp: heldGrace[c.info.bundleID] != nil, fits: heldWindowFits()).first {
            return putHeld(c, p.held, inScan: inScan)
        }
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
                windows[c.info.id]?.offDisplay = true
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
        // A managed window is never also held, so it is never saved twice.
        if !heldWindows.isEmpty { heldWindows.removeAll { $0.info.id == c.info.id && $0.info.bundleID == c.info.bundleID } }
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
    /// An app that does not answer (hung) keeps its observer and elements: they still work when it comes back.
    func healApp(_ pid: pid_t) {
        guard NSRunningApplication(processIdentifier: pid) != nil else { return removeApp(pid) }
        guard let tracker, tracker.rewatch(pid) else {
            log.log("tracker: pid \(pid) does not answer, keeping its observer")
            return
        }
        var fresh: [WindowID: AXUIElement] = [:]
        for e in AX.elements(AX.app(pid), kAXWindowsAttribute) {
            if let id = AX.windowID(e) { fresh[id] = e }
        }
        let managed = windows.filter { $0.value.info.pid == pid }.mapValues(\.element)
        let plan = Policy.healPlan(managed: managed, fresh: fresh)
        // rewatch dropped every window notification, so all managed windows are observed again. A window that
        // AXWindows does not list may be on another Space; it keeps its old element.
        for (id, e) in plan.observe {
            tracker.observe(window: e, pid: pid)
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
        case .appActivated(let pid):
            // An app that was given up on (it did not answer for a long time), or that has held windows, is
            // scanned again when it is used.
            let onScreen = Set(activeSpaces.values)
            let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            if let tracker,
               Policy.rescanOnActivate(watching: tracker.isWatching(pid), waiting: tracker.isWaiting(for: pid),
                                       rescanPending: quietRescans[pid] != nil, gaveUp: staleApps.contains(pid),
                                       holdsWindows: heldWindows.contains { $0.info.bundleID == bundle && ($0.floats || onScreen.contains($0.spaceID)) }),
               let app = NSRunningApplication(processIdentifier: pid), WindowTracker.isManageable(app) { scanApp(pid) }
            focusChanged(pid: pid)
        case .focusedWindowChanged(let pid):
            focusChanged(pid: pid)
        case .appHidden(let pid):
            for (id, w) in windows where w.info.pid == pid && w.state == .tiled { takeOff(id, as: .hidden) }
        case .appShown(let pid):
            for (id, w) in windows where w.info.pid == pid && w.state == .hidden { putBack(id, focus: false) }
        case .windowCreated(let element, let pid):
            if let c = classify(element, pid: pid, onlyNew: true) { adopt(c, isNew: true) }
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
            } else if let c = classify(element, pid: pid, onlyNew: true) {
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
    func takeOff(_ id: WindowID, as state: ManagedWindow.State, relayoutNow: Bool = true) {
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
            if relayoutNow { relayout(key) }
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
            let k = Policy.putBackKey(old: StripKey(display: d.uuid, space: old.space), windowSpaces: Spaces.spaces(of: id),
                                      activeSpaces: activeSpaces, allSpaces: Spaces.all)
            guard !isDisabled(k.display) else { return floatOffDisplay(id) }
            key = k
        } else if let k = stripKey(for: id, element: w.element) {
            key = k
        } else {
            return floatOffDisplay(id)
        }
        var strip = strips[key] ?? Strip()
        strip.insert(w.info, width: w.width ?? .proportion(config.layout.defaultWidth), slot: w.slot, focus: focus)
        if focus, let m = metrics(key) { strip.ensureFocusVisible(settings: config.layout, metrics: m) }
        strips[key] = strip
        w.state = .tiled
        w.key = key
        w.userFloating = false
        w.offDisplay = false
        w.parkedFrame = nil
        windows[id] = w
        applier.forget(id)
        relayout(key)
        scheduleSessionSave()
    }

    /// A window that comes back (unminimized, shown, out of fullscreen) on a display Striple does not manage: it
    /// floats there, and tiles again when it is moved to a managed display. A floating window stays as it is.
    private func floatOffDisplay(_ id: WindowID) {
        guard var w = windows[id], w.state != .floating, w.state != .tiled else { return }
        w.state = .floating
        w.offDisplay = true
        w.parkedFrame = nil
        windows[id] = w
        applier.forget(id)
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
        quietRescans[pid] = nil
        staleApps.remove(pid)
        let bundle = heldWindows.first { $0.info.pid == pid }?.info.bundleID
        let next = bundle.flatMap { b in
            NSRunningApplication.runningApplications(withBundleIdentifier: b).first { $0.processIdentifier != pid && !$0.isTerminated }?.processIdentifier
        }
        HeldWindow.appQuit(&heldWindows, pid: pid, nextPid: next)
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
        guard before != activeSpaces else {
            // A window moved in Mission Control to the Space on screen of another display changes no active Space.
            let touched = reconcileSpaces()
            for key in touched { relayout(key) }
            if !touched.isEmpty { scheduleSessionSave() }
            return
        }
        overlays.hideAll()
        scanAll(session: nil)
        reconcileSpaces()
        relayoutAll(animate: false)
        syncFocusWithSystem()
    }

    /// Moves windows whose Space changed (for example dragged in Mission Control) to the right strip.
    /// Returns the strips that changed; the caller lays them out.
    @discardableResult
    private func reconcileSpaces() -> Set<StripKey> {
        var touched: Set<StripKey> = []
        for (id, w) in windows where w.state == .tiled || w.offDisplay {
            touched.formUnion(respace(id, relayoutNow: false))
        }
        return touched
    }

    /// Puts one window on the strip of the display and Space it is on now (see `Policy.respaceAction`).
    /// Returns the strips that changed.
    func respace(_ id: WindowID, relayoutNow: Bool) -> Set<StripKey> {
        guard let w = windows[id] else { return [] }
        let action = Policy.respaceAction(
            state: w.state, userFloating: w.userFloating, offDisplay: w.offDisplay, key: w.key,
            windowSpaces: w.state == .tiled ? Spaces.spaces(of: id) : [], activeSpaces: activeSpaces,
            allSpaces: Spaces.all, here: { self.stripKey(for: id, element: w.element) }, isDisabled: { self.isDisabled($0) })
        switch action {
        case .stay:
            return []
        case .float(let from):
            log.log("respace: window \(id) of \(w.info.bundleID) is on a display Striple does not manage, it floats")
            takeOff(id, as: .floating, relayoutNow: relayoutNow)
            windows[id]?.offDisplay = true
            return [from]
        case .move(let from, let to):
            log.log("respace: window \(id) of \(w.info.bundleID) moved to another Space or display")
            var source = strips[from] ?? Strip()
            let width = source.locate(id).map { source.columns[$0.column].width }
            source.remove(id)
            if let m = metrics(from) { source.ensureFocusVisible(settings: config.layout, metrics: m) }
            strips[from] = source
            var strip = strips[to] ?? Strip()
            strip.insert(w.info, width: width ?? .proportion(config.layout.defaultWidth), focus: false)
            strips[to] = strip
            windows[id]?.key = to
            applier.forget(id)
            if relayoutNow {
                relayout(from)
                relayout(to)
            }
            return [from, to]
        case .tile(let to):
            log.log("respace: window \(id) of \(w.info.bundleID) is on a managed display again, it tiles")
            if w.key != to { windows[id]?.slot = nil }
            windows[id]?.key = to
            putBack(id, focus: false)
            return [to]
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
