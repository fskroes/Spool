import AppKit
import Combine
import SwiftUI
import SpoolCore
import SpoolEngine

/// Shared state and actions for the menu and the windows.
@MainActor
final class AppModel: ObservableObject {
    let store: ConfigStore
    let engine: Engine
    let recorder: ShortcutRecorder
    let license: LicenseGate
    /// Which place groups are open on the Shortcuts page. Kept here so a group you closed stays closed when you
    /// change page or close Settings.
    let placeFolds = PlaceFoldState()
    @Published var tab: SettingsTab = .general {
        didSet { settingsWindow.title = tab.title }
    }
    private var dock = DockPresence()

    private lazy var settingsWindow: HostedWindow = {
        let window = HostedWindow(title: tab.title, autosaveName: "SpoolSettings", resizable: true, content: .split(
            sidebar: { [unowned self] in AnyView(SettingsSidebar().environmentObject(self)) },
            detail: { [unowned self] in AnyView(SettingsDetail(store: store, engine: engine).environmentObject(self)) }))
        window.onShow = { [weak self] in self?.windowOpened("settings") }
        window.onClose = { [weak self] in
            self?.recorder.stop()
            // The colour panel belongs to the border colour in Settings. It must not stay without a Dock icon.
            if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
            self?.windowClosed("settings")
        }
        return window
    }()

    private lazy var guideWindow: HostedWindow = {
        let window = HostedWindow(title: "Welcome to Spool", autosaveName: "SpoolGuide", resizable: false) { [unowned self] in
            AnyView(OnboardingView(store: store, engine: engine).environmentObject(self))
        }
        window.onShow = { [weak self] in self?.windowOpened("guide") }
        window.onClose = { [weak self] in self?.windowClosed("guide") }
        return window
    }()

    private lazy var licenseWindow: HostedWindow = {
        let window = HostedWindow(title: "Activate Spool", autosaveName: "SpoolLicense", resizable: false) { [unowned self] in
            AnyView(LicenseView(gate: license).environmentObject(self))
        }
        window.onShow = { [weak self] in self?.windowOpened("license") }
        window.onClose = { [weak self] in self?.windowClosed("license") }
        return window
    }()

    init(store: ConfigStore, engine: Engine, license: LicenseGate? = nil) {
        self.store = store
        self.engine = engine
        let license = license ?? LicenseGate()
        self.license = license
        self.recorder = ShortcutRecorder(engine: engine, store: store)
        engine.licenseCheck = { [unowned license] in license.checkBeforeStart() }
    }

    func openSettings(_ tab: SettingsTab? = nil) {
        if let tab { self.tab = tab }
        if !settingsWindow.isOpen { LoginItem.syncConfig(store) }
        settingsWindow.show()
    }

    func openGuide() { guideWindow.show() }

    func closeGuide() { guideWindow.close() }

    func openLicenseWindow() { licenseWindow.show() }

    /// Checks and stores a key from the window, a URL or the CLI. On success: closes the window, starts the
    /// engine, and shows the guide when the first run is not done. On failure `license.error` holds the text.
    @discardableResult
    func activateLicense(_ text: String) -> LicenseKeeper.Outcome {
        let outcome = license.activate(text)
        switch outcome {
        case .activated:
            licenseWindow.close()
            // Only the start the license refused goes on now (an unlicensed copy always tries at launch).
            // A new key for a licensed copy does not start an engine that the user stopped.
            if engine.status == .unlicensed { engine.start() }
            openGuideIfNeeded()
        case .invalid, .saveFailed, .notRequired:
            break
        }
        return outcome
    }

    /// `spool://license?key=<key>`. A valid key also replaces the key of a licensed copy, like
    /// `spool license <key>` (a buyer with a new key clicks the link in the email). A URL without a key opens
    /// the window, or Settings when there is a license.
    func activateLicense(fromURL key: String) {
        switch LicenseLaunch.urlAction(key: key, status: license.status) {
        case .ignore: return
        case .openLicenseWindow: openLicenseWindow()
        case .openSettings: openSettings()
        case .activate(let key):
            // A key that fails opens the window, which shows the error.
            switch activateLicense(key) {
            case .invalid, .saveFailed: openLicenseWindow()
            case .activated, .notRequired: break
            }
        }
    }

    /// With a broken config.json the guide would save over the user's file when it closes.
    func openGuideIfNeeded() {
        if !store.config.behavior.onboardingDone, !store.fileHasError { openGuide() }
    }

    /// A click on the Dock icon, or Spool opened again: the open windows come to the front, the guide above
    /// Settings and an update window above all. A minimized window comes back from the Dock.
    /// With no window open, Settings opens.
    func reopen() {
        guard dock.hasOpenWindow else { return license.status == .unlicensed ? openLicenseWindow() : openSettings() }
        App.activate()
        // Also About and the Sparkle windows, which Spool does not own as a HostedWindow.
        for window in NSApp.windows where window.isMiniaturized { window.deminiaturize(nil) }
        if settingsWindow.isOpen { settingsWindow.show() }
        if guideWindow.isOpen { guideWindow.show() }
        if licenseWindow.isOpen { licenseWindow.show() }
        if dock.open.contains(UpdateWindows.window) { Updater.shared.showPendingUpdate() }
    }

    private var aboutObserver: NSObjectProtocol?

    /// The standard About panel. Spool counts it as an open window, so the Dock icon and the menu bar stay
    /// while it is on screen.
    func showAbout() {
        let visible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        // The policy changes before the app activates, as in HostedWindow.show, so the menu bar comes with it.
        windowOpened("about")
        App.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
        guard aboutObserver == nil else { return }
        guard let panel = Self.newWindow(NSApp.windows, isVisible: \.isVisible, before: visible) else {
            return windowClosed("about")
        }
        aboutObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.aboutObserver { NotificationCenter.default.removeObserver(observer) }
                self.aboutObserver = nil
                self.windowClosed("about")
            }
        }
    }

    /// The first window in `windows` that is visible and was not visible `before`: the panel that just opened.
    nonisolated static func newWindow<W: AnyObject>(_ windows: [W], isVisible: (W) -> Bool,
                                                    before: Set<ObjectIdentifier>) -> W? {
        windows.first { isVisible($0) && !before.contains(ObjectIdentifier($0)) }
    }

    func windowOpened(_ id: String) {
        if let policy = dock.opened(id) { NSApp.setActivationPolicy(policy) }
    }

    func windowClosed(_ id: String) {
        if let policy = dock.closed(id) { NSApp.setActivationPolicy(policy) }
        // Also when Spool is in the back (a background window closed from its title bar): Sparkle shows the
        // update of a regular app only on activation, so without this the Dock icon stays with no window.
        if dock.onlyUpdateLeft(after: id) { Updater.shared.showPendingUpdate() }
    }

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
        let log = SpoolPaths.logFile
        do {
            try FileManager.default.createDirectory(at: SpoolPaths.logDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("Spool: cannot create the log folder: %@", error.localizedDescription)
        }
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            NSWorkspace.shared.open(SpoolPaths.logDirectory)
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
        case .running: return "Spool is running"
        case .stopped: return "Spool is stopped"
        case .noPermission: return "Accessibility permission needed"
        case .unlicensed: return "Spool needs a license key"
        }
    }
}
