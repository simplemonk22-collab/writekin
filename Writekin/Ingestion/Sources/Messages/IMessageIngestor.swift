import Foundation

struct IMessageIngestor: SourceIngestor {
    static let kind = SourceKind.iMessage

    /// Settings key holding the epoch seconds of the last successful full
    /// ingest — the incremental-export high-water mark. Cleared by
    /// `CorpusReset` so a reset corpus re-exports everything.
    static let highWaterKey = "imessage.lastIngestedAt"
    /// Export overlap: start this many days BEFORE the high-water mark, so
    /// messages that synced late from another device still get picked up
    /// and reply-context pairing has its preceding messages in-window
    /// (the write-side dedupe makes re-seen messages free).
    static let overlapDays = 14.0

    var chatDB: URL
    var exporter: any MessageExporting
    var writer: CorpusWriter

    init(chatDB: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Messages/chat.db"),
         exporter: any MessageExporting = ImessageExporterCLI(),
         writer: CorpusWriter) {
        self.chatDB = chatDB
        self.exporter = exporter
        self.writer = writer
    }

    func ingest(into writer: CorpusWriter,
                progress: @Sendable (IngestProgress) -> Void) async throws {
        let fm = FileManager.default
        let sourceID = try await writer.sourceID(for: Self.kind)
        var tally = IngestProgress(phase: .exportingMessages)
        progress(tally)
        // Probe the chatDB's parent dir first so an FDA denial is distinguishable
        // from "no Messages data" (mirrors IMessageAdapter.detect's probe).
        do {
            _ = try fm.contentsOfDirectory(atPath: chatDB.deletingLastPathComponent().path)
        } catch {
            if isPermissionDenied(error) { throw DetectError.permissionDenied }
            throw error
        }
        let work = fm.temporaryDirectory
            .appendingPathComponent("\(AppIdentity.lowercaseName)-imessage-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let copied = work.appendingPathComponent("chat.db")
        try fm.copyItem(at: chatDB, to: copied)
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: chatDB.path + suffix) {
            try? fm.copyItem(atPath: chatDB.path + suffix, toPath: copied.path + suffix)
        }
        // Incremental export: after a successful full pass we remember when
        // it ran, and later runs export only from a few days before that
        // mark — instead of re-exporting and re-parsing the entire message
        // history every time.
        let storedHighWater = (try? await writer.settingsStore
            .get(Self.highWaterKey)) ?? nil
        let startDate = storedHighWater.flatMap(Double.init).map {
            Date(timeIntervalSince1970: $0 - Self.overlapDays * 86_400)
        }
        let exportDir = work.appendingPathComponent("export")
        try await exporter.export(chatDB: copied, to: exportDir, startDate: startDate)
        try Task.checkCancellation()
        let txtFiles = (try? fm.contentsOfDirectory(at: exportDir,
                                                    includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "txt" } ?? []
        for file in txtFiles {
            try Task.checkCancellation()
            let chatName = file.deletingPathExtension().lastPathComponent
            tally.phase = .reading(chatName)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                tally.unparseable += 1
                continue
            }
            let results = try await writer.writeBatch(
                Self.parseExportedTxt(text, chatName: chatName),
                sourceID: sourceID, accountID: nil)
            for result in results {
                switch result {
                case .inserted: tally.itemsLanded += 1
                default: tally.skipped += 1
                }
            }
            progress(tally)
        }
        // Only after a full uncancelled pass (a cancel throws before this
        // line), so a cut-short run re-exports the same window next time.
        try await writer.settingsStore.set(
            Self.highWaterKey, String(Date().timeIntervalSince1970))
        try await writer.markSynced(sourceID: sourceID)
        progress(tally)
    }

    /// imessage-exporter txt format: "<date>\n<sender>\n<body…>" blocks
    /// separated by blank lines; "Me" is the account owner. Remembers the most
    /// recent non-"Me" block (body stripped like "Me" bodies, truncated to the
    /// last 500 characters) and attaches it as `contextText` to the next "Me"
    /// block when the gap is within 12 hours (spec §2). Context is consumed by
    /// the first reply so a run of consecutive "Me" blocks doesn't repeat it.
    static func parseExportedTxt(_ text: String, chatName: String) -> [RawItem] {
        var items: [RawItem] = []
        var participants: Set<String> = []
        var pendingContext: (body: String, date: Date?)?
        let blocks = text.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard lines.count >= 2 else { continue }
            if lines[0].hasPrefix("Tapbacks:") { continue }
            let date = Self.parseExportDate(lines[0])
            guard date != nil || looksLikeDateLine(lines[0]) else { continue }
            let sender = lines[1]
            let body = lines.dropFirst(2)
                .filter { !$0.hasPrefix("Tapbacks:") && !AttachmentPathLine.matches($0) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if sender != "Me" {
                participants.insert(sender)
                if !body.isEmpty {
                    pendingContext = (body: String(body.suffix(500)), date: date)
                }
                continue
            }
            guard !body.isEmpty else { continue }
            var contextText: String?
            if let pending = pendingContext,
               let replyDate = date, let contextDate = pending.date,
               replyDate.timeIntervalSince(contextDate) <= 12 * 3600 {
                contextText = pending.body
            }
            pendingContext = nil   // consumed (or expired) by this reply
            // Content-derived identity, NOT the positional index: with
            // --start-date the export window shifts, so "chat#146" numbers
            // a DIFFERENT message each run — old messages re-add under
            // fresh ids and (worse) a new message can collide with a stale
            // id and be swallowed as already-ingested. Timestamp + body
            // hash is stable no matter where the window starts.
            var item = RawItem(
                externalID: "\(chatName)#\(Int(date?.timeIntervalSince1970 ?? 0))#\(sha256Hex(body).prefix(12))",
                kind: .sms,
                authoredAt: date,
                authoredAtConfidence: date != nil ? .embedded : nil,
                accountHint: nil,
                recipients: [],
                threadID: chatName,
                rawText: body)
            item.contextText = contextText
            items.append(item)
        }
        let finalRecipients = participants.isEmpty ? [chatName] : Array(participants).sorted()
        return items.map { item in
            var updated = item
            updated.recipients = finalRecipients
            return updated
        }
    }

    /// imessage-exporter date lines vary more than one strict format:
    /// single-digit days print unpadded ("Jun 5, 2024"), spacing between date
    /// and time isn't always doubled, and read receipts append a
    /// parenthetical ("… PM (Read by them after 1 hour)"). The old strict
    /// `dd`+double-space parse silently dropped the timestamp for ~13% of
    /// real messages — which also cost them reply-context (12h window) and
    /// cutoff/timeline participation.
    static func parseExportDate(_ line: String) -> Date? {
        var cleaned = line.trimmingCharacters(in: .whitespaces)
        if let paren = cleaned.range(of: " (") {
            cleaned = String(cleaned[..<paren.lowerBound])
        }
        // Collapse runs of spaces so one format handles both spacings.
        cleaned = cleaned.split(separator: " ").joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy h:mm:ss a"
        return formatter.date(from: cleaned)
    }

    static func looksLikeDateLine(_ line: String) -> Bool {
        line.range(of: #"^[A-Z][a-z]{2} \d{1,2}, \d{4}"#,
                   options: .regularExpression) != nil
    }
}
