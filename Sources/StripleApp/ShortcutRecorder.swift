import AppKit
import Combine
import StripleCore
import StripleEngine

/// Pure rules for the shortcut recorder.
enum RecorderRules {
    enum Outcome: Equatable {
        case accept(KeyCombo)
        case cancel
        /// The key needs at least one of ⌃⌥⌘, so typing stays free.
        case needsModifier
        /// ⌘ or ⌘⇧ with a key belongs to the apps (⌘W, ⌘C, ⌘Tab...). A global hotkey would take it from every app.
        case appShortcut
        /// macOS already uses the combination (System Settings > Keyboard > Keyboard Shortcuts).
        case systemShortcut(KeyCombo)
    }

    static func evaluate(keyCode: UInt16, modifiers: KeyModifiers, systemShortcuts: Set<KeyCombo> = []) -> Outcome {
        if keyCode == KeyCode.escape { return .cancel }
        if keyCode == KeyCode.delete && modifiers.isEmpty { return .cancel }
        let function = isFunctionKey(keyCode)
        guard function || !modifiers.isDisjoint(with: [.control, .option, .command]) else { return .needsModifier }
        let combo = KeyCombo(keyCode, modifiers)
        if !function && modifiers.contains(.command) && modifiers.isDisjoint(with: [.control, .option]) { return .appShortcut }
        if systemShortcuts.contains(combo) { return .systemShortcut(combo) }
        return .accept(combo)
    }

    static func isFunctionKey(_ code: UInt16) -> Bool { FunctionKeys.codes.contains(code) }
}

extension KeyModifiers {
    /// Maps AppKit modifier flags. Caps Lock, Fn and the side of the key are ignored.
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
    }
}

/// Records one key combination for one command. Global shortcuts are paused while it records,
/// so pressing an existing shortcut records it instead of running it.
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var command: Command?
    /// The modifiers held down right now, shown while recording.
    @Published private(set) var liveModifiers: KeyModifiers = []
    @Published private(set) var hint: String?

    private let engine: Engine
    private let store: ConfigStore
    private var monitor: Any?
    private var resignToken: NSObjectProtocol?
    /// Read when recording starts, so a change in System Settings counts.
    private var systemShortcuts: Set<KeyCombo> = []

    init(engine: Engine, store: ConfigStore) {
        self.engine = engine
        self.store = store
        // While recording, the global shortcuts are off. When the user goes to another app, they must come back.
        resignToken = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func start(_ command: Command) {
        stop()
        self.command = command
        hint = nil
        systemShortcuts = SystemShortcuts.current()
        engine.hotkeysSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    /// Ends recording without a change. Also called when the settings window closes.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if command != nil { engine.hotkeysSuspended = false }
        command = nil
        liveModifiers = []
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let mods = KeyModifiers(event.modifierFlags)
        if event.type == .flagsChanged {
            liveModifiers = mods
            return nil
        }
        guard let command else { return event }
        switch RecorderRules.evaluate(keyCode: event.keyCode, modifiers: mods, systemShortcuts: systemShortcuts) {
        case .cancel:
            stop()
        case .needsModifier:
            hint = "Hold ⌃, ⌥ or ⌘ with the key. F1 to F20 work alone."
            NSSound.beep()
        case .appShortcut:
            hint = "Apps use ⌘ with a key (for example ⌘W closes a window). Add ⌃ or ⌥."
            NSSound.beep()
        case .systemShortcut(let combo):
            hint = "macOS uses \(KeyLabel.label(combo)). Choose other keys, or turn it off in System Settings > Keyboard > Keyboard Shortcuts."
            NSSound.beep()
        case .accept(let combo):
            store.update { config in
                var list = config.bindings[command] ?? []
                if !list.contains(combo) { list.append(combo) }
                config.bindings[command] = list
            }
            stop()
        }
        return nil
    }
}
