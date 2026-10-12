import Combine
import SwiftUI
import StripleCore
import StripleEngine

/// Reads the Mac Setup checks. Refreshes every 2 seconds, but only while the tab is on screen.
@MainActor
final class MacSetupModel: ObservableObject {
    @Published private(set) var checks: [MacSetupCheck] = []
    nonisolated(unsafe) private var timer: Timer?

    func refresh(_ fingers: SwipeFingers) {
        let next = MacSetupProbe.checks(swipeFingers: fingers)
        if next != checks { checks = next }
    }

    func startPolling(_ fingers: @escaping @MainActor () -> SwipeFingers) {
        stopPolling()
        refresh(fingers())
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(fingers()) }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }
}

struct MacSetupTab: View {
    @ObservedObject var store: ConfigStore
    @StateObject private var model = MacSetupModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(summary).font(.headline)
                Spacer()
                Button("Refresh") { model.refresh(store.config.gestures.fingers) }
            }
            .padding(12)

            List(model.checks) { check in
                MacSetupRow(check: check)
            }

            Note("Striple only reads these settings. It never changes macOS settings. You decide what to change.")
                .padding(12)
        }
        .onAppear { model.startPolling { [store] in store.config.gestures.fingers } }
        .onDisappear { model.stopPolling() }
        .onChange(of: store.config.gestures.fingers) { model.refresh($0) }
    }

    private var summary: String {
        let open = model.checks.filter { $0.status != .ok }.count
        if model.checks.isEmpty { return "Checking…" }
        switch open {
        case 0: return "Your Mac is ready for Striple."
        case 1: return "1 item needs your attention."
        default: return "\(open) items need your attention."
        }
    }
}

struct MacSetupRow: View {
    let check: MacSetupCheck

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundColor(color)
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title).fontWeight(.medium)
                if !check.fix.isEmpty { Note(check.fix) }
            }
            Spacer()
            if check.status != .ok {
                if check.pane == .accessibility {
                    Button("Request Permission") { Permissions.prompt() }
                }
                if check.pane != .none {
                    Button("Open Settings") { Permissions.openSettings(check.pane) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch check.status {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch check.status {
        case .ok: return .green
        case .warning: return .orange
        case .problem: return .red
        }
    }
}
