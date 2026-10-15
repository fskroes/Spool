import Carbon.HIToolbox
import Foundation
import SpoolCore

/// Global shortcuts through Carbon hot keys. They need no extra permission and are delivered on the main thread.
@MainActor
final class Hotkeys {
    private var refs: [EventHotKeyRef] = []
    private var commands: [UInt32: Command] = [:]
    private var handler: EventHandlerRef?
    private let onCommand: (Command) -> Void
    private(set) var failed: [KeyCombo] = []

    init(onCommand: @escaping (Command) -> Void) { self.onCommand = onCommand }

    static func carbonModifiers(_ m: KeyModifiers) -> UInt32 {
        var out: UInt32 = 0
        if m.contains(.control) { out |= UInt32(controlKey) }
        if m.contains(.option) { out |= UInt32(optionKey) }
        if m.contains(.shift) { out |= UInt32(shiftKey) }
        if m.contains(.command) { out |= UInt32(cmdKey) }
        return out
    }

    /// Replaces all registered shortcuts. Returns the combos macOS refused (taken by another app or the system).
    @discardableResult
    func register(_ bindings: [Command: [KeyCombo]]) -> [KeyCombo] {
        unregisterAll()
        installHandler()
        var next: UInt32 = 1
        failed = []
        // A combo bound to two Spool actions is registered once. That is a conflict inside Spool
        // (the Shortcuts page shows it), not a refusal by macOS.
        var seen = Set<KeyCombo>()
        // Sorted so IDs are stable between runs, which keeps logs comparable.
        for (command, combos) in bindings.sorted(by: { $0.key.name < $1.key.name }) {
            for combo in combos where seen.insert(combo).inserted {
                var ref: EventHotKeyRef?
                let id = EventHotKeyID(signature: OSType(0x5354_5250), id: next) // "STRP"
                let status = RegisterEventHotKey(UInt32(combo.keyCode), Self.carbonModifiers(combo.modifiers), id,
                                                 GetApplicationEventTarget(), 0, &ref)
                if status == noErr, let ref {
                    refs.append(ref)
                    commands[next] = command
                } else {
                    failed.append(combo)
                }
                next += 1
            }
        }
        return failed
    }

    func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        commands.removeAll()
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            guard let event, let user else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(user).takeUnretainedValue()
            MainActor.assumeIsolated { hotkeys.fire(id.id) }
            return noErr
        }, 1, &spec, me, &handler)
    }

    private func fire(_ id: UInt32) {
        guard let c = commands[id] else { return }
        onCommand(c)
    }

    func shutdown() {
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

extension Hotkeys {
    /// The enabled macOS shortcuts (Spotlight, Spaces, screenshots, input sources...). Carbon accepts a hotkey
    /// that macOS also uses without an error, so Spool checks this list itself.
    nonisolated static func systemShortcuts() -> Set<KeyCombo> {
        var ref: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&ref) == noErr, let list = ref?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return systemShortcuts(from: list)
    }

    nonisolated static func systemShortcuts(from list: [[String: Any]]) -> Set<KeyCombo> {
        var out = Set<KeyCombo>()
        for item in list {
            guard (item[kHISymbolicHotKeyEnabled as String] as? Bool) ?? false,
                  let code = (item[kHISymbolicHotKeyCode as String] as? NSNumber)?.intValue, code >= 0, code < 0xFFFF,
                  let mods = (item[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { continue }
            // Arrows and other function keys always carry the fn flag, so there it says nothing.
            // On any other key (fn ⌃ F for window tiling) the user must press Fn, which Spool never binds.
            if mods & fnMask != 0, !keysWithImplicitFn.contains(code) { continue }
            out.insert(KeyCombo(UInt16(code), keyModifiers(carbon: mods)))
        }
        return out
    }

    /// `kEventKeyModifierFnMask`.
    nonisolated static let fnMask: UInt32 = 1 << 17

    nonisolated static let keysWithImplicitFn: Set<Int> = [
        kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow,
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_Help,
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    nonisolated static func keyModifiers(carbon m: UInt32) -> KeyModifiers {
        var out: KeyModifiers = []
        if m & UInt32(controlKey) != 0 { out.insert(.control) }
        if m & UInt32(optionKey) != 0 { out.insert(.option) }
        if m & UInt32(shiftKey) != 0 { out.insert(.shift) }
        if m & UInt32(cmdKey) != 0 { out.insert(.command) }
        return out
    }
}

/// The key combinations macOS itself uses right now. For the shortcut recorder.
public enum SystemShortcuts {
    public static func current() -> Set<KeyCombo> { Hotkeys.systemShortcuts() }
}
