import Foundation

struct FileSystemAdapter: SourceAdapter {
    static let kind = SourceKind.fileSystem

    var roots: [URL]

    static let supportedExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "mdown", "docx", "doc", "rtf", "pdf",
    ]
    /// Document formats stored as directory bundles, counted as single items.
    static let bundleExtensions: Set<String> = ["pages", "rtfd"]
    static let excludedDirNames: Set<String> = ["node_modules", ".git", ".Trash"]
    /// Repo-convention files that are essentially never the user's own prose.
    /// Compared against the lowercased filename minus extension.
    static let nonAuthoredBaseNames: Set<String> = [
        "readme", "license", "licence", "changelog", "contributing",
        "code_of_conduct", "notice", "authors", "copying",
    ]

    init(roots: [URL]? = nil) {
        // Built-in defaults live in DocumentRootsStore so detection,
        // ingestion, and the Sources folder list all agree; callers that
        // can load the user-configured roots pass them in explicitly.
        self.roots = roots ?? DocumentRootsStore.defaultRoots()
    }

    /// Matched document files and bundles under a root (same exclusion rules
    /// as detection). Bundles (.pages/.rtfd) are returned as single URLs.
    static func candidateFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return result }
        for case let url as URL in enumerator {
            if excludedDirNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            if bundleExtensions.contains(ext) {
                enumerator.skipDescendants()
                result.append(url)
            } else if supportedExtensions.contains(ext),
                      !nonAuthoredBaseNames.contains(
                        url.deletingPathExtension().lastPathComponent.lowercased()),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                        .isRegularFile == true {
                result.append(url)
            }
        }
        return result
    }

    private func walkDirectory(at root: URL) -> (count: Int, minDate: Date?, maxDate: Date?) {
        let fm = FileManager.default
        var minDate: Date?
        var maxDate: Date?
        let candidates = Self.candidateFiles(under: root)

        for url in candidates {
            guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]),
                  let mtime = values.contentModificationDate
            else { continue }
            minDate = Swift.min(minDate ?? mtime, mtime)
            maxDate = Swift.max(maxDate ?? mtime, mtime)
        }

        return (candidates.count, minDate, maxDate)
    }

    func detect() async throws -> SourceReport {
        var totalCount = 0
        var globalMinDate: Date?
        var globalMaxDate: Date?
        var perRootCounts: [(name: String, count: Int)] = []

        for root in roots {
            let (count, minDate, maxDate) = walkDirectory(at: root)
            totalCount += count
            if count > 0 {
                perRootCounts.append((Self.friendlyName(for: root), count))
            }
            if let minDate {
                globalMinDate = Swift.min(globalMinDate ?? minDate, minDate)
            }
            if let maxDate {
                globalMaxDate = Swift.max(globalMaxDate ?? maxDate, maxDate)
            }
        }

        guard totalCount > 0 else {
            return SourceReport(kind: Self.kind, found: false)
        }
        var dateRange: ClosedRange<Date>?
        if let globalMinDate, let globalMaxDate { dateRange = globalMinDate...globalMaxDate }
        var notes: [DetectNote] = []
        if perRootCounts.count > 1 {
            for entry in perRootCounts {
                notes.append(.itemsInFolder(count: entry.count, name: entry.name))
            }
        }
        return SourceReport(kind: Self.kind, found: true,
                            estimatedItemCount: totalCount, dateRange: dateRange,
                            notes: notes)
    }

    static func friendlyName(for root: URL) -> String {
        if root.lastPathComponent == "com~apple~CloudDocs" { return "iCloud Drive" }
        return root.lastPathComponent
    }
}
