import SwiftUI
import SpoolCore
import SpoolEngine

/// Per-app rules: float, tile, or a fixed place on the strip.
struct RulesTab: View {
    @ObservedObject var store: ConfigStore
    @ViewState private var selection: String?
    @ViewState private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(store.config.rules) { rule in
                    RuleRow(store: store, rule: rule).tag(rule.bundleID)
                }
            }
            .overlay {
                if store.config.rules.isEmpty {
                    Text("No rules yet. Click + to add an app.").foregroundColor(.secondary)
                }
            }
            .onDeleteCommand(perform: removeSelected)

            HStack(spacing: 0) {
                Button { picking = true } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    .help("Add a rule for an app")
                Button(action: removeSelected) { Image(systemName: "minus").frame(width: 24, height: 20) }
                    .help("Remove the selected rule")
                    .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Note("Float: Spool does not put the windows of this app on the strip.")
                Note("Tile: Spool puts every window of this app on the strip, also windows that cannot resize.")
                Note("Place N: new windows of this app go to place N on the strip.")
            }
            .padding(12)
        }
        .sheet(isPresented: $picking) {
            AppPicker(excluding: Set(store.config.rules.map(\.bundleID))) { app in
                store.update { $0.rules.append(AppRule(bundleID: app.bundleID, appName: app.name, action: .float)) }
                selection = app.bundleID
            }
        }
    }

    private func removeSelected() {
        guard let id = selection else { return }
        store.update { $0.rules.removeAll { $0.bundleID == id } }
        selection = nil
    }
}

private struct RuleRow: View {
    @ObservedObject var store: ConfigStore
    let rule: AppRule

    private enum Kind: String, CaseIterable { case float = "Float", tile = "Tile", slot = "Place" }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcons.icon(bundleID: rule.bundleID))
                .resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.appName)
                Text(rule.bundleID).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Picker("Action", selection: kind) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 90)
            HStack(spacing: 4) {
                if case .slot(let n) = rule.action {
                    Text(verbatim: "\(n)").monospacedDigit().frame(width: 22, alignment: .trailing)
                    Stepper("Place", value: slot, in: 1...20).labelsHidden()
                }
            }
            .frame(width: 60, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var kind: Binding<Kind> {
        Binding(get: {
            switch rule.action {
            case .float: return .float
            case .tile: return .tile
            case .slot: return .slot
            }
        }, set: { kind in
            switch kind {
            case .float: set(.float)
            case .tile: set(.tile)
            case .slot: set(.slot(1))
            }
        })
    }

    private var slot: Binding<Int> {
        Binding(get: { if case .slot(let n) = rule.action { return n } else { return 1 } },
                set: { set(.slot(min(max($0, 1), 20))) })
    }

    private func set(_ action: AppRule.Action) {
        let id = rule.bundleID
        store.update { config in
            if let i = config.rules.firstIndex(where: { $0.bundleID == id }) { config.rules[i].action = action }
        }
    }
}
