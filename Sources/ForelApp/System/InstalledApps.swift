import AppKit
import Foundation
import UniformTypeIdentifiers

/// Apps installed on this Mac, scanned from the usual install locations.
/// Backs the "Downloaded with app" condition editor: a name + path pair so
/// the UI can both suggest names and show each app's real icon. Purely a UI
/// convenience — the rule engine just compares the stored string regardless
/// of where the value came from.
enum InstalledApps {
    struct App: Hashable {
        let name: String
        let path: String
    }

    private static var searchPaths: [String] {
        var paths = ["/Applications", "/System/Applications", "/System/Applications/Utilities"]
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            paths.append((home as NSString).appendingPathComponent("Applications"))
        }
        return paths
    }

    /// Sorted, deduplicated installed apps. Computed once per process
    /// (`static let` is lazy) — installed apps rarely change mid-session.
    static let all: [App] = {
        var seen = Set<String>()
        var result: [App] = []
        for base in searchPaths {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = (base as NSString).appendingPathComponent(entry)
                let name = displayName(forAppAt: path) ?? (entry as NSString).deletingPathExtension
                if seen.insert(name).inserted {
                    result.append(App(name: name, path: path))
                }
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    static func path(forName name: String) -> String? {
        all.first { $0.name == name }?.path
    }

    static func displayName(forAppAt path: String) -> String? {
        let infoPlistPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: infoPlistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
    }

    /// Opens a Finder-style picker scoped to `/Applications`, restricted to
    /// app bundles, so the user can pick an app visually instead of typing
    /// its name. Returns `nil` if cancelled.
    @MainActor
    static func pickFromFinder() -> App? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let path = url.path
        let name = displayName(forAppAt: path) ?? url.deletingPathExtension().lastPathComponent
        return App(name: name, path: path)
    }
}
