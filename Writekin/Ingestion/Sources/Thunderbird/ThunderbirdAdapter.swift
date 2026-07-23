import Foundation

struct ThunderbirdAdapter: SourceAdapter {
    static let kind = SourceKind.thunderbird

    var thunderbirdRoot: URL

    init(thunderbirdRoot: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Thunderbird")) {
        self.thunderbirdRoot = thunderbirdRoot
    }

    /// On-disk mailbox names to match, lowercased. These follow the language
    /// of the mail client that created them, not the app's UI language —
    /// format vocabulary, not display text, so deliberately independent of
    /// App/Locales and broader than the UI languages the app supports.
    static let localizedSentMailboxNames: Set<String> = [
        "sent", "sent mail", "sent messages", "sent items", "sent-1",
        "gesendet", "envoyés", "enviados", "inviata",
    ]

    /// Rough mbox-size-to-message-count heuristic; surfaced as an estimate in notes.
    private static let bytesPerMessageEstimate: Int64 = 4096

    func detect() async throws -> SourceReport {
        let fm = FileManager.default
        let ini = thunderbirdRoot.appendingPathComponent("profiles.ini")
        guard let iniText = try? String(contentsOf: ini, encoding: .utf8) else {
            return SourceReport(kind: Self.kind, found: false)
        }

        var totalBytes: Int64 = 0
        var foundAny = false
        var sawMaildir = false
        for profile in Self.profilePaths(fromINI: iniText, root: thunderbirdRoot) {
            for subdirName in ["ImapMail", "Mail"] {
                let subdir = profile.appendingPathComponent(subdirName)
                guard let servers = try? fm.contentsOfDirectory(
                    at: subdir, includingPropertiesForKeys: nil) else { continue }
                for server in servers where server.hasDirectoryPath {
                    for entry in Self.matchedEntries(under: server, sentNames: Self.localizedSentMailboxNames) {
                        if entry.hasDirectoryPath {
                            sawMaildir = true
                            continue
                        }
                        foundAny = true
                        let size = (try? entry.resourceValues(forKeys: [URLResourceKey.fileSizeKey]).fileSize) ?? 0
                        totalBytes += Int64(size)
                    }
                }
            }
        }

        var notes: [DetectNote] = []
        if sawMaildir { notes.append(.maildirUnsupported) }
        guard foundAny else {
            return SourceReport(kind: Self.kind, found: false, notes: notes)
        }
        notes.append(.countEstimatedFromSize)
        let estimate = max(1, Int(totalBytes / Self.bytesPerMessageEstimate))
        return SourceReport(kind: Self.kind, found: true,
                            estimatedItemCount: estimate, notes: notes)
    }

    /// Walks a server directory (and recursively any `*.sbd` subdirectory) for
    /// entries whose lowercased name is in `sentNames`, skipping `.msf` index
    /// files. Returns both matching files and matching directories (the latter
    /// indicate an unsupported maildir-format mailbox).
    private static func matchedEntries(under dir: URL, sentNames: Set<String>) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        let entries = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries {
            let name = entry.lastPathComponent.lowercased()
            if entry.hasDirectoryPath {
                if entry.pathExtension.lowercased() == "sbd" {
                    result.append(contentsOf: matchedEntries(under: entry, sentNames: sentNames))
                    continue
                }
                if sentNames.contains(name) {
                    result.append(entry)
                }
                continue
            }
            guard entry.pathExtension != "msf", sentNames.contains(name) else { continue }
            result.append(entry)
        }
        return result
    }

    /// Sent mbox files (maildir directories excluded) under a server dir,
    /// including any nested inside `*.sbd` subfolders.
    static func sentMboxFiles(under serverDir: URL, sentNames: Set<String>) -> [URL] {
        matchedEntries(under: serverDir, sentNames: sentNames).filter { !$0.hasDirectoryPath }
    }

    static func profilePaths(fromINI text: String, root: URL) -> [URL] {
        var result: [URL] = []
        var inProfileSection = false
        var currentPath: String?
        var currentIsRelative = true

        func flush() {
            if inProfileSection, let path = currentPath {
                result.append(currentIsRelative
                    ? root.appendingPathComponent(path)
                    : URL(fileURLWithPath: path))
            }
            currentPath = nil
            currentIsRelative = true
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                inProfileSection = line.lowercased().hasPrefix("[profile")
            } else if let eq = line.firstIndex(of: "=") {
                let key = String(line[..<eq]).lowercased()
                let value = String(line[line.index(after: eq)...])
                if key == "path" { currentPath = value }
                if key == "isrelative" { currentIsRelative = (value == "1") }
            }
        }
        flush()
        return result
    }
}
