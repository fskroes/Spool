import AppKit
import SwiftUI
import StripleCore

/// An app that can get a rule.
struct AppEntry: Identifiable, Hashable, Sendable {
    var bundleID: String
    var name: String
    var url: URL?
    var id: String { bundleID }
}

/// Finds running and installed apps. The merge and filter steps are pure.
enum AppCatalog {
    static func installedFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            + [home.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// Reads the `.app` bundles directly inside each folder. Slow on a cold disk: call it off the main thread.
    static func scanInstalled(folders: [URL] = installedFolders()) -> [AppEntry] {
        var out: [AppEntry] = []
        for folder in folders {
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles])) ?? []
            for url in items where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                out.append(AppEntry(bundleID: id, name: displayName(bundle, url: url), url: url))
            }
        }
        return out
    }

    static func running(excluding ownID: String?) -> [AppEntry] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != ownID else { return nil }
            return AppEntry(bundleID: id, name: app.localizedName ?? id, url: app.bundleURL)
        }
    }

    /// One entry per bundle ID (running apps win), without the excluded IDs, sorted by name.
    static func merge(running: [AppEntry], installed: [AppEntry], excluding: Set<String>) -> [AppEntry] {
        var seen = excluding
        var out: [AppEntry] = []
        for entry in running + installed where !seen.contains(entry.bundleID) {
            seen.insert(entry.bundleID)
            out.append(entry)
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Matches the name or the bundle ID. An empty query matches all.
    static func filter(_ entries: [AppEntry], query: String) -> [AppEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.bundleID.localizedCaseInsensitiveContains(q) }
    }

    private static func displayName(_ bundle: Bundle, url: URL) -> String {
        let keys = ["CFBundleDisplayName", "CFBundleName"]
        for dict in [bundle.localizedInfoDictionary, bundle.infoDictionary] {
            for key in keys {
                if let name = dict?[key] as? String, !name.isEmpty { return name }
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

/// App icons, cached because `NSWorkspace.icon(forFile:)` reads from disk.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(bundleID: String, url: URL? = nil) -> NSImage {
        if let cached = cache[bundleID] { return cached }
        let path = (url ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID))?.path
        let image = path.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        cache[bundleID] = image
        return image
    }
}

/// A sheet to pick an app for a new rule.
struct AppPicker: View {
    let excluding: Set<String>
    let onPick: (AppEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var apps: [AppEntry] = []
    @ViewState private var loading = true
    @ViewState private var query = ""
    @ViewState private var selection: String?

    var body: some View {
        let shown = AppCatalog.filter(apps, query: query)
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose an app").font(.headline)
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
            List(shown, selection: $selection) { app in
                HStack {
                    Image(nsImage: AppIcons.icon(bundleID: app.bundleID, url: app.url))
                        .resizable().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                        Text(app.bundleID).font(.caption).foregroundColor(.secondary)
                    }
                }
                .tag(app.bundleID)
            }
            .contextMenu(forSelectionType: String.self, menu: { _ in }, primaryAction: { ids in
                if let id = ids.first, let app = apps.first(where: { $0.bundleID == id }) { pick(app) }
            })
            .overlay {
                if loading { ProgressView() } else if shown.isEmpty { Text("No apps found").foregroundColor(.secondary) }
            }
            HStack {
                Note("Running apps and apps in the Applications folders.")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Rule") {
                    if let app = apps.first(where: { $0.bundleID == selection }) { pick(app) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(width: 460, height: 480)
        .task { await load() }
    }

    private func pick(_ app: AppEntry) {
        onPick(app)
        dismiss()
    }

    private func load() async {
        let ownID = Bundle.main.bundleIdentifier
        let running = AppCatalog.running(excluding: ownID)
        let installed = await Task.detached(priority: .userInitiated) { AppCatalog.scanInstalled() }.value
        apps = AppCatalog.merge(running: running, installed: installed, excluding: excluding.union([ownID].compactMap { $0 }))
        loading = false
    }
}
