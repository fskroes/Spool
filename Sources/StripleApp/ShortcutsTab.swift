import SwiftUI
import StripleCore
import StripleEngine

/// Every bindable command with its key combinations, in groups. A command can have zero or more.
struct ShortcutsTab: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var engine: Engine
    @ObservedObject var recorder: ShortcutRecorder
    @ObservedObject var folds: PlaceFoldState
    @ViewState private var query = ""
    @ViewState private var confirmReset = false
    /// Changes when the keyboard layout changes, so the labels are drawn again.
    @ViewState private var layoutGeneration = 0

    var body: some View {
        let conflicts = bindingConflicts(store.config.bindings)
        let defaults = DefaultBindings.make()
        let opens = placesToOpen(conflicts)
        let forced = placesThatStayOpen(conflicts)
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
                ForEach(ShortcutGroup.allCases, id: \.self) { group in
                    let commands = group.commands
                    let single = commands.single.filter(matches)
                    let places = commands.places.filter(matches)
                    if !single.isEmpty || !places.isEmpty {
                        Section(group.title) {
                            ForEach(single, id: \.name) { row($0, conflicts: conflicts, defaults: defaults) }
                            if let placesTitle = group.placesTitle, !places.isEmpty {
                                if isSearching {
                                    ForEach(places, id: \.name) { row($0, conflicts: conflicts, defaults: defaults) }
                                } else {
                                    let isOpen = expandedBinding(group, forced: forced)
                                    DisclosureGroup(isExpanded: isOpen) {
                                        ForEach(places, id: \.name) { row($0, conflicts: conflicts, defaults: defaults) }
                                    } label: {
                                        PlacesLabel(title: placesTitle,
                                                    summary: PlaceSummary.text(places.map { store.config.bindings[$0] ?? [] },
                                                                               label: KeyLabel.label),
                                                    conflict: hasConflict(places, conflicts),
                                                    toggle: { withAnimation { isOpen.wrappedValue.toggle() } })
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .id(layoutGeneration)
            .onAppear { open(opens) }
            .onChange(of: opens) { open($0) }

            Note("Click + and press the new key combination. \(RecorderRules.ruleText) Press Esc to cancel. The labels follow your keyboard layout.")
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

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func matches(_ command: Command) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return command.title.localizedCaseInsensitiveContains(q) || command.name.localizedCaseInsensitiveContains(q)
            || (store.config.bindings[command] ?? []).contains { KeyLabel.label($0).localizedCaseInsensitiveContains(q) }
    }

    private func row(_ command: Command, conflicts: [KeyCombo: [Command]], defaults: [Command: [KeyCombo]]) -> some View {
        ShortcutRow(command: command,
                    combos: store.config.bindings[command] ?? [],
                    isDefault: (store.config.bindings[command] ?? []) == (defaults[command] ?? []),
                    conflicts: conflicts,
                    store: store,
                    recorder: recorder)
    }

    private func hasConflict(_ commands: [Command], _ conflicts: [KeyCombo: [Command]]) -> Bool {
        commands.contains {
            PlaceFolding.hasProblem($0, bindings: store.config.bindings, conflicts: conflicts,
                                    refused: Set(engine.refusedShortcuts))
        }
    }

    private func placesToOpen(_ conflicts: [KeyCombo: [Command]]) -> Set<Command> {
        PlaceFolding.placesToOpen(bindings: store.config.bindings, conflicts: conflicts,
                                  refused: Set(engine.refusedShortcuts), recording: recorder.command)
    }

    private func placesThatStayOpen(_ conflicts: [KeyCombo: [Command]]) -> Set<ShortcutGroup> {
        PlaceFolding.groupsThatStayOpen(bindings: store.config.bindings, conflicts: conflicts, recording: recorder.command)
    }

    private func open(_ opens: Set<Command>) {
        folds.expanded = PlaceFolding.opened(opens, before: folds.openedBefore, expanded: folds.expanded)
        folds.openedBefore = opens
    }

    private func expandedBinding(_ group: ShortcutGroup, forced: Set<ShortcutGroup>) -> Binding<Bool> {
        Binding(get: { PlaceFolding.isOpen(group, expanded: folds.expanded, forced: forced) },
                set: { folds.expanded = PlaceFolding.toggled(group, open: $0, expanded: folds.expanded, forced: forced) })
    }
}

/// The open place groups of the Shortcuts page, for the whole run of Striple (see `AppModel.placeFolds`).
@MainActor
final class PlaceFoldState: ObservableObject {
    /// The groups whose place rows are open.
    @Published var expanded: Set<ShortcutGroup> = []
    /// The place rows that needed you the last time (`PlaceFolding.placesToOpen`), so only a new one opens a group.
    var openedBefore: Set<Command> = []
}

/// The nine place rows of a group are folded. A group opens by itself when one of its place rows records, has a
/// conflict, or has a combo that macOS or another app owns, so the row that needs you is not hidden. It then stays
/// open until you close it, also after the conflict is solved, so the row you changed does not go away under the
/// pointer. While a row records or has a conflict, its group cannot close: a hidden recorder would take the next
/// key press. A combo that macOS or another app owns only opens the group: it can stay that way for good, and the
/// group must still fold. A group you closed opens by itself again only for a row that needs you and did not before.
enum PlaceFolding {
    /// The place rows that record, or have a conflict or a combo that macOS or another app owns.
    static func placesToOpen(bindings: [Command: [KeyCombo]], conflicts: [KeyCombo: [Command]],
                             refused: Set<KeyCombo> = [], recording: Command?) -> Set<Command> {
        Set(ShortcutGroup.allCases.flatMap(\.commands.places).filter { command in
            command == recording || hasProblem(command, bindings: bindings, conflicts: conflicts, refused: refused)
        })
    }

    static func groupsToOpen(bindings: [Command: [KeyCombo]], conflicts: [KeyCombo: [Command]],
                             refused: Set<KeyCombo> = [], recording: Command?) -> Set<ShortcutGroup> {
        groups(of: placesToOpen(bindings: bindings, conflicts: conflicts, refused: refused, recording: recording))
    }

    /// The groups that hold the place rows `places`.
    static func groups(of places: Set<Command>) -> Set<ShortcutGroup> {
        Set(ShortcutGroup.allCases.filter { group in group.commands.places.contains(where: places.contains) })
    }

    /// The groups that cannot close: a place row records or has a conflict. Not for a refused combo (see above).
    static func groupsThatStayOpen(bindings: [Command: [KeyCombo]], conflicts: [KeyCombo: [Command]],
                                   recording: Command?) -> Set<ShortcutGroup> {
        groupsToOpen(bindings: bindings, conflicts: conflicts, refused: [], recording: recording)
    }

    /// One of the combos of `command` is used by another action, or macOS or another app owns it.
    static func hasProblem(_ command: Command, bindings: [Command: [KeyCombo]], conflicts: [KeyCombo: [Command]],
                           refused: Set<KeyCombo>) -> Bool {
        (bindings[command] ?? []).contains { conflicts[$0] != nil || refused.contains($0) }
    }

    /// The open groups after `placesToOpen` changed from `before` to `opens`. Only a place row that is new in `opens`
    /// opens its group, so a group you closed by hand stays closed when another row starts or stops recording, or
    /// when the list is drawn again. A new problem in a group that already had one still opens it.
    static func opened(_ opens: Set<Command>, before: Set<Command>,
                       expanded: Set<ShortcutGroup>) -> Set<ShortcutGroup> {
        expanded.union(groups(of: opens.subtracting(before)))
    }

    /// A group is open when you opened it, or when it must be open (`forced`, from `groupsThatStayOpen`).
    static func isOpen(_ group: ShortcutGroup, expanded: Set<ShortcutGroup>, forced: Set<ShortcutGroup>) -> Bool {
        expanded.contains(group) || forced.contains(group)
    }

    /// The open groups after a click on the row or the disclosure triangle of `group`. A group that must be open
    /// stays open.
    static func toggled(_ group: ShortcutGroup, open: Bool, expanded: Set<ShortcutGroup>,
                        forced: Set<ShortcutGroup>) -> Set<ShortcutGroup> {
        var result = expanded
        if open {
            result.insert(group)
        } else if !forced.contains(group) {
            result.remove(group)
        }
        return result
    }
}

/// The summary next to a folded run of nine place shortcuts.
enum PlaceSummary {
    /// `combos[i]` are the combos of place `i + 1`. "⌃⌥1 to ⌃⌥9" when every place has one combo with the same
    /// modifiers and its own digit; else how many places have a shortcut.
    static func text(_ combos: [[KeyCombo]], label: (KeyCombo) -> String) -> String {
        let set = combos.filter { !$0.isEmpty }.count
        if set == 0 { return "No shortcuts" }
        let firsts = combos.compactMap { $0.count == 1 ? $0[0] : nil }
        if firsts.count == combos.count, let first = firsts.first, let last = firsts.last,
           firsts.allSatisfy({ $0.modifiers == first.modifiers }),
           firsts.enumerated().allSatisfy({ KeyCode.usName($0.element.keyCode) == "\($0.offset + 1)" }) {
            return "\(label(first)) to \(label(last))"
        }
        return "\(set) of \(combos.count) set"
    }
}

private struct PlacesLabel: View {
    let title: String
    let summary: String
    let conflict: Bool
    /// A click anywhere on the row opens or closes it, not only on the triangle.
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer()
            if conflict {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    .help("A key combination in this group is used by more than one action, or macOS or another app owns it")
            }
            Text(summary).foregroundColor(.secondary).monospacedDigit()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
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
