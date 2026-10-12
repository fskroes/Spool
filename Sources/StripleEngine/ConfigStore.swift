import Combine
import Foundation
import StripleCore

/// The one source of truth for settings. The UI writes through `update`, the engine observes `$config`.
/// Changes apply at once and are saved to `config.json`. Edits made to the file in a text editor
/// are loaded automatically. A file with errors is not applied: `loadError` tells why.
@MainActor
public final class ConfigStore: ObservableObject {
    @Published public private(set) var config: Config
    @Published public private(set) var loadError: String?

    public let fileURL: URL
    private var lastData: Data?
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?

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
            loadError = nil
            if next != config { config = next }
        } catch {
            loadError = "config.json has an error, so Striple keeps the last good settings: \(Self.describe(error))"
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try config.encoded()
            lastData = data
            try data.write(to: fileURL, options: .atomic)
            loadError = nil
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

    private static func describe(_ error: Error) -> String {
        if case let DecodingError.dataCorrupted(context) = error {
            return (context.underlyingError as NSError?)?.localizedDescription ?? context.debugDescription
        }
        return error.localizedDescription
    }

    deinit { watcher?.cancel() }
}
