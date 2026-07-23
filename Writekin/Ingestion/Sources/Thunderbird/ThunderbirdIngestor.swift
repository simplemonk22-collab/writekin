import Foundation

protocol SourceIngestor: Sendable {
    static var kind: SourceKind { get }
    func ingest(into writer: CorpusWriter,
                progress: @Sendable (IngestProgress) -> Void) async throws
}

struct ThunderbirdIngestor: SourceIngestor {
    static let kind = SourceKind.thunderbird

    var thunderbirdRoot: URL
    var writer: CorpusWriter

    init(thunderbirdRoot: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Thunderbird"),
         writer: CorpusWriter) {
        self.thunderbirdRoot = thunderbirdRoot
        self.writer = writer
    }

    func ingest(into writer: CorpusWriter,
                progress: @Sendable (IngestProgress) -> Void) async throws {
        let sourceID = try await writer.sourceID(for: Self.kind)
        var tally = IngestProgress(phase: .readingThunderbirdMailboxes)
        progress(tally)
        let ini = thunderbirdRoot.appendingPathComponent("profiles.ini")
        guard let iniText = try? String(contentsOf: ini, encoding: .utf8) else { return }

        for profile in ThunderbirdAdapter.profilePaths(fromINI: iniText, root: thunderbirdRoot) {
            for sub in ["ImapMail", "Mail"] {
                let subdir = profile.appendingPathComponent(sub)
                let servers = (try? FileManager.default.contentsOfDirectory(
                    at: subdir, includingPropertiesForKeys: nil)) ?? []
                for server in servers where server.hasDirectoryPath {
                    for mbox in ThunderbirdAdapter.sentMboxFiles(under: server,
                                                                 sentNames: ThunderbirdAdapter.localizedSentMailboxNames) {
                        try await ingest(mbox: mbox, sourceID: sourceID,
                                         writer: writer, tally: &tally, progress: progress)
                    }
                }
            }
        }
        try await writer.markSynced(sourceID: sourceID)
        progress(tally)
    }

    private func ingest(mbox: URL, sourceID: Int64,
                        writer: CorpusWriter,
                        tally: inout IngestProgress,
                        progress: @Sendable (IngestProgress) -> Void) async throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: mbox.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let mtimeEpoch = Int(((attrs?[.modificationDate] as? Date)
            ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970)
        let fingerprint = "\(size):\(mtimeEpoch)"

        // Unmodified since a previous full pass: the user's real Sent Mail
        // mboxes can be gigabytes and haven't changed since 2014 — re-parsing
        // them every "Ingest All" purely to dedupe-skip every message is a
        // real time sink. Skip the whole file with one stat() comparison.
        if let stored = try? await writer.fileFingerprint(path: mbox.path), stored == fingerprint {
            tally.skippedFiles += 1
            tally.phase = .upToDate(mbox.lastPathComponent)
            progress(tally)
            return
        }

        var index = 0
        var totalProcessed = 0
        tally.phase = .reading(mbox.lastPathComponent)
        progress(tally)
        // Buffered batch writes (one transaction per chunk) + a per-address
        // account cache — the per-message write and accountID round-trips
        // dominated changed-mbox re-parses.
        var accountCache: [String: Int64?] = [:]
        var buffer: [(raw: RawItem, accountID: Int64?)] = []
        try await MboxReader(url: mbox).forEachMessageAsync { rfc822 in
            try Task.checkCancellation()
            index += 1
            totalProcessed += 1
            let parsed = MailMessageParser.parse(rfc822)
            guard let text = parsed.textBody else {
                tally.unparseable += 1
                let raw = RawItem(
                    externalID: "\(mbox.lastPathComponent)#\(index)",
                    kind: .email,
                    authoredAt: parsed.date,
                    authoredAtConfidence: parsed.date != nil ? .embedded : nil,
                    accountHint: parsed.from.first,
                    recipients: parsed.to + parsed.cc,
                    threadID: parsed.inReplyTo ?? parsed.references.first,
                    rawText: "")
                try await writer.writeDropped(raw, sourceID: sourceID, accountID: nil,
                                              dropReason: "unparseable")
                return
            }
            let raw = RawItem(
                externalID: parsed.messageID ?? "\(mbox.lastPathComponent)#\(index)",
                kind: .email,
                authoredAt: parsed.date,
                authoredAtConfidence: parsed.date != nil ? .embedded : nil,
                accountHint: parsed.from.first,
                recipients: parsed.to + parsed.cc,
                threadID: parsed.inReplyTo ?? parsed.references.first,
                rawText: text)

            // A message whose From header didn't parse has no reliable
            // identity — falling back to the server directory name (e.g.
            // "imap.googlemail.com") used to invent a bogus account. Land
            // it with no account instead; it can be attributed via merge
            // later if the user recognizes it.
            let accountID: Int64?
            if let hint = raw.accountHint {
                if let cached = accountCache[hint] {
                    accountID = cached
                } else {
                    accountID = try await writer.accountID(for: hint)
                    accountCache[hint] = accountID
                }
            } else {
                accountID = nil
            }
            buffer.append((raw, accountID))
            if buffer.count >= 250 {
                let results = try await writer.writeBatch(
                    buffer.map(\.raw), sourceID: sourceID,
                    accountIDs: buffer.map(\.accountID))
                for result in results {
                    if case .inserted = result { tally.itemsLanded += 1 }
                    else { tally.skipped += 1 }
                }
                buffer.removeAll(keepingCapacity: true)
                progress(tally)
            }
        }
        if !buffer.isEmpty {
            let results = try await writer.writeBatch(
                buffer.map(\.raw), sourceID: sourceID,
                accountIDs: buffer.map(\.accountID))
            for result in results {
                if case .inserted = result { tally.itemsLanded += 1 }
                else { tally.skipped += 1 }
            }
            progress(tally)
        }

        // Only recorded after the mbox is fully processed without
        // cancellation (a thrown CancellationError above skips this line,
        // so a cancelled run re-reads the file next time).
        try await writer.setFileFingerprint(path: mbox.path, size: size, mtimeEpoch: mtimeEpoch)
    }
}
