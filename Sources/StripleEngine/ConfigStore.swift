import Combine
import Foundation
import StripleCore

/// The one source of truth for settings. The UI writes through `update`, the engine observes `$config`.
/// Changes apply at once and are saved to `config.json`. Edits made to the file in a text editor
/// are loaded automatically. A file with errors is not applied: `loadError` tells why. A save while the file
/// has errors keeps that file as `config.json.broken`, so the user's edits are never lost.
@MainActor
public final class ConfigStore: ObservableObject {
    @Published public private(set) var config: Config
    @Published public private(set) var loadError: String?

    public let fileURL: URL
    private var lastData: Data?
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    /// The file on disk did not decode. The next save keeps a copy of it first.
    private var fileIsBroken = false

    public var brokenCopyURL: URL { fileURL.appendingPathExtension("broken") }

    public init(fileURL: URL = StriplePaths.configFile, watch: Bool = true) {
        self.fileURL = fileURL
        self.config = Config()
        load()
        if lastData == nil && loadError == nil { save() }
        if watch { startWatching() }
    }

    /// Changes the settings, saves them and notifies observers. No-op when nothing changed.
    public func update(_ change: (inout Config) -> Void) {
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

    /// Reads the file again. Called by the file watcher; public for "Reload" buttons and tests.
    public func reload() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            lastData = nil
            return
        }
        guard data != lastData else { return }
        lastData = data
        do {
            var next = try Config.decode(data)
            next.layout = next.layout.sanitized()
            fileIsBroken = false
            loadError = nil
            if next != config { config = next }
            // Save a migrated file once, so the migration does not run again on a later edit.
            if let v = Config.fileVersion(data), v < Config.currentVersion { save() }
        } catch {
            fileIsBroken = true
            loadError = "config.json has an error, so Striple keeps the last good settings: \(Self.describe(error))"
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try config.encoded()
            var kept: String?
            if fileIsBroken {
                try? FileManager.default.removeItem(at: brokenCopyURL)
                try FileManager.default.copyItem(at: fileURL, to: brokenCopyURL)
                kept = brokenCopyURL.lastPathComponent
            }
            lastData = data
            try data.write(to: fileURL, options: .atomic)
            fileIsBroken = false
            loadError = kept.map { "config.json had an error. Striple saved its settings and kept your file as \($0)." }
        } catch {
            loadError = "Could not save config.json: \(error.localizedDescription)"
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
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
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

    deinit { watcher?.cancel() }
}
