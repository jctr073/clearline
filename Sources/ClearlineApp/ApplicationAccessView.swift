import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ClearlineCore

struct InstalledApplication: Identifiable {
    let id: String
    let name: String
    let url: URL

    init(url: URL) throws {
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let id = bundle.bundleIdentifier, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApplicationLookupError.invalidApplication
        }
        self.id = id
        self.url = url
        let names = [bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                     bundle.object(forInfoDictionaryKey: "CFBundleName") as? String]
        name = names.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? url.deletingPathExtension().lastPathComponent
    }

    static func find(_ id: String) -> InstalledApplication? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return try? InstalledApplication(url: url)
    }
}

enum ApplicationLookupError: LocalizedError {
    case invalidApplication
    var errorDescription: String? { "Choose a Mac application (.app) with a valid bundle identifier." }
}

struct ApplicationAccessView: View {
    @ObservedObject var state: AppState
    @State private var applications: [String: InstalledApplication] = [:]
    @State private var manualID = ""
    @State private var lookupError: String?

    private var trimmedID: String { manualID.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Section("App access") {
            HStack {
                Text("Choose apps to allow selected-text assistance.")
                Spacer()
                Button("Browse apps…", systemImage: "folder") { browse() }
            }
            if let lookupError { Text(lookupError).font(.caption).foregroundStyle(.red) }
            DisclosureGroup("Advanced: enter a bundle identifier") {
                HStack {
                    TextField("For example, com.apple.TextEdit", text: $manualID)
                    Button("Allow") { setAccess(trimmedID, allowed: true); manualID = "" }.disabled(trimmedID.isEmpty)
                    Button("Block") { setAccess(trimmedID, allowed: false); manualID = "" }.disabled(trimmedID.isEmpty)
                }
            }
        }
        Section("Allowed apps") {
            let allowed = state.preferences.allowedApps.subtracting(state.preferences.blockedApps)
            if allowed.isEmpty { Text("No apps allowed yet.").foregroundStyle(.secondary) }
            ForEach(sorted(allowed), id: \.self) { id in
                HStack(spacing: 12) {
                    applicationLabel(id: id)
                    Spacer()
                    Button("Remove") { state.preferences.allowedApps.remove(id); state.crossApp?.invalidate() }
                        .accessibilityLabel("Remove \(applications[id]?.name ?? id)")
                }
            }
            Text("Allowing an app enables selected-text assistance when you invoke Clearline. Text support varies by app.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !state.preferences.blockedApps.isEmpty {
            Section("Blocked apps") {
                ForEach(sorted(state.preferences.blockedApps), id: \.self) { id in
                    HStack(spacing: 12) {
                        applicationLabel(id: id)
                        Spacer()
                        Button("Unblock") {
                            state.preferences.blockedApps.remove(id)
                            state.preferences.allowedApps.remove(id)
                            state.crossApp?.invalidate()
                        }
                            .accessibilityLabel("Unblock \(applications[id]?.name ?? id)")
                    }
                }
                Text("Blocked apps cannot use selected-text assistance. Unblocking an app does not add it to Allowed apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func applicationLabel(id: String) -> some View {
        HStack(spacing: 10) {
            if let app = applications[id] {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable().scaledToFit().frame(width: 28, height: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                    Text(id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else {
                Image(systemName: "app.dashed").font(.title2).frame(width: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(id).textSelection(.enabled)
                    Text("App not found on this Mac").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: id) {
            if applications[id] == nil { applications[id] = InstalledApplication.find(id) }
        }
    }

    private func sorted(_ ids: Set<String>) -> [String] {
        ids.sorted {
            let comparison = (applications[$0]?.name ?? $0).localizedStandardCompare(applications[$1]?.name ?? $1)
            return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
        }
    }

    private func setAccess(_ id: String, allowed: Bool) {
        guard !id.isEmpty else { return }
        if allowed {
            state.preferences.blockedApps.remove(id)
            state.preferences.allowedApps.insert(id)
        } else {
            state.preferences.allowedApps.remove(id)
            state.preferences.blockedApps.insert(id)
        }
        state.crossApp?.invalidate()
        lookupError = nil
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.title = "Allow applications"
        panel.message = "Select one or more apps. Hold Command to select individual apps or Shift to select a range."
        panel.prompt = "Allow selected apps"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        do {
            // Validate the whole selection before changing access for any app.
            let selected = try panel.urls.map { try InstalledApplication(url: $0) }
            var preferences = state.preferences
            for app in selected {
                applications[app.id] = app
                preferences.blockedApps.remove(app.id)
                preferences.allowedApps.insert(app.id)
            }
            state.preferences = preferences
            state.crossApp?.invalidate()
            lookupError = nil
        } catch { lookupError = "No apps were added. \(error.localizedDescription)" }
    }
}
