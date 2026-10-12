import SwiftUI
import StripleCore
import StripleEngine

/// Polls the Accessibility permission once a second, only while the first guide step is on screen.
@MainActor
final class PermissionWatcher: ObservableObject {
    @Published private(set) var trusted = Permissions.isTrusted
    nonisolated(unsafe) private var timer: Timer?
    var onGranted: (() -> Void)?

    func start() {
        stop()
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        let now = Permissions.isTrusted
        guard now != trusted else { return }
        trusted = now
        if now { onGranted?() }
    }

    deinit { timer?.invalidate() }
}

/// The first-run guide: Accessibility, the strip, the five essential shortcuts.
struct OnboardingView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var engine: Engine
    @EnvironmentObject var app: AppModel
    @ViewState private var step = 0
    private let lastStep = 2

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: PermissionStep(engine: engine)
                case 1: StripStep()
                default: ShortcutsStep(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)

            Divider()
            HStack {
                StepDots(count: lastStep + 1, current: step)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                if step < lastStep {
                    Button("Next") { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") {
                        store.update { $0.behavior.onboardingDone = true }
                        app.closeGuide()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 440)
    }
}

private struct PermissionStep: View {
    @ObservedObject var engine: Engine
    @EnvironmentObject var app: AppModel
    @StateObject private var watcher = PermissionWatcher()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("1. Allow Accessibility").font(.title2.bold())
            Text("Striple moves and resizes the windows of other apps. macOS allows this only with the Accessibility permission. Striple needs no other permission.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: watcher.trusted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(watcher.trusted ? .green : .red)
                    .font(.title2)
                Text(watcher.trusted ? "Permission granted." : "Permission not granted yet.")
            }
            if !watcher.trusted {
                HStack {
                    Button("Request Permission") { Permissions.prompt() }
                    Button("Open System Settings") { Permissions.openSettings(.accessibility) }
                }
                Note("Turn on Striple in the list. This page updates by itself.")
            } else if engine.status == .running {
                Note("Striple is running.")
            }
        }
        .onAppear {
            let model = app
            watcher.onGranted = { [weak model] in model?.autoStartIfNeeded() }
            watcher.start()
        }
        .onDisappear { watcher.stop() }
    }
}

private struct StripStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("2. The strip").font(.title2.bold())
            StripDrawing()
                .frame(height: 140)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                Text("Your windows sit side by side on a long strip.")
                Text("The screen shows one part of the strip. Move the focus and the strip scrolls.")
                Text("A new window opens to the right. The other windows keep their size.")
            }
        }
    }
}

/// Columns on a strip that is wider than the screen. The frame is the visible part.
struct StripDrawing: View {
    private let widths: [CGFloat] = [70, 110, 80, 130, 90, 70]
    private let focused = 3

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 8
            let total = widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
            let start = (geo.size.width - total) / 2
            let viewportX = start + widths[..<2].reduce(0, +) + gap * 2 - gap / 2
            let viewportWidth = widths[2...4].reduce(0, +) + gap * 3
            ZStack(alignment: .topLeading) {
                ForEach(widths.indices, id: \.self) { i in
                    let x = start + widths[..<i].reduce(0, +) + gap * CGFloat(i)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(i == focused ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: widths[i], height: geo.size.height - 40)
                        .offset(x: x, y: 20)
                }
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.primary, lineWidth: 2)
                    .frame(width: viewportWidth, height: geo.size.height - 24)
                    .offset(x: viewportX, y: 12)
                Text("Screen")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .offset(x: viewportX, y: geo.size.height - 12)
            }
        }
        .accessibilityLabel("Windows in columns on a strip. The screen shows three of the six columns.")
    }
}

private struct ShortcutsStep: View {
    @ObservedObject var store: ConfigStore
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3. Five shortcuts to start").font(.title2.bold())
            EssentialShortcuts(store: store)
            Note("You can change every shortcut in Settings > Shortcuts.")
            Button("Open Mac Setup") { app.openSettings(.macSetup) }
                .buttonStyle(.link)
            Note("Mac Setup shows macOS settings that can get in the way of Striple, and how to fix them.")
        }
    }
}

private struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == current ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
        }
    }
}
