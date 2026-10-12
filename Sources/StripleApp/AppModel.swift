import AppKit
import Combine
import SwiftUI
import StripleCore
import StripleEngine

/// Shared state and actions for the menu and the windows.
@MainActor
final class AppModel: ObservableObject {
    let store: ConfigStore
    let engine: Engine
    let recorder: ShortcutRecorder
    @Published var tab: SettingsTab = .general

    private lazy var settingsWindow: HostedWindow = {
        let window = HostedWindow(title: "Striple", autosaveName: "StripleSettings", resizable: true) { [unowned self] in
            AnyView(SettingsView(store: store, engine: engine).environmentObject(self))
        }
        window.onClose = { [weak self] in self?.recorder.stop() }
        return window
    }()

    private lazy var guideWindow: HostedWindow = {
        HostedWindow(title: "Welcome to Striple", autosaveName: "StripleGuide", resizable: false) { [unowned self] in
            AnyView(OnboardingView(store: store, engine: engine).environmentObject(self))
        }
    }()

    init(store: ConfigStore, engine: Engine) {
        self.store = store
        self.engine = engine
        self.recorder = ShortcutRecorder(engine: engine, store: store)
    }

    func openSettings(_ tab: SettingsTab? = nil) {
        if let tab { self.tab = tab }
        if !settingsWindow.isVisible { LoginItem.syncConfig(store) }
        settingsWindow.show()
    }

    func openGuide() { guideWindow.show() }

    func closeGuide() { guideWindow.close() }

    /// Starts tiling when auto-start is on and the engine is not running yet.
    func autoStartIfNeeded() {
        if store.config.behavior.autoStart && engine.status != .running { engine.start() }
    }

    /// Opens config.json in the default editor for JSON, or in TextEdit when there is none.
    func openConfigFile() {
        let url = store.fileURL
        // A link to a folder that does not exist: show the link, never replace it with a plain file.
        guard store.createFileIfMissing() else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func revealLog() {
        let log = StriplePaths.logFile
        do {
            try FileManager.default.createDirectory(at: StriplePaths.logDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("Striple: cannot create the log folder: %@", error.localizedDescription)
        }
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            NSWorkspace.shared.open(StriplePaths.logDirectory)
        }
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

extension LoginItem {
    /// Makes the setting show the real state. The user can change it in System Settings too.
    @MainActor
    static func syncConfig(_ store: ConfigStore) {
        // A save while config.json has errors replaces the user's file. Only the user may cause that.
        guard isAvailable, !store.fileHasError else { return }
        let on = showsOn(state)
        store.update(automatic: true) { $0.behavior.launchAtLogin = on }
    }
}

extension ConfigStore {
    /// A binding that reads `config` and writes through `update`, so every change applies at once.
    func binding<Value>(_ keyPath: WritableKeyPath<Config, Value>) -> Binding<Value> {
        Binding(get: { self.config[keyPath: keyPath] },
                set: { value in self.update { $0[keyPath: keyPath] = value } })
    }
}

extension Engine.Status {
    var summary: String {
        switch self {
        case .running: return "Striple is running"
        case .stopped: return "Striple is stopped"
        case .noPermission: return "Accessibility permission needed"
        }
    }
}
