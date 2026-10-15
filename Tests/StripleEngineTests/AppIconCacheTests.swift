import AppKit
import Testing
@testable import StripleCore
@testable import StripleEngine

@MainActor
@Suite struct AppIconCacheTests {
    nonisolated static func image() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
    }

    /// Waits until the background queue made every icon and the main thread stored it.
    static func waitUntilDone(_ cache: AppIconCache) async throws {
        let deadline = Date().addingTimeInterval(2)
        while cache.pendingCount > 0, Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        #expect(cache.pendingCount == 0, "the icon was made within 2 s")
    }

    /// The cache rules, with each icon made at once (no background queue).
    static func sync(_ lookup: @escaping @Sendable (Int32, String) -> NSImage?) -> AppIconCache {
        AppIconCache(queue: nil, lookup: lookup)
    }

    static func keys(_ pids: some Sequence<Int32>, _ bundleID: String = "b") -> Set<AppIconCache.Key> {
        Set(pids.map { AppIconCache.Key(pid: $0, bundleID: bundleID) })
    }

    @Test func eachAppIsLookedUpOnce() {
        let asked = Asked()
        let cache = Self.sync { pid, _ in asked.add(pid); return Self.image() }
        for _ in 0..<5 {
            #expect(cache.icon(pid: 10, bundleID: "com.a") != nil)
            #expect(cache.icon(pid: 20, bundleID: "com.b") != nil)
        }
        #expect(asked.pids == [10, 20])
        #expect(cache.lookups == 2)
    }

    @Test func anAppWithNoIconIsNotLookedUpAgain() {
        let cache = Self.sync { _, _ in nil }
        for _ in 0..<5 { #expect(cache.icon(pid: 10, bundleID: "com.a") == nil) }
        #expect(cache.lookups == 1)
    }

    @Test func anUnknownPidHasNoIconAndNoLookup() {
        let cache = Self.sync { _, _ in Self.image() }
        #expect(cache.icon(pid: 0, bundleID: "") == nil)
        #expect(cache.icon(pid: -1, bundleID: "com.a") == nil)
        #expect(cache.lookups == 0)
    }

    @Test func aReusedPidOfAnotherAppGetsANewIcon() {
        let cache = Self.sync { _, _ in Self.image() }
        _ = cache.icon(pid: 10, bundleID: "com.old")
        _ = cache.icon(pid: 10, bundleID: "com.new")
        #expect(cache.lookups == 2)
    }

    /// A full cache removes only the icon that was used least recently, not all of them.
    @Test func aFullCacheRemovesTheLeastRecentlyUsedIcon() {
        let asked = Asked()
        let cache = Self.sync { pid, _ in asked.add(pid); return Self.image() }
        let limit = Int32(AppIconCache.limit)
        for pid in 1...limit { _ = cache.icon(pid: pid, bundleID: "b") }
        #expect(cache.count == AppIconCache.limit)
        _ = cache.icon(pid: 1, bundleID: "b")
        #expect(cache.lookups == AppIconCache.limit, "still cached at the limit")
        // Pid 1 was used last, so pid 2 is now the least recently used icon.
        _ = cache.icon(pid: 999, bundleID: "b")
        #expect(cache.count == AppIconCache.limit, "the cache does not grow past the limit")
        for pid in [1, 3, limit, 999] as [Int32] { _ = cache.icon(pid: pid, bundleID: "b") }
        #expect(cache.lookups == AppIconCache.limit + 1, "only pid 999 was looked up: the other icons stayed")
        _ = cache.icon(pid: 2, bundleID: "b")
        #expect(asked.pids.suffix(2) == [999, 2], "pid 2 was removed, so it is looked up again")
        #expect(cache.count == AppIconCache.limit)
    }

    /// A draw uses many icons with no new app between them. Each use counts on its own, so of those the icon
    /// used first is removed first, not a random one of them.
    @Test func eachUseCountsInTheOrder() {
        let cache = Self.sync { _, _ in Self.image() }
        let limit = Int32(AppIconCache.limit)
        for pid in 1...limit { _ = cache.icon(pid: pid, bundleID: "b") }
        for pid in 1...limit { _ = cache.icon(pid: pid, bundleID: "b") }
        _ = cache.icon(pid: 999, bundleID: "b")
        for pid in 2...limit { _ = cache.icon(pid: pid, bundleID: "b") }
        #expect(cache.lookups == AppIconCache.limit + 1, "only pid 1, used first in the draw, was removed")
        _ = cache.icon(pid: 1, bundleID: "b")
        #expect(cache.lookups == AppIconCache.limit + 2)
    }

    /// A missing icon is an entry too: it is removed by age like an icon, and then looked up again.
    @Test func aKnownMissingIconIsRemovedByAgeToo() {
        let cache = Self.sync { pid, _ in pid == 1 ? nil : Self.image() }
        for pid in 1...Int32(AppIconCache.limit) + 1 { _ = cache.icon(pid: pid, bundleID: "b") }
        #expect(cache.count == AppIconCache.limit)
        #expect(cache.icon(pid: 1, bundleID: "b") == nil)
        #expect(cache.lookups == AppIconCache.limit + 2, "pid 1 was the oldest entry, so it was looked up again")
    }

    /// The bug this cache had: at 64 icons, one new app emptied the whole cache, so each icon on screen was
    /// nil for 1 to 90 ms and the minimap drew it as a grey block (a blink). Now a new app removes the oldest
    /// icon. Each draw uses the icons on screen, so that is never one of them, also with no `shown` set.
    @Test func theIconsOnScreenStayWhenNewAppsFillTheCache() async throws {
        let cache = AppIconCache(queue: DispatchQueue(label: "test.icons")) { _, _ in Self.image() }
        let onScreen = Array(Int32(1)...10)
        for pid in onScreen { _ = cache.icon(pid: pid, bundleID: "b") }
        try await Self.waitUntilDone(cache)
        let lookups = cache.lookups
        // 3 times the limit of new apps, one at a time, with a minimap draw before and after each one.
        for pid in Int32(100)..<Int32(100 + 3 * AppIconCache.limit) {
            for shown in onScreen { #expect(cache.icon(pid: shown, bundleID: "b") != nil, "pid \(shown) blinks at new app \(pid)") }
            _ = cache.icon(pid: pid, bundleID: "b")
            for shown in onScreen { #expect(cache.icon(pid: shown, bundleID: "b") != nil, "pid \(shown) blinks at new app \(pid)") }
            try await Self.waitUntilDone(cache)
            #expect(cache.count <= AppIconCache.limit)
        }
        #expect(cache.lookups == lookups + 3 * AppIconCache.limit, "no icon on screen was looked up again")
        #expect(cache.count == AppIconCache.limit)
    }

    /// A minimap on screen draws again only when something changes. While it does not draw, its icons get old,
    /// but the cache must not remove them: the next `onLoad` redraws it, and a removed icon would blink.
    @Test func theIconsOfAMinimapOnScreenStayWhileItDoesNotDraw() {
        let cache = Self.sync { _, _ in Self.image() }
        let onA = Array(Int32(1)...10)
        cache.shown = { Self.keys(onA, "a") }
        for pid in onA { _ = cache.icon(pid: pid, bundleID: "a") }
        // Another minimap shows more new apps than the limit. A does not draw in that time.
        for pid in Int32(100)..<Int32(100 + 2 * AppIconCache.limit) { _ = cache.icon(pid: pid, bundleID: "b") }
        #expect(cache.count == AppIconCache.limit)
        let lookups = cache.lookups
        for pid in onA { #expect(cache.icon(pid: pid, bundleID: "a") != nil, "icon \(pid) of A stays") }
        #expect(cache.lookups == lookups, "no icon of A was made again")
        // A is hidden now: its icons are old icons like the others.
        cache.shown = { [] }
        for pid in Int32(1000)..<Int32(1000 + AppIconCache.limit) { _ = cache.icon(pid: pid, bundleID: "b") }
        _ = cache.icon(pid: 1, bundleID: "a")
        #expect(cache.lookups == lookups + AppIconCache.limit + 1, "the icons of a hidden minimap are removed")
    }

    /// More apps on screen than the limit (3 or more minimaps): the cache keeps them all while they are shown,
    /// so the icons settle after one load. A plain limit would loop: each ready icon removes the oldest icon on
    /// screen, `onLoad` redraws, and that draw makes the removed icon again.
    @Test func moreAppsOnScreenThanTheLimitDoNotLoop() async throws {
        let cache = AppIconCache(queue: DispatchQueue(label: "test.icons")) { _, _ in Self.image() }
        let loaded = Loaded()
        cache.onLoad = { loaded.count += 1 }
        var onScreen = Array(Int32(1)...Int32(AppIconCache.limit + 10))
        cache.shown = { Self.keys(onScreen) }
        for pid in onScreen { _ = cache.icon(pid: pid, bundleID: "b") }
        try await Self.waitUntilDone(cache)
        #expect(loaded.count == onScreen.count)
        // The redraws that `onLoad` asks for.
        for round in 1...3 {
            for pid in onScreen { #expect(cache.icon(pid: pid, bundleID: "b") != nil, "pid \(pid) blinks in redraw \(round)") }
            try await Self.waitUntilDone(cache)
        }
        #expect(cache.lookups == onScreen.count, "no icon was made twice")
        #expect(loaded.count == onScreen.count, "no more redraws after the first load")
        #expect(cache.count == onScreen.count, "the cache grew past the limit while the icons were on screen")
        // One more app comes on screen.
        onScreen.append(999)
        _ = cache.icon(pid: 999, bundleID: "b")
        try await Self.waitUntilDone(cache)
        for pid in onScreen { #expect(cache.icon(pid: pid, bundleID: "b") != nil, "pid \(pid) blinks after the new app") }
        #expect(cache.lookups == onScreen.count)
        #expect(cache.count == onScreen.count)
    }

    /// When the minimaps hide, the next new app shrinks the cache back to the limit, oldest icons first.
    @Test func theCacheShrinksToTheLimitWhenTheMinimapsHide() {
        let cache = Self.sync { _, _ in Self.image() }
        let over = Int32(AppIconCache.limit + 10)
        cache.shown = { Self.keys(1...over) }
        for pid in 1...over { _ = cache.icon(pid: pid, bundleID: "b") }
        #expect(cache.count == Int(over), "all icons are on screen, so none is removed")
        cache.shown = { [] }
        _ = cache.icon(pid: 500, bundleID: "b")
        #expect(cache.count == AppIconCache.limit, "back to the limit")
        let lookups = cache.lookups
        let newest = Array(over - Int32(AppIconCache.limit) + 2...over)
        for pid in newest + [500] { _ = cache.icon(pid: pid, bundleID: "b") }
        #expect(cache.lookups == lookups, "the newest icons stayed")
        _ = cache.icon(pid: newest[0] - 1, bundleID: "b")
        #expect(cache.lookups == lookups + 1, "an older icon was removed")
    }

    /// When the cache is full, it removes the least recently used icon that no minimap shows. An older icon on
    /// screen stays, and the cache does not grow for it.
    @Test func theOldestIconThatIsNotShownIsRemoved() {
        let cache = Self.sync { _, _ in Self.image() }
        cache.shown = { Self.keys([1]) }
        for pid in 1...Int32(AppIconCache.limit) { _ = cache.icon(pid: pid, bundleID: "b") }
        _ = cache.icon(pid: 999, bundleID: "b")
        #expect(cache.count == AppIconCache.limit)
        let lookups = cache.lookups
        _ = cache.icon(pid: 1, bundleID: "b")
        _ = cache.icon(pid: 3, bundleID: "b")
        #expect(cache.lookups == lookups, "pid 1 is shown and pid 3 is newer than pid 2")
        _ = cache.icon(pid: 2, bundleID: "b")
        #expect(cache.lookups == lookups + 1, "pid 2 was removed")
    }

    /// `Overlays` tells the cache the apps of each minimap panel that is on screen, and only of those.
    /// It orders a real panel in, so it needs a window server (a login session, not SSH only).
    @Test(.enabled(if: CGSessionCopyCurrentDictionary() != nil, "needs a window server"))
    func theOverlaysKeepTheIconsOfAMinimapOnScreen() throws {
        let overlays = Overlays(appIcons: Self.sync { _, _ in Self.image() })
        let entry = overlays.minimapEntry("D")
        let other = overlays.minimapEntry("E")
        entry.view.model = MinimapModel(items: (1...3).map {
            .init(rect: CGRect(x: 0, y: 0, width: 0.1, height: 1), highlighted: false, pid: Int32($0), bundleID: "a")
        }, viewport: CGRect(x: 0, y: 0, width: 1, height: 1))
        other.view.model = MinimapModel(items: [
            .init(rect: CGRect(x: 0, y: 0, width: 0.1, height: 1), highlighted: false, pid: 9, bundleID: "e"),
        ], viewport: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(overlays.appIcons.shown().isEmpty, "no minimap is on screen")
        // The panel has no size, so nothing shows on the screen of the test machine.
        entry.panel.orderFrontRegardless()
        defer { entry.panel.orderOut(nil) }
        try #require(entry.panel.isVisible)
        #expect(overlays.appIcons.shown() == Self.keys(1...3, "a"), "the apps of the minimap on screen, not of E")
        for pid in Int32(1)...3 { _ = overlays.appIcons.icon(pid: pid, bundleID: "a") }
        for pid in Int32(100)..<Int32(100 + 2 * AppIconCache.limit) { _ = overlays.appIcons.icon(pid: pid, bundleID: "b") }
        let lookups = overlays.appIcons.lookups
        for pid in Int32(1)...3 { _ = overlays.appIcons.icon(pid: pid, bundleID: "a") }
        #expect(overlays.appIcons.lookups == lookups, "the icons of the minimap on screen stayed")
        entry.panel.orderOut(nil)
        #expect(overlays.appIcons.shown().isEmpty, "a hidden minimap keeps no icons")
    }

    /// Icons that the background queue finishes go through the same limit: many apps at once do not grow the
    /// cache past it.
    @Test func manyIconsMadeAtOnceStayInTheLimit() async throws {
        let cache = AppIconCache(queue: DispatchQueue(label: "test.icons")) { _, _ in Self.image() }
        for pid in 1...Int32(2 * AppIconCache.limit) { _ = cache.icon(pid: pid, bundleID: "b") }
        #expect(cache.pendingCount == 2 * AppIconCache.limit)
        try await Self.waitUntilDone(cache)
        #expect(cache.count == AppIconCache.limit)
        let newest = Int32(2 * AppIconCache.limit)
        #expect(cache.icon(pid: newest, bundleID: "b") != nil, "the icon finished last stays")
        #expect(cache.lookups == 2 * AppIconCache.limit)
    }

    @Test func theIconIsASmallRetinaBitmap() throws {
        let cache = Self.sync { _, _ in Self.image() }
        let icon = try #require(cache.icon(pid: 10, bundleID: "com.a"))
        #expect(icon.size == NSSize(width: MinimapModel.maxIconSide, height: MinimapModel.maxIconSide))
        #expect(icon.representations.count == 1)
        let rep = try #require(icon.representations.first as? NSBitmapImageRep)
        #expect(rep.pixelsWide == Int(MinimapModel.maxIconSide * 2))
        #expect(rep.pixelsHigh == Int(MinimapModel.maxIconSide * 2))
        // The icon fills the whole bitmap: a wrong scale would draw only a part of it.
        let last = rep.pixelsWide - 1
        for (x, y) in [(last / 2, last / 2), (0, 0), (last, 0), (0, last), (last, last)] {
            let c = try #require(rep.colorAt(x: x, y: y))
            #expect(c.alphaComponent > 0.9, "pixel \(x),\(y)")
            #expect(c.redComponent > 0.9, "pixel \(x),\(y)")
        }
    }

    @Test func theLiveLookupFindsARunningApp() throws {
        // The test runner is not an app, so use the Dock: it runs in every login session.
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
        let cache = AppIconCache(queue: nil)
        #expect(cache.icon(pid: dock.processIdentifier, bundleID: "com.apple.dock") != nil)
        #expect(cache.icon(pid: dock.processIdentifier, bundleID: "com.example.other") == nil,
                "the default lookup checks the bundle ID")
    }

    /// The cache that Striple uses makes icons in the background, off the main thread: the first ask returns
    /// at once. It also checks the bundle ID.
    @Test func theDefaultCacheOfTheOverlaysIsAsyncAndChecksTheApp() async throws {
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
        let cache = Overlays().appIcons
        let queue = try #require(cache.queue, "the cache has a queue")
        #expect(queue !== DispatchQueue.main)
        let onMain = await withCheckedContinuation { done in queue.async { done.resume(returning: Thread.isMainThread) } }
        #expect(!onMain, "the queue runs off the main thread")
        #expect(cache.icon(pid: dock.processIdentifier, bundleID: "com.apple.dock") == nil, "not made at once")
        #expect(cache.icon(pid: dock.processIdentifier, bundleID: "com.example.other") == nil, "not made at once")
        #expect(cache.pendingCount == 2)
        try await Self.waitUntilDone(cache)
        #expect(cache.icon(pid: dock.processIdentifier, bundleID: "com.apple.dock") != nil)
        #expect(cache.icon(pid: dock.processIdentifier, bundleID: "com.example.other") == nil, "another app has the pid")
        #expect(cache.lookups == 2)
    }

    /// The default queue of the cache runs the lookup off the main thread.
    @Test func theDefaultQueueRunsOffTheMainThread() async throws {
        let asked = Asked()
        let cache = AppIconCache(lookup: { pid, _ in asked.add(pid, main: Thread.isMainThread); return Self.image() })
        #expect(cache.icon(pid: 10, bundleID: "com.a") == nil)
        try await Self.waitUntilDone(cache)
        #expect(asked.onMain == [false])
        #expect(cache.icon(pid: 10, bundleID: "com.a") != nil)
    }

    /// The lookup runs after the request. If another app has the pid by then, it must not give its icon.
    @Test func theLiveLookupChecksTheBundleID() throws {
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
        #expect(AppIconCache.liveIcon(pid: dock.processIdentifier, bundleID: "com.apple.dock") != nil)
        #expect(AppIconCache.liveIcon(pid: dock.processIdentifier, bundleID: "com.example.other") == nil)
        #expect(AppIconCache.liveIcon(pid: dock.processIdentifier, bundleID: "") == nil)
    }

    /// A cold icon takes up to 90 ms, so the default cache makes it off the main thread: the lookup and the
    /// small bitmap. The first ask returns nil at once, asks made while the icon is made do not start a second
    /// lookup, and `onLoad` says when the icon is ready.
    @Test func theIconIsMadeInTheBackgroundAndThenReady() async throws {
        let asked = Asked(), drawn = Asked()
        let cache = AppIconCache(queue: DispatchQueue(label: "test.icons")) { pid, _ in
            asked.add(pid, main: Thread.isMainThread)
            // The handler runs when the cache draws the icon into its small bitmap.
            return NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
                drawn.add(pid, main: Thread.isMainThread)
                NSColor.red.setFill()
                rect.fill()
                return true
            }
        }
        let loaded = Loaded()
        cache.onLoad = { loaded.count += 1 }
        #expect(cache.icon(pid: 10, bundleID: "com.a") == nil, "not ready yet")
        #expect(cache.icon(pid: 10, bundleID: "com.a") == nil, "still not ready")
        #expect(cache.pendingCount == 1)
        try await Self.waitUntilDone(cache)
        #expect(loaded.count == 1)
        #expect(cache.icon(pid: 10, bundleID: "com.a") != nil, "ready after onLoad")
        #expect(cache.lookups == 1)
        #expect(asked.pids == [10])
        #expect(asked.onMain == [false], "the lookup ran off the main thread")
        #expect(drawn.onMain == [false], "the bitmap was drawn off the main thread")
        let icon = try #require(cache.icon(pid: 10, bundleID: "com.a"))
        let rep = try #require(icon.representations.first as? NSBitmapImageRep)
        #expect(icon.representations.count == 1)
        #expect(rep.pixelsWide == Int(MinimapModel.maxIconSide * 2), "the ready icon is the small bitmap")
    }

    @Test func anIconThatCannotBeMadeDoesNotAskForARedraw() async throws {
        let asked = Asked()
        let cache = AppIconCache(queue: DispatchQueue(label: "test.icons")) { pid, _ in asked.add(pid); return nil }
        let loaded = Loaded()
        cache.onLoad = { loaded.count += 1 }
        #expect(cache.icon(pid: 10, bundleID: "com.a") == nil)
        try await Self.waitUntilDone(cache)
        #expect(cache.icon(pid: 10, bundleID: "com.a") == nil)
        #expect(cache.pendingCount == 0, "a known missing icon starts no new load")
        #expect(cache.lookups == 1, "the missing icon is remembered")
        #expect(loaded.count == 0)
    }
}

/// The pids a lookup was asked for, from any thread.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var _pids: [Int32] = []
    private var _onMain: [Bool] = []
    func add(_ pid: Int32, main: Bool = false) { lock.withLock { _pids.append(pid); _onMain.append(main) } }
    var pids: [Int32] { lock.withLock { _pids } }
    var onMain: [Bool] { lock.withLock { _onMain } }
}

@MainActor private final class Loaded { var count = 0 }

/// The minimap view as Striple draws it, rendered into a bitmap. No panel is shown.
@MainActor
@Suite struct MinimapIconDrawTests {
    final class Shown { var value = true }

    static let size = CGSize(width: 520, height: 54)

    /// One block that covers `width` of the strip, for an app with pid 10.
    static func model(width: Double, highlighted: Bool = false) -> MinimapModel {
        model(block: CGRect(x: 0, y: 0, width: width, height: 1), highlighted: highlighted)
    }

    /// One block at `block` (fractions of the strip, y 0 at the top), for an app with pid 10.
    static func model(block: CGRect, highlighted: Bool = false) -> MinimapModel {
        MinimapModel(items: [.init(rect: block, highlighted: highlighted,
                                   pid: 10, bundleID: "com.a")],
                     viewport: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// The colour at the middle of the first block (x in view points from the left, y in the middle).
    static func render(_ view: MinimapView, blockWidth: Double) throws -> NSColor {
        try #require(renderInDisplaySpace(view, blockWidth: blockWidth).usingColorSpace(.deviceRGB))
    }

    /// The same colour, in the colour space of the bitmap that the view drew into. `dx` moves the sample
    /// that many points to the right of the middle of the block.
    static func renderInDisplaySpace(_ view: MinimapView, blockWidth: Double, dx: Double = 0) throws -> NSColor {
        try renderInDisplaySpace(view, block: CGRect(x: 0, y: 0, width: blockWidth, height: 1), dx: dx)
    }

    /// The colour `dx` points right of and `dy` points above the middle of `block`, in the bitmap colour space.
    static func renderInDisplaySpace(_ view: MinimapView, block: CGRect, dx: Double = 0, dy: Double = 0) throws -> NSColor {
        view.frame = CGRect(origin: .zero, size: size)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / size.width
        // The view insets the blocks by 10 x 8 points. Model y 0 and bitmap row 0 are both at the top.
        let x = 10 + block.midX * (size.width - 20) + dx
        let y = 8 + block.midY * (size.height - 16) - dy
        return try #require(rep.colorAt(x: Int(x * scale), y: Int(y * scale)))
    }

    /// The largest difference of one colour component.
    static func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
            abs(a.blueComponent - b.blueComponent))
    }

    @Test func aLargeBlockShowsTheIconOfItsApp() throws {
        let asked = Asked()
        // Like the live lookup, this one gives an icon only for the right app.
        let overlays = Overlays(appIcons: AppIconCache(queue: nil) { pid, bundleID in
            asked.add(pid)
            return bundleID == "com.a" ? AppIconCacheTests.image() : nil
        })
        let view = overlays.minimapEntry("D").view
        view.model = Self.model(width: 0.5)
        let c = try Self.render(view, blockWidth: 0.5)
        #expect(asked.pids == [10], "the view asked for the icon of the block's app")
        #expect(c.redComponent - c.greenComponent > 0.3, "the red icon is drawn on the grey block: \(c)")
    }

    /// The icon of the highlighted block is drawn opaque, so its pixel is the pure red of the test icon,
    /// whatever the accent colour of the block below is. The other icons are drawn at 0.7, so 30 % of the
    /// grey block shows through.
    @Test func theHighlightedIconIsOpaqueAndTheOthersAreFaded() throws {
        let showIcon = Shown()
        let overlays = Overlays(appIcons: AppIconCache(queue: nil) { _, _ in AppIconCacheTests.image() })
        let view = overlays.minimapEntry("D").view
        let live = view.icon
        view.icon = { pid, bundleID in showIcon.value ? live?(pid, bundleID) : nil }
        view.model = Self.model(width: 0.5, highlighted: true)
        let on = try Self.renderInDisplaySpace(view, blockWidth: 0.5)
        view.model = Self.model(width: 0.5, highlighted: false)
        let off = try Self.renderInDisplaySpace(view, blockWidth: 0.5)
        showIcon.value = false
        let grey = try Self.renderInDisplaySpace(view, blockWidth: 0.5)
        let red = try #require(NSColor.red.usingColorSpace(on.colorSpace))
        #expect(Self.distance(on, red) < 0.02, "the highlighted icon is opaque: \(on) against \(red)")
        let faded = NSColor(colorSpace: on.colorSpace, components: [
            0.7 * red.redComponent + 0.3 * grey.redComponent, 0.7 * red.greenComponent + 0.3 * grey.greenComponent,
            0.7 * red.blueComponent + 0.3 * grey.blueComponent, 1,
        ], count: 4)
        // A fade of 0.65 or 0.75 is about 0.02 away; the drawing is about 0.002 away.
        #expect(Self.distance(off, faded) < 0.01, "the other icon is drawn at 0.7: \(off) against \(faded), grey \(grey)")
    }

    /// The icon is `MinimapModel.iconSide` large, square and centred: 20 points in a large block, and 6 points
    /// less than a narrow or a short block. Outside the icon the block stays grey.
    @Test func theIconHasTheSizeOfIconSide() throws {
        let overlays = Overlays(appIcons: AppIconCache(queue: nil) { _, _ in AppIconCacheTests.image() })
        let view = overlays.minimapEntry("D").view
        func isRed(_ c: NSColor) throws -> Bool {
            let rgb = try #require(c.usingColorSpace(.deviceRGB))
            return rgb.redComponent - rgb.greenComponent > 0.3
        }
        // A 250 point block: a 20 point icon, so 7 points from the middle is icon and 14 points is grey.
        view.model = Self.model(width: 0.5)
        #expect(try isRed(Self.renderInDisplaySpace(view, blockWidth: 0.5, dx: 7)), "inside the 20 point icon")
        #expect(try !isRed(Self.renderInDisplaySpace(view, blockWidth: 0.5, dx: 14)), "outside the 20 point icon")
        #expect(try !isRed(Self.renderInDisplaySpace(view, blockWidth: 0.5, dx: -14)), "outside the 20 point icon")
        let large = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        for dy in [7.0, -7.0] {
            #expect(try isRed(Self.renderInDisplaySpace(view, block: large, dy: dy)), "inside the 20 point icon, dy \(dy)")
        }
        for dy in [14.0, -14.0] {
            #expect(try !isRed(Self.renderInDisplaySpace(view, block: large, dy: dy)), "outside the 20 point icon, dy \(dy)")
        }
        // A block of half the height (a window in a stacked column) is 17.5 points high: an 11 point icon.
        let short = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        view.model = Self.model(block: short)
        for d in [3.0, -3.0] {
            #expect(try isRed(Self.renderInDisplaySpace(view, block: short, dy: d)), "inside the 11 point icon, dy \(d)")
        }
        for d in [7.0, -7.0] {
            #expect(try !isRed(Self.renderInDisplaySpace(view, block: short, dy: d)), "outside the 11 point icon, dy \(d)")
        }
        #expect(try !isRed(Self.renderInDisplaySpace(view, block: short, dx: 7)), "the icon is square, not 11 x 20")
        // An 18 point block is 16.5 points after the inset: a 10 point icon.
        let narrow = 18.0 / (Self.size.width - 20)
        view.model = Self.model(width: narrow)
        #expect(try isRed(Self.renderInDisplaySpace(view, blockWidth: narrow, dx: 3)), "inside the 10 point icon")
        #expect(try !isRed(Self.renderInDisplaySpace(view, blockWidth: narrow, dx: 6.5)), "outside the 10 point icon")
    }

    @Test func aSmallBlockShowsNoIconAndStartsNoLookup() throws {
        let overlays = Overlays(appIcons: AppIconCache(queue: nil) { _, _ in AppIconCacheTests.image() })
        let view = overlays.minimapEntry("D").view
        // 0.02 of 500 points is 10 points: below the 16 points an icon needs.
        view.model = Self.model(width: 0.02)
        let c = try Self.render(view, blockWidth: 0.02)
        #expect(overlays.appIcons.lookups == 0)
        #expect(abs(c.redComponent - c.greenComponent) < 0.1, "grey, no icon: \(c)")
    }

    /// The icon is made in the background after the first draw. When it is ready, the minimap draws again
    /// by itself, so the icon shows also if the strip does not move any more.
    @Test func aReadyIconRedrawsTheMinimap() async throws {
        let overlays = Overlays(appIcons: AppIconCache(queue: DispatchQueue(label: "test.icons")) { _, _ in
            AppIconCacheTests.image()
        })
        let view = overlays.minimapEntry("D").view
        view.model = Self.model(width: 0.5)
        let before = try Self.render(view, blockWidth: 0.5)
        #expect(abs(before.redComponent - before.greenComponent) < 0.1, "no icon before it is ready: \(before)")
        let requests = view.displayRequests
        try await AppIconCacheTests.waitUntilDone(overlays.appIcons)
        #expect(view.displayRequests > requests, "the ready icon asked for a redraw: \(requests) -> \(view.displayRequests)")
        let after = try Self.render(view, blockWidth: 0.5)
        #expect(after.redComponent - after.greenComponent > 0.3, "the icon is drawn now: \(after)")
    }
}
