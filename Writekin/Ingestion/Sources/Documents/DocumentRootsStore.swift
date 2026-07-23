import Foundation

/// Settings-backed list of folders scanned for documents (detection and
/// ingestion). Stored under the `doc.roots` key as a JSON array of absolute
/// paths; when the key is unset the built-in defaults apply. The first
/// add/remove materializes the defaults into the stored list so later edits
/// (including removing a default) persist.
enum DocumentRootsStore {
    static let key = "doc.roots"

    /// Built-in scan locations: ~/Documents, ~/Desktop, iCloud Drive, and
    /// every third-party provider folder under ~/Library/CloudStorage.
    static func defaultRoots() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var defaults = [
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"),
        ]
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        if let providers = try? FileManager.default.contentsOfDirectory(
            at: cloudStorage, includingPropertiesForKeys: nil) {
            defaults.append(contentsOf: providers.filter(\.hasDirectoryPath)
                .sorted { $0.path < $1.path })
        }
        return defaults
    }

    /// The configured roots, or the defaults when nothing has been stored
    /// (or the stored value can't be decoded).
    static func load(settings: SettingsStore) async -> [URL] {
        guard let json = try? await settings.get(key),
              let data = json.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data)
        else { return defaultRoots() }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    static func add(path: String, settings: SettingsStore) async throws {
        var paths = await load(settings: settings).map(\.path)
        let normalized = standardize(path)
        guard !paths.contains(where: { standardize($0) == normalized }) else { return }
        paths.append(normalized)
        try await save(paths, settings: settings)
    }

    static func remove(path: String, settings: SettingsStore) async throws {
        let normalized = standardize(path)
        var paths = await load(settings: settings).map(\.path)
        paths.removeAll { standardize($0) == normalized }
        try await save(paths, settings: settings)
    }

    /// Clears the stored list so the built-in defaults apply again.
    static func reset(settings: SettingsStore) async throws {
        try await settings.set(key, nil)
    }

    private static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func save(_ paths: [String], settings: SettingsStore) async throws {
        let data = try JSONEncoder().encode(paths)
        try await settings.set(key, String(data: data, encoding: .utf8))
    }
}
