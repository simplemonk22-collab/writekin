import Foundation

/// A single file within a model's Hugging Face repo.
///
/// `bytes: 0` and `sha256: ""` are sentinel values meaning "unverified" —
/// the downloader (Task 4) treats an empty `sha256` as "skip verification".
/// Real sizes/hashes can be filled in later once fetched from the repo.
struct ManifestFile: Codable, Sendable {
    var path: String
    var bytes: Int64
    var sha256: String
}

struct ManifestModel: Codable, Sendable, Identifiable {
    var id: String
    var displayName: String
    var hfRepo: String
    var files: [ManifestFile]
    var license: String
    var ramTierGB: Int
    var kind: String
    var contextLength: Int

    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.bytes }
    }
}

enum ModelManifest {
    /// Loads the manifest bundled with the app (`model-manifest.json`).
    /// Returns an empty array on any failure (soft-fail contract).
    static func load() -> [ManifestModel] {
        guard let url = Bundle.main.url(forResource: "model-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let models = try? load(from: data)
        else {
            return []
        }
        return models
    }

    static func load(from data: Data) throws -> [ManifestModel] {
        try JSONDecoder().decode([ManifestModel].self, from: data)
    }


    /// Installed physical memory in GB, via `hw.memsize` sysctl.
    static func installedMemoryGB() -> Int {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        let result = sysctlbyname("hw.memsize", &size, &len, nil, 0)
        guard result == 0 else { return 0 }
        return Int(size / (1024 * 1024 * 1024))
    }
}
