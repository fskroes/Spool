import SwiftUI
import StripleCore
import StripleEngine

/// Every bindable command with its key combinations. A command can have zero or more.
struct ShortcutsTab: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var engine: Engine
    @ObservedObject var recorder: ShortcutRecorder
    @ViewState private var query = ""
    @ViewState private var confirmReset = false
    /// Changes when the keyboard layout changes, so the labels are drawn again.
    @ViewState private var layoutGeneration = 0

    var body: some View {
        let conflicts = bindingConflicts(store.config.bindings)
        let defaults = DefaultBindings.make()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Spacer()
                Button("Reset All Shortcuts…") { confirmReset = true }
            }
            .padding(12)

            if !conflicts.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(conflicts.count == 1 ? "1 key combination is used by more than one action. Only one action runs."
                                              : "\(conflicts.count) key combinations are used by more than one action. Only one action runs.")
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            if !engine.refusedShortcuts.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("macOS or another app already uses \(engine.refusedShortcuts.map(KeyLabel.label).joined(separator: ", ")). Striple cannot use \(engine.refusedShortcuts.count == 1 ? "it" : "them"). Choose other keys, or free them in the other app.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            List {
                ForEach(rows, id: \.name) { command in
                    ShortcutRow(command: command,
                                combos: store.config.bindings[command] ?? [],
                                isDefault: (store.config.bindings[command] ?? []) == (defaults[command] ?? []),
                                conflicts: conflicts,
                                store: store,
                                recorder: recorder)
                }
            }
            .id(layoutGeneration)

            Note("Click + and press the new key combination. Use ⌃, ⌥ or ⌘ with the key, or a function key alone. Press Esc to cancel. The labels follow your keyboard layout.")
                .padding(12)
        }
        .confirmationDialog("Reset all shortcuts to the defaults?", isPresented: $confirmReset) {
            Button("Reset All Shortcuts", role: .destructive) {
                recorder.stop()
                store.resetBindings()
            }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: KeyLabel.layoutChanged)) { _ in
            layoutGeneration += 1
        }
        .onDisappear { recorder.stop() }
    }

    private var rows: [Command] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Command.bindable }
        return Command.bindable.filter { command in
            command.title.localizedCaseInsensitiveContains(q) || command.name.localizedCaseInsensitiveContains(q)
                || (store.config.bindings[command] ?? []).contains { KeyLabel.label($0).localizedCaseInsensitiveContains(q) }
        }
    }
}

private struct ShortcutRow: View {
    let command: Command
    let combos: [KeyCombo]
    let isDefault: Bool
    let conflicts: [KeyCombo: [Command]]
    @ObservedObject var store: ConfigStore
    @ObservedObject var recorder: ShortcutRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(command.title).frame(minWidth: 200, alignment: .leading)
                Spacer()
                ForEach(combos, id: \.self) { combo in
                    KeyChip(label: KeyLabel.label(combo), conflict: conflicts[combo] != nil) { remove(combo) }
                        .help(conflictText(combo) ?? "Click × to remove")
                }
                if recorder.command == command {
                    RecordingChip(modifiers: recorder.liveModifiers) { recorder.stop() }
                } else {
                    Button { recorder.start(command) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Record a new key combination")
                }
                Button { reset() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("Use the default shortcut")
                    .disabled(isDefault)
            }
            if recorder.command == command, let hint = recorder.hint {
                Note(hint, color: .orange)
            }
            ForEach(combos.filter { conflicts[$0] != nil }, id: \.self) { combo in
                if let text = conflictText(combo) { Note(text, color: .orange) }
            }
        }
        .padding(.vertical, 2)
    }

    private func conflictText(_ combo: KeyCombo) -> String? {
        guard let others = conflicts[combo]?.filter({ $0 != command }), !others.isEmpty else { return nil }
        return "\(KeyLabel.label(combo)) is also used by: " + others.map(\.title).joined(separator: ", ")
    }

    private func remove(_ combo: KeyCombo) {
        store.update { $0.bindings[command] = ($0.bindings[command] ?? []).filter { $0 != combo } }
    }

    private func reset() {
        store.update { $0.bindings[command] = DefaultBindings.make()[command] ?? [] }
    }
}

struct KeyChip: View {
    let label: String
    var conflict = false
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(.body, design: .rounded)).monospacedDigit()
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                    .buttonStyle(.borderless)
                    .help("Remove")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(conflict ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(conflict ? Color.orange : Color.secondary.opacity(0.35)))
    }
}

private struct RecordingChip: View {
    let modifiers: KeyModifiers
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(modifiers.isEmpty ? "Press keys…" : modifiers.symbols + "…")
            Button(action: onCancel) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .help("Cancel")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.2)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor))
    }
}
