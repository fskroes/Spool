import Carbon.HIToolbox
import Foundation
import StripleCore

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
        // Sorted so IDs are stable between runs, which keeps logs comparable.
        for (command, combos) in bindings.sorted(by: { $0.key.name < $1.key.name }) {
            for combo in combos {
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
