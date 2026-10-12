import Combine
import Foundation
import StripleCore

/// The one source of truth for settings. The UI writes through `update`, the engine observes `$config`.
/// Changes apply at once and are saved to `config.json`. Edits made to the file in a text editor
/// are loaded automatically. A file with errors is not applied: `loadError` tells why. A save while the file
/// has errors keeps that file as `config.json.broken`, so the user's edits are never lost.
/// Each good load and save also writes `config.json.lastgood`. When `config.json` has errors or is missing at
/// launch, Striple starts with the settings in that copy, not with the factory settings.
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

    public init(fileURL: URL = StriplePaths.configFile, watch: Bool = true, arrowsTaken: Bool = Config.systemTakesArrows) {
        self.fileURL = fileURL
        self.arrowsTaken = arrowsTaken
        self.config = Config()
        load()
        let missing = lastData == nil && loadError == nil
        if fileIsBroken || missing { loadLastGood() }
        if missing { save() }
        if watch { startWatching() }
    }

    /// Changes the settings, saves them and notifies observers. No-op when nothing changed.
    public func update(_ change: (inout Config) -> Void) {
        // An edit that the watchers did not report yet is read first, so this save does not replace it.
        loadIfChangedOnDisk()
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
            loadError = "config.json has an error, so Striple keeps the last good settings: \(decodeError ?? "")"
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

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try config.encoded()
            var kept: String?
            if fileIsBroken, let user = try? Data(contentsOf: fileURL) {
                // An atomic write: an old copy stays until the new one is complete.
                try user.write(to: brokenCopyURL, options: .atomic)
                kept = brokenCopyURL.lastPathComponent
            }
            lastData = data
            try data.write(to: fileURL, options: .atomic)
            fileIsBroken = false
            hasProblem = false
            keepLastGood(data)
            loadError = kept.map { name in
                let why = decodeError.map { " (\($0))" } ?? ""
                return "config.json had an error\(why). Striple saved its settings and kept your file as \(name)."
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

    /// Watches the file that is at `fileURL` now. Called again after each folder change, because an atomic save
    /// or a delete puts a new file (a new inode) there.
    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.load() }
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
    }
}
