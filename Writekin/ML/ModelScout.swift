import Foundation

/// A candidate model directory discovered on disk by `ModelScout`.
///
/// `matchedManifestID` non-nil means the directory's contents were verified
/// (or, in the low-confidence path, plausibly matched by name) against a
/// manifest entry and can be adopted via `ModelScout.adopt`. `note` carries
/// an honest, user-facing explanation when a directory looked relevant but
/// isn't usable (e.g. GGUF weights, which this app's MLX runtime can't load).
struct ScoutedModel: Sendable, Equatable {
    var location: URL
    var appName: String
    var matchedManifestID: String?
    var note: ScoutNote?
}

/// Why a scouted directory can't be used (or was matched less confidently).
/// Typed so the scan (background code, no `Localization` access) never
/// renders text — the Models screen localizes at render time.
enum ScoutNote: Sendable, Equatable {
    case ggufUnusable
    case nameMatchOnly

    var l10nKey: L10nKey {
        switch self {
        case .ggufUnusable: .scoutNoteGGUF
        case .nameMatchOnly: .scoutNoteNameMatch
        }
    }
}

/// Scans well-known local model caches (LM Studio, Hugging Face hub) for
/// files that already match a manifest entry, so the user can adopt an
/// existing on-disk model instead of re-downloading it.
///
/// Scanning is deliberately cheap: files are only hashed when their basename
/// matches some manifest file's basename AND their size matches that file's
/// expected size. This app never hashes multi-gigabyte blobs that can't
/// possibly match anything in the manifest.
struct ModelScout: Sendable {
    private let searchRoots: [(URL, String)]

    /// - Parameter searchRoots: `(directory, appName)` pairs to scan. `nil`
    ///   defaults to the three real local model cache locations.
    init(searchRoots: [(URL, String)]? = nil) {
        if let searchRoots {
            self.searchRoots = searchRoots
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.searchRoots = [
                (home.appendingPathComponent(".cache/lm-studio/models"), "LM Studio"),
                (home.appendingPathComponent(".lmstudio/models"), "LM Studio (legacy)"),
                (home.appendingPathComponent(".cache/huggingface/hub"), "Hugging Face"),
            ]
        }
    }

    /// Scans each search root (up to three levels deep, matching the
    /// `models--org--name/snapshots/<rev>` layout used by these caches) and
    /// returns one `ScoutedModel` per candidate directory found.
    func scan(manifest: [ManifestModel]) -> [ScoutedModel] {
        let fm = FileManager.default
        var results: [ScoutedModel] = []

        for (root, appName) in searchRoots {
            guard let candidateDirs = try? candidateDirectories(under: root, fm: fm) else { continue }
            for dir in candidateDirs {
                guard let filesUnderDir = try? allFiles(under: dir, fm: fm) else { continue }

                if filesUnderDir.contains(where: { $0.pathExtension.lowercased() == "gguf" }) {
                    results.append(ScoutedModel(
                        location: dir, appName: appName, matchedManifestID: nil,
                        note: .ggufUnusable))
                    continue
                }

                if let matchID = matchByChecksum(dir: dir, files: filesUnderDir, manifest: manifest, fm: fm) {
                    results.append(ScoutedModel(location: dir, appName: appName, matchedManifestID: matchID, note: nil))
                    continue
                }

                if let matchID = matchByDirectoryName(dir: dir, manifest: manifest) {
                    results.append(ScoutedModel(
                        location: dir, appName: appName, matchedManifestID: matchID,
                        note: .nameMatchOnly))
                    continue
                }
            }
        }

        return results
    }

    /// Clones every manifest file for the matched model from `scouted.location`
    /// into `<modelsRoot>/<manifestID>/`, using `clonefile` (via `cp -c`) where
    /// possible so the operation is instant and copy-on-write, falling back to
    /// a plain copy elsewhere. Records an `InstalledModel(source: "cloned")`.
    func adopt(_ scouted: ScoutedModel, manifest: [ManifestModel], into modelsRoot: URL, db: AppDatabase) async throws {
        guard let modelID = scouted.matchedManifestID,
              let model = manifest.first(where: { $0.id == modelID })
        else {
            throw ModelScoutError.noMatch
        }

        let fm = FileManager.default
        let sourceFiles = (try? allFiles(under: scouted.location, fm: fm)) ?? []
        let destDir = modelsRoot.appendingPathComponent(model.id)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        for file in model.files {
            guard let sourceURL = sourceFiles.first(where: { $0.lastPathComponent == basename(file.path) }) else {
                // A manifest file with a real checksum, or any safetensors
                // weight file, missing from the scouted source means this
                // isn't actually a usable copy of the model — fail loudly
                // rather than silently adopting a partial/broken install.
                let isWeights = (file.path as NSString).pathExtension.lowercased() == "safetensors"
                if !file.sha256.isEmpty || isWeights {
                    throw ModelScoutError.missingFile(file.path)
                }
                continue
            }
            let destURL = destDir.appendingPathComponent(file.path)
            try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try Self.cloneFile(from: sourceURL, to: destURL)
        }

        let installed = InstalledModel(
            id: model.id, repo: model.hfRepo, path: destDir.path,
            kind: model.kind, installedAt: Date(), source: "cloned")
        try await db.writer.write { dbc in
            try installed.insert(dbc)
        }
    }

    enum ModelScoutError: Error, Equatable {
        case noMatch
        /// A manifest file with a real checksum, or a `.safetensors` weight
        /// file, was missing from the scouted source directory during `adopt`.
        case missingFile(String)
    }

    // MARK: - Matching

    private func matchByChecksum(
        dir: URL, files: [URL], manifest: [ManifestModel], fm: FileManager
    ) -> String? {
        for model in manifest {
            let verifiableFiles = model.files.filter { !$0.sha256.isEmpty }
            guard !verifiableFiles.isEmpty else { continue }

            var allMatch = true
            for manifestFile in verifiableFiles {
                guard let candidate = files.first(where: { $0.lastPathComponent == basename(manifestFile.path) })
                else {
                    allMatch = false
                    break
                }
                guard plausibleSize(candidate, expected: manifestFile.bytes, fm: fm),
                      let hash = try? sha256HexOfFile(at: candidate),
                      hash == manifestFile.sha256
                else {
                    allMatch = false
                    break
                }
            }
            if allMatch {
                return model.id
            }
        }
        return nil
    }

    /// Low-confidence path used only when a manifest entry has no verifiable
    /// hashes at all: match by the directory name containing the model's
    /// *full* id (or its `hfRepo` tail), separator-normalized so cache
    /// layouts like `models--org--Qwen2.5-7B-Instruct-4bit` still line up.
    /// A short, generic fragment (e.g. "4bit") is deliberately not enough —
    /// that previously misadopted any quantized model into any manifest
    /// entry sharing that suffix.
    private func matchByDirectoryName(dir: URL, manifest: [ManifestModel]) -> String? {
        let dirName = Self.normalizeForMatch(dir.path)
        for model in manifest {
            let allEmpty = !model.files.isEmpty && model.files.allSatisfy { $0.sha256.isEmpty }
            guard allEmpty else { continue }
            let repoTail = model.hfRepo.split(separator: "/").last.map(String.init) ?? model.hfRepo
            let candidates = [model.id, repoTail]
            for candidate in candidates {
                let normalized = Self.normalizeForMatch(candidate)
                guard !normalized.isEmpty, dirName.contains(normalized) else { continue }
                return model.id
            }
        }
        return nil
    }

    /// Lowercases and collapses `--`/`_` separators to a single `-`, so
    /// Hugging Face cache directory names (`--`-joined) and manifest ids
    /// (`-`-joined) compare equal regardless of separator style.
    private static func normalizeForMatch(_ s: String) -> String {
        var result = s.lowercased()
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        return result.replacingOccurrences(of: "_", with: "-")
    }

    private func plausibleSize(_ url: URL, expected: Int64, fm: FileManager) -> Bool {
        guard expected > 0 else { return true }
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return false }
        return size.int64Value == expected
    }

    private func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    // MARK: - Filesystem enumeration

    /// Returns leaf-ish directories up to 3 levels under `root` that
    /// plausibly hold a model snapshot (i.e. contain at least one file).
    private func candidateDirectories(under root: URL, fm: FileManager) throws -> [URL] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        var results: [URL] = []
        let level1 = try contentsDirs(of: root, fm: fm)
        for d1 in level1 {
            let level2 = try contentsDirs(of: d1, fm: fm)
            if level2.isEmpty {
                if try hasFiles(d1, fm: fm) { results.append(d1) }
                continue
            }
            for d2 in level2 {
                let level3 = try contentsDirs(of: d2, fm: fm)
                if level3.isEmpty {
                    if try hasFiles(d2, fm: fm) { results.append(d2) }
                    continue
                }
                for d3 in level3 where try hasFiles(d3, fm: fm) {
                    results.append(d3)
                }
            }
        }
        return results
    }

    private func contentsDirs(of dir: URL, fm: FileManager) throws -> [URL] {
        let entries = try fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    private func hasFiles(_ dir: URL, fm: FileManager) throws -> Bool {
        !(try allFiles(under: dir, fm: fm)).isEmpty
    }

    private func allFiles(under dir: URL, fm: FileManager) throws -> [URL] {
        guard let enumerator = fm.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    // MARK: - Clonefile

    /// Copy-on-write clone via `cp -c` (APFS clonefile), falling back to a
    /// plain `FileManager.copyItem` when cloning isn't supported (e.g. across
    /// volumes, or non-APFS filesystems).
    private static func cloneFile(from sourceURL: URL, to destURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-c", sourceURL.path, destURL.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            return
        }
        if process.terminationStatus != 0 {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        }
    }
}
