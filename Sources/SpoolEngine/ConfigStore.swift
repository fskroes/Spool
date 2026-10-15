import Combine
import Foundation
import SpoolCore

/// The one source of truth for settings. The UI writes through `update`, the engine observes `$config`.
/// Changes apply at once and are saved to `config.json`. Edits made to the file in a text editor
/// are loaded automatically. A file with errors is not applied: `loadError` tells why. A save while the file
/// has errors keeps that file as `config.json.broken`, so the user's edits are never lost.
/// Each good load and save also writes `config.json.lastgood`. When `config.json` has errors or is missing at
/// launch, Spool starts with the settings in that copy, not with the factory settings.
@MainActor
public final class ConfigStore: ObservableObject {
    @Published public private(set) var config: Config
    /// A message for the user: the file has an error, a save failed, or a save kept the user's file as a copy.
    @Published public private(set) var loadError: String?
    /// True while something is wrong now: the file has an error, or the last save failed. False for the note
    /// that a save kept the user's file as `config.json.broken`.
    @Published public private(set) var hasProblem = false

    public let fileURL: URL
    private var lastData: Data?
    /// The folder: an editor that saves atomically replaces the file.
    private var watcher: DispatchSourceFileSystemObject?
    /// The file itself: an editor or a shell redirect that writes in place changes no folder entry.
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    /// While `config.json` is a link: the next check that the watched file is still the link target.
    private var linkRetryWork: DispatchWorkItem?
    /// The file `fileWatcher` watches (device and inode), nil when no file is watched.
    private var watchedFile: FileID?
    private struct FileID: Equatable {
        let device: dev_t
        let inode: ino_t
    }
    private let linkRetryDelay: TimeInterval
    /// The file on disk did not decode. The next save keeps a copy of it first.
    private var fileIsBroken = false
    /// Why the file did not decode. Kept for the message after a save.
    private var decodeError: String?
    private var lastGoodData: Data?
    private let arrowsTaken: Bool

    public var brokenCopyURL: URL { fileURL.appendingPathExtension("broken") }
    public var lastGoodURL: URL { fileURL.appendingPathExtension("lastgood") }
    /// True while `config.json` has errors. Automatic changes (not made by the user) must wait until it is fixed.
    public var fileHasError: Bool { fileIsBroken }
    /// Called each time a read of `config.json` fails to decode (the engine counts it in the metrics).
    public var onLoadError: (() -> Void)?

    public init(fileURL: URL = SpoolPaths.configFile, watch: Bool = true, arrowsTaken: Bool = Config.systemTakesArrows,
                linkRetryDelay: TimeInterval = 5) {
        self.fileURL = fileURL
        self.arrowsTaken = arrowsTaken
        self.linkRetryDelay = linkRetryDelay
        self.config = Config()
        load()
        let missing = lastData == nil && loadError == nil
        if fileIsBroken || missing { loadLastGood() }
        if missing { save() }
        if watch { startWatching() }
    }

    /// Changes the settings, saves them and notifies observers. No-op when nothing changed.
    /// `automatic`: a change the user did not make. It is not done while the file has an error, also when that
    /// error is found only by the read here.
    public func update(automatic: Bool = false, _ change: (inout Config) -> Void) {
        // An edit that the watchers did not report yet is read first, so this save does not replace it.
        loadIfChangedOnDisk()
        if automatic, fileIsBroken { return }
        var next = config
        change(&next)
        next.layout = next.layout.sanitized()
        guard next != config else { return }
        config = next
        save()
    }

    public func resetBindings() { update { $0.bindings = DefaultBindings.make() } }

    public func resetAll() {
        let keep = config.behavior.onboardingDone
        update {
            $0 = Config()
            $0.behavior.onboardingDone = keep
        }
    }

    /// Hides the note that a save kept the user's file as a copy. A real problem stays.
    public func dismissNote() {
        if !hasProblem { loadError = nil }
    }

    /// Reads the file again. Called by the file watcher; public for "Reload" buttons and tests.
    public func reload() { load() }

    private func loadIfChangedOnDisk() {
        if (try? Data(contentsOf: fileURL)) != lastData { load() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            lastData = nil
            if fileIsBroken {
                // The user removed the broken file. Write the settings in use, so the next launch has them too.
                fileIsBroken = false
                decodeError = nil
                loadError = nil
                hasProblem = false
                save()
            }
            return
        }
        guard data != lastData else { return }
        lastData = data
        do {
            var next = try Config.decode(data, arrowsTaken: arrowsTaken)
            next.layout = next.layout.sanitized()
            fileIsBroken = false
            decodeError = nil
            loadError = nil
            hasProblem = false
            if next != config { config = next }
            // Save a migrated file once, so the migration does not run again on a later edit.
            if let v = Config.fileVersion(data), v < next.version {
                save()
            } else {
                keepLastGood(data)
            }
        } catch {
            fileIsBroken = true
            hasProblem = true
            decodeError = Self.describe(error)
            loadError = "config.json has an error, so Spool keeps the last good settings: \(decodeError ?? "")"
            onLoadError?()
        }
    }

    /// At launch with a broken `config.json`: use the settings of the last good file, if there is one.
    private func loadLastGood() {
        guard let data = try? Data(contentsOf: lastGoodURL),
              var good = try? Config.decode(data, arrowsTaken: arrowsTaken) else { return }
        good.layout = good.layout.sanitized()
        lastGoodData = data
        config = good
    }

    private func keepLastGood(_ data: Data) {
        guard data != lastGoodData else { return }
        if (try? data.write(to: lastGoodURL, options: .atomic)) != nil { lastGoodData = data }
    }

    /// The file a save writes: the target of a symlink (a dotfiles repo), so the link stays a link. An atomic
    /// write to the link itself would replace it with a plain file.
    /// A relative link is read from the real folder of the link, as the kernel does: `..` in it goes up from
    /// that folder, also when the folder is reached through another link (`~/.config -> ~/dotfiles/config`).
    nonisolated static func writeTarget(of url: URL) -> URL {
        var out = url
        // The kernel follows up to 32 links (MAXSYMLINKS).
        for _ in 0..<32 {
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: out.path) else { return out }
            if dest.hasPrefix("/") {
                out = URL(fileURLWithPath: dest)
            } else {
                let dir = out.deletingLastPathComponent()
                let real = realpath(dir.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? dir.path
                out = URL(fileURLWithPath: real, isDirectory: true).appendingPathComponent(dest)
            }
        }
        return out
    }

    /// A save to a link whose target folder does not exist. Spool does not make the user's folders.
    struct LinkTargetFolderMissing: LocalizedError {
        let target: URL
        var errorDescription: String? {
            "it is a link to \(target.path), and the folder \(target.deletingLastPathComponent().path) does not exist"
        }
    }

    /// Links that point to each other in a loop. A write would replace one of them with a plain file.
    struct LinkLoop: LocalizedError {
        let at: URL
        var errorDescription: String? { "it is a link in a loop or a chain of more than 32 links, at \(at.path)" }
    }

    /// Makes the folder for `target` when it is Spool's own file, else checks that the user's folder exists.
    private func prepareFolder(of target: URL) throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil { throw LinkLoop(at: target) }
        let dir = target.deletingLastPathComponent()
        if target == fileURL {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } else {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                throw LinkTargetFolderMissing(target: target)
            }
        }
    }

    /// Writes the current settings when there is no file, so that an editor can open it. A link stays a link:
    /// the file is written at the link target. Returns false when it cannot write (the folder of the link
    /// target does not exist); the caller then shows the link in Finder.
    @discardableResult
    public func createFileIfMissing() -> Bool {
        let target = Self.writeTarget(of: fileURL)
        if FileManager.default.fileExists(atPath: target.path) { return true }
        do {
            try prepareFolder(of: target)
            try config.encoded().write(to: target, options: .atomic)
            // Load it now: this clears a save error, and the file watch starts on the new file.
            if watcher != nil { watchFile() }
            load()
            return true
        } catch {
            return false
        }
    }

    private func save() {
        do {
            let target = Self.writeTarget(of: fileURL)
            try prepareFolder(of: target)
            // An atomic write replaces a read-only file when its folder is writable. The user made it read-only.
            if FileManager.default.fileExists(atPath: target.path), !FileManager.default.isWritableFile(atPath: target.path) {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: target.path])
            }
            let data = try config.encoded()
            var kept: String?
            if fileIsBroken, let user = try? Data(contentsOf: fileURL) {
                // An atomic write: an old copy stays until the new one is complete.
                try user.write(to: brokenCopyURL, options: .atomic)
                kept = brokenCopyURL.lastPathComponent
            }
            try data.write(to: target, options: .atomic)
            // Only after the write: a failed save must not look like a change on disk to `loadIfChangedOnDisk`.
            lastData = data
            fileIsBroken = false
            hasProblem = false
            keepLastGood(data)
            loadError = kept.map { name in
                let why = decodeError.map { " (\($0))" } ?? ""
                return "config.json had an error\(why). Spool saved its settings and kept your file as \(name)."
            }
            decodeError = nil
        } catch {
            loadError = "Could not save config.json: \(error.localizedDescription)"
            hasProblem = true
        }
    }

    /// Watches the folder, not the file: an atomic save by an editor replaces the file.
    private func startWatching() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.watchFile()
                self?.scheduleReload()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
        watchFile()
    }

    /// Watches the file that is at `fileURL` now (the target, for a symlink). Called again after each change,
    /// because an atomic save or a delete puts a new file (a new inode) there, also in the folder of a symlink target.
    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
        linkRetryWork?.cancel()
        linkRetryWork = nil
        watchedFile = nil
        // A link target can come later (a dotfiles repo that is not cloned yet) or be moved away
        // (`mv ~/dotfiles ~/dotfiles.old`). No event in the folder of the link tells, so check every few seconds.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)) != nil { scheduleLinkCheck() }
        let fd = open(fileURL.path, O_EVTONLY)
        var info = stat()
        guard fd >= 0 else {
            // A file that cannot be opened (no read permission) is still known, so the check does not reload it
            // every few seconds. `chmod`, `chown` or an ACL change makes it readable with no event, also for a plain
            // file, so the check tries to open it again.
            if stat(fileURL.path, &info) == 0 {
                watchedFile = FileID(device: info.st_dev, inode: info.st_ino)
                if linkRetryWork == nil { scheduleLinkCheck() }
            }
            return
        }
        if fstat(fd, &info) == 0 { watchedFile = FileID(device: info.st_dev, inode: info.st_ino) }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }

    private func scheduleLinkCheck() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkLinkTarget() }
        }
        linkRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + linkRetryDelay, execute: work)
    }

    /// Reloads and watches again when the file at the link target is not the watched one, or when the known file
    /// that could not be opened can be opened now.
    private func checkLinkTarget() {
        var info = stat()
        let now = stat(fileURL.path, &info) == 0 ? FileID(device: info.st_dev, inode: info.st_ino) : nil
        if now != watchedFile { return scheduleReload() }
        if now != nil, fileWatcher == nil {
            let fd = open(fileURL.path, O_EVTONLY)
            if fd >= 0 {
                close(fd)
                return scheduleReload()
            }
        }
        scheduleLinkCheck()
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.watcher != nil { self.watchFile() }
                self.load()
            }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    static func describe(_ error: Error) -> String {
        let context: DecodingError.Context
        switch error as? DecodingError {
        case .dataCorrupted(let c)?:
            // A JSON syntax error has no path; the system message names the line.
            if c.codingPath.isEmpty, let u = c.underlyingError as NSError? { return u.localizedDescription }
            context = c
        case .typeMismatch(_, let c)?, .valueNotFound(_, let c)?: context = c
        case .keyNotFound(let key, let c)?: return "\(path(c.codingPath + [key])): the value is missing"
        default: return error.localizedDescription
        }
        return "\(path(context.codingPath)): \(context.debugDescription)"
    }

    /// For example `bindings.focus-left[0].mods`.
    private static func path(_ keys: [CodingKey]) -> String {
        keys.reduce("") { out, k in
            if let i = k.intValue { return out + "[\(i)]" }
            return out.isEmpty ? k.stringValue : out + "." + k.stringValue
        }
    }

    deinit {
        watcher?.cancel()
        fileWatcher?.cancel()
        linkRetryWork?.cancel()
    }
}
