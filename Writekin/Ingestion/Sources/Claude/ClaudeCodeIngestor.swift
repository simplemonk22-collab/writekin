import Foundation

/// Reads the user's own prompts out of Claude Code session transcripts
/// (`~/.claude/projects/<project>/<session>.jsonl`) — conversational,
/// unguarded writing that's pure authored voice. ONLY the human side is
/// ingested; assistant turns are AI text and never touch the corpus.
///
/// A transcript's `"user"`-typed lines include plenty that ISN'T the
/// user's writing, all skipped here: tool results (delivered as user-role
/// messages), sidechain/subagent traffic, slash-command invocations, and
/// harness artifacts like "[Request interrupted…]". Code-heavy prompts and
/// long pastes are dropped later by `FilterPass` ("code_content" /
/// "likely_paste") so they're visible in Browse rather than silently gone.
enum ClaudeCodeStore {
    static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }

    struct ChatMessage: Sendable, Equatable {
        var uuid: String
        var sessionID: String?
        var text: String
        var timestamp: Date?
    }

    /// Harness artifacts that surface as user-typed text but aren't the
    /// user's writing.
    private static let skipPrefixes = [
        "<command-name>", "<local-command", "[Request interrupted",
        "Caveat: the messages below",
    ]

    static func transcriptFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        let projectDirs = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        return projectDirs.filter(\.hasDirectoryPath).flatMap { dir in
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
        }.sorted { $0.path < $1.path }
    }

    /// Claude Desktop agent-mode roots: sessions store `audit.jsonl`
    /// transcripts nested a few levels deep. Regular Desktop chats are
    /// server-side only (verified empty: no conversation payloads in the
    /// app's IndexedDB or HTTP cache) — agent mode is all there is locally.
    static var desktopSessionsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
    }

    static func desktopAuditFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "audit.jsonl" }
            .sorted { $0.path < $1.path }
    }

    /// Parses one transcript's real user messages. Malformed lines are
    /// skipped, never fatal — transcripts are another program's internals.
    static func userMessages(inTranscript text: String) -> [ChatMessage] {
        var result: [ChatMessage] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let rec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  rec["type"] as? String == "user",
                  (rec["isSidechain"] as? Bool) != true,
                  let message = rec["message"] as? [String: Any]
            else { continue }

            let messageText: String
            if let content = message["content"] as? String {
                messageText = content
            } else if let blocks = message["content"] as? [[String: Any]] {
                // Tool results arrive as user-role messages — the tool's
                // output, not the user's words.
                guard !blocks.contains(where: { $0["type"] as? String == "tool_result" })
                else { continue }
                messageText = blocks
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
            } else {
                continue
            }

            let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !skipPrefixes.contains(where: { trimmed.hasPrefix($0) })
            else { continue }

            // Claude Desktop's agent-mode audit transcripts use snake_case
            // session ids and an `_audit_timestamp` key; Claude Code uses
            // `sessionId`/`timestamp`. Same records otherwise.
            result.append(ChatMessage(
                uuid: rec["uuid"] as? String ?? UUID().uuidString,
                sessionID: (rec["sessionId"] ?? rec["session_id"]) as? String,
                text: trimmed,
                timestamp: ((rec["timestamp"] ?? rec["_audit_timestamp"]) as? String)
                    .flatMap(parseTimestamp)))
        }
        return result
    }

    // Cached: parseTimestamp runs once per transcript line (thousands per
    // ingest) and ISO8601DateFormatter construction is not cheap.
    // nonisolated(unsafe) is sound here: ISO8601DateFormatter is documented
    // thread-safe (unlike DateFormatter pre-iOS 7), it just predates Sendable.
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plainFormatter = ISO8601DateFormatter()

    static func parseTimestamp(_ iso: String) -> Date? {
        fractionalFormatter.date(from: iso) ?? plainFormatter.date(from: iso)
    }
}

/// Detect card: reports whether ~/.claude/projects exists and how many
/// session transcripts it holds.
struct ClaudeCodeAdapter: SourceAdapter {
    static let kind = SourceKind.claudeCode
    var root: URL = ClaudeCodeStore.defaultRoot

    func detect() async throws -> SourceReport {
        let files = ClaudeCodeStore.transcriptFiles(under: root)
        return SourceReport(kind: Self.kind, found: !files.isEmpty,
                            estimatedItemCount: files.isEmpty ? nil : files.count,
                            notes: files.isEmpty
                                ? []
                                : [.claudeCodeSessions(files.count)])
    }
}

struct ClaudeCodeIngestor: SourceIngestor {
    static let kind = SourceKind.claudeCode

    var root: URL = ClaudeCodeStore.defaultRoot
    var writer: CorpusWriter

    init(root: URL = ClaudeCodeStore.defaultRoot, writer: CorpusWriter) {
        self.root = root
        self.writer = writer
    }

    func ingest(into writer: CorpusWriter,
                progress: @Sendable (IngestProgress) -> Void) async throws {
        try await ingestClaudeTranscripts(
            files: ClaudeCodeStore.transcriptFiles(under: root),
            phase: .readingClaudeCodeSessions,
            kind: Self.kind, writer: writer, progress: progress)
    }
}

/// Claude Desktop: only agent-mode sessions store transcripts locally
/// (`audit.jsonl`, same record schema as Claude Code) — regular Desktop
/// chats live on Anthropic's servers with nothing parseable on disk.
struct ClaudeDesktopAdapter: SourceAdapter {
    static let kind = SourceKind.claudeDesktop
    var root: URL = ClaudeCodeStore.desktopSessionsRoot

    func detect() async throws -> SourceReport {
        let files = ClaudeCodeStore.desktopAuditFiles(under: root)
        return SourceReport(kind: Self.kind, found: !files.isEmpty,
                            estimatedItemCount: files.isEmpty ? nil : files.count,
                            notes: files.isEmpty
                                ? [.claudeDesktopServerSide]
                                : [.claudeDesktopSessions(files.count)])
    }
}

struct ClaudeDesktopIngestor: SourceIngestor {
    static let kind = SourceKind.claudeDesktop

    var root: URL = ClaudeCodeStore.desktopSessionsRoot
    var writer: CorpusWriter

    init(root: URL = ClaudeCodeStore.desktopSessionsRoot, writer: CorpusWriter) {
        self.root = root
        self.writer = writer
    }

    func ingest(into writer: CorpusWriter,
                progress: @Sendable (IngestProgress) -> Void) async throws {
        try await ingestClaudeTranscripts(
            files: ClaudeCodeStore.desktopAuditFiles(under: root),
            phase: .readingClaudeDesktopSessions,
            kind: Self.kind, writer: writer, progress: progress)
    }
}

/// Shared transcript-ingest loop for both Claude sources: per-file
/// size+mtime fingerprint skip (transcripts are append-only), per-message
/// dedupe via external id, item kind "chat".
private func ingestClaudeTranscripts(
    files: [URL], phase: IngestPhase, kind: SourceKind, writer: CorpusWriter,
    progress: @Sendable (IngestProgress) -> Void
) async throws {
    let sourceID = try await writer.sourceID(for: kind)
    var tally = IngestProgress(phase: phase)
    progress(tally)

    for file in files {
        try Task.checkCancellation()
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let mtime = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        if let stored = try? await writer.fileFingerprint(path: file.path),
           stored == "\(size):\(mtime)" {
            tally.skippedFiles += 1
            progress(tally)
            continue
        }

        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let project = file.deletingLastPathComponent().lastPathComponent
        let raws = ClaudeCodeStore.userMessages(inTranscript: text).map { message in
            RawItem(
                externalID: "\(project)/\(file.lastPathComponent)#\(message.uuid)",
                kind: .chat,
                authoredAt: message.timestamp,
                authoredAtConfidence: message.timestamp != nil ? .embedded : nil,
                accountHint: nil,
                recipients: [],
                threadID: message.sessionID,
                rawText: message.text)
        }
        for result in try await writer.writeBatch(raws, sourceID: sourceID, accountID: nil) {
            switch result {
            case .inserted: tally.itemsLanded += 1
            default: tally.skipped += 1
            }
        }
        progress(tally)
        try? await writer.setFileFingerprint(path: file.path, size: size, mtimeEpoch: mtime)
    }
    try await writer.markSynced(sourceID: sourceID)
}
