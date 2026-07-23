import Foundation

struct AppleMailIngestor: SourceIngestor {
    static let kind = SourceKind.appleMail

    var mailRoot: URL
    var writer: CorpusWriter

    init(mailRoot: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mail"),
         writer: CorpusWriter) {
        self.mailRoot = mailRoot
        self.writer = writer
    }

    func ingest(into writer: CorpusWriter,
                progress: @Sendable (IngestProgress) -> Void) async throws {
        let fm = FileManager.default
        let sourceID = try await writer.sourceID(for: Self.kind)
        var tally = IngestProgress(phase: .readingAppleMail)
        progress(tally)
        // Probe the mail root first so an FDA denial is distinguishable from
        // "no Mail data" — without probing, contentsOfDirectory's `try?` below
        // silently returns empty and ingest looks like a no-op success.
        let rootContents: [URL]
        do {
            rootContents = try fm.contentsOfDirectory(at: mailRoot,
                                                       includingPropertiesForKeys: nil)
        } catch {
            if isPermissionDenied(error) { throw DetectError.permissionDenied }
            rootContents = []
        }
        let versionDirs = rootContents
            .filter { $0.lastPathComponent.hasPrefix("V") && $0.hasDirectoryPath }
        for versionDir in versionDirs {
            let accountDirs = (try? fm.contentsOfDirectory(
                at: versionDir, includingPropertiesForKeys: nil)) ?? []
            for accountDir in accountDirs where accountDir.hasDirectoryPath {
                let sentFiles = AppleMailAdapter.sentMailboxes(under: accountDir)
                    .flatMap { AppleMailAdapter.emlxFiles(in: $0) }
                if !sentFiles.isEmpty {
                    // Whole-mailbox skip: emlx files are immutable once
                    // written, so an unchanged file LISTING (which the
                    // enumeration above produced anyway) means an unchanged
                    // mailbox — skip without opening a single file. This is
                    // what kills the re-ingest cost: the per-message known-ID
                    // check below still opens every file for headers.
                    let fingerprint = Self.fileListFingerprint(sentFiles)
                    let fingerprintPath = accountDir.path + "#sent"
                    if let stored = try? await writer.fileFingerprint(path: fingerprintPath),
                       stored == fingerprint {
                        tally.skippedFiles += 1
                        tally.phase = .upToDate(accountDir.lastPathComponent)
                        progress(tally)
                        continue
                    }
                    tally.phase = .reading(accountDir.lastPathComponent)
                    progress(tally)
                    try await ingestEmlxFiles(sentFiles, ownAddresses: nil,
                                              sourceID: sourceID, writer: writer,
                                              tally: &tally, progress: progress)
                    // Only after a full uncancelled pass (a cancel throws
                    // past this line), mirroring the mbox fingerprints.
                    try await writer.setFileFingerprint(path: fingerprintPath,
                                                        value: fingerprint)
                    continue
                }
                let allMailFiles = AppleMailAdapter
                    .mailboxes(matching: AppleMailAdapter.localizedAllMailNames, under: accountDir)
                    .flatMap { AppleMailAdapter.emlxFiles(in: $0, includingPartial: true) }
                guard !allMailFiles.isEmpty else { continue }
                // Checked BEFORE ownAddresses(forAllMailFiles:), which reads
                // headers — an unchanged All Mail must cost zero file opens.
                // This matters double here: most All Mail messages are other
                // people's, invisible to the known-ID set, so without this
                // every re-ingest paid a header read per foreign message.
                let fingerprint = Self.fileListFingerprint(allMailFiles)
                let fingerprintPath = accountDir.path + "#allmail"
                if let stored = try? await writer.fileFingerprint(path: fingerprintPath),
                   stored == fingerprint {
                    tally.skippedFiles += 1
                    tally.phase = .upToDate(accountDir.lastPathComponent)
                    progress(tally)
                    continue
                }
                let own = AppleMailAdapter.ownAddresses(forAllMailFiles: allMailFiles)
                guard !own.isEmpty else { continue }
                try await writer.setOwnAddresses(Array(own).sorted(),
                                                 accountHint: own.sorted()[0])
                tally.phase = .scanningAllMail
                progress(tally)
                try await ingestEmlxFiles(allMailFiles, ownAddresses: own,
                                          sourceID: sourceID, writer: writer,
                                          tally: &tally, progress: progress)
                try await writer.setFileFingerprint(path: fingerprintPath,
                                                    value: fingerprint)
            }
        }
        try await writer.markSynced(sourceID: sourceID)
        progress(tally)
    }

    /// Buffered writes flush this many items per batch (one transaction
    /// each, via `CorpusWriter.writeBatch`).
    static let writeChunkSize = 250

    /// Files handed to the parallel parse stage per round — bounds memory
    /// (at most this many parsed messages in flight) and sets the progress
    /// cadence.
    static let parseChunkSize = 500

    /// Parse workers per chunk. Half the cores: parsing is CPU+IO mixed,
    /// and the serial writer + the rest of the app still need headroom —
    /// this is a background nicety, not a benchmark.
    static var parseWorkers: Int {
        max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    /// What the parallel stage decided about one emlx file. Everything the
    /// serial stage needs (tally bumps, writer calls) rides in the case —
    /// workers never touch the writer or the tally.
    enum ParseOutcome: Sendable {
        /// Not the user's message (own-address filter) — no tally movement.
        case foreign
        /// Already in the corpus (known external-ID skip).
        case known
        case unparseable
        /// Headers parsed but no text body — recorded as a dropped item.
        case noBody(RawItem, from: String?)
        case parsed(RawItem, from: String?)
    }

    /// Fingerprint of a mailbox's file listing: count + hash of the sorted
    /// paths. Emlx files are immutable once written, so new/removed FILES
    /// are the only way a mailbox's ingestable content changes — content
    /// never needs to be read to decide "unchanged". Pure, exposed for
    /// tests.
    static func fileListFingerprint(_ files: [URL]) -> String {
        "\(files.count):" + sha256Hex(files.map(\.path).sorted().joined(separator: "\n"))
    }

    /// ownAddresses == nil means "a real Sent mailbox — everything is sent".
    ///
    /// Two-stage pipeline (packaging plan Task 8): the per-file work —
    /// header reads, own-address filtering, known-ID checks, the full MIME
    /// parse — is pure and runs on `parseWorkers` TaskGroup workers a chunk
    /// at a time; the writer interaction (account resolution, batch writes,
    /// dropped records) stays serial in this parent, so tallies and write
    /// ordering behave exactly as the serial version did.
    private func ingestEmlxFiles(_ files: [URL], ownAddresses: Set<String>?,
                                 sourceID: Int64, writer: CorpusWriter,
                                 tally: inout IngestProgress,
                                 progress: @Sendable (IngestProgress) -> Void) async throws {
        // Everything this source already has, fetched once — lets workers
        // skip known messages on a header-only read, before the full MIME
        // parse and the per-item write round-trip. This is what makes a
        // re-ingest fast: nearly every file short-circuits here.
        let known = try await writer.knownExternalIDs(sourceID: sourceID)
        // From-address → account id, resolved once per address instead of
        // one actor round-trip per message.
        var accountCache: [String: Int64?] = [:]
        var buffer: [(raw: RawItem, accountID: Int64?)] = []

        func flush() async throws {
            guard !buffer.isEmpty else { return }
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

        func resolveAccount(_ from: String?) async throws -> Int64? {
            guard let from else { return nil }
            if let cached = accountCache[from] { return cached }
            let accountID = try await writer.accountID(for: from)
            accountCache[from] = accountID
            return accountID
        }

        var index = 0
        while index < files.count {
            try Task.checkCancellation()
            let upper = min(index + Self.parseChunkSize, files.count)
            let chunk = Array(files[index..<upper])
            index = upper
            let outcomes = try await Self.parseChunk(
                chunk, ownAddresses: ownAddresses, known: known)
            for outcome in outcomes {
                switch outcome {
                case .foreign:
                    break
                case .known:
                    tally.skipped += 1
                case .unparseable:
                    tally.unparseable += 1
                case .noBody(let raw, let from):
                    try await writer.writeDropped(raw, sourceID: sourceID,
                                                  accountID: try await resolveAccount(from),
                                                  dropReason: "body_not_downloaded")
                    tally.skipped += 1
                case .parsed(let raw, let from):
                    buffer.append((raw, try await resolveAccount(from)))
                    if buffer.count >= Self.writeChunkSize { try await flush() }
                }
            }
            // Fires even for chunks that were all header-only skips — those
            // are still work, and a write-based cadence alone would never
            // show progress during a long run of foreign/known messages.
            progress(tally)
        }
        try await flush()
    }

    /// Parses one chunk on up to `parseWorkers` concurrent workers, each
    /// taking a contiguous slice. Results come back in file order (slices
    /// reassembled by index) so downstream behavior is deterministic.
    static func parseChunk(_ urls: [URL], ownAddresses: Set<String>?,
                           known: Set<String>) async throws -> [ParseOutcome] {
        guard !urls.isEmpty else { return [] }
        let workers = min(parseWorkers, urls.count)
        let sliceSize = (urls.count + workers - 1) / workers
        let slices = stride(from: 0, to: urls.count, by: sliceSize).map {
            Array(urls[$0..<min($0 + sliceSize, urls.count)])
        }
        return try await withThrowingTaskGroup(of: (Int, [ParseOutcome]).self) { group in
            for (sliceIndex, slice) in slices.enumerated() {
                group.addTask {
                    var outcomes: [ParseOutcome] = []
                    outcomes.reserveCapacity(slice.count)
                    for url in slice {
                        try Task.checkCancellation()
                        outcomes.append(Self.parseFile(url, ownAddresses: ownAddresses,
                                                       known: known))
                    }
                    return (sliceIndex, outcomes)
                }
            }
            var collected = [[ParseOutcome]](repeating: [], count: slices.count)
            for try await (sliceIndex, outcomes) in group {
                collected[sliceIndex] = outcomes
            }
            return collected.flatMap { $0 }
        }
    }

    /// The pure per-file stage — no writer, no tally. Same decision order
    /// as the old serial loop: cheap header-only checks first (own-address
    /// filter, known-ID skip), full MIME parse only for survivors.
    static func parseFile(_ url: URL, ownAddresses: Set<String>?,
                          known: Set<String>) -> ParseOutcome {
        var headers: [String: String]?
        if let own = ownAddresses {
            // All Mail carries every hop of the thread (incl. others'
            // replies), so most messages here aren't ours — skip foreign
            // messages without paying for a full MIME parse.
            headers = AppleMailAdapter.headerValues(at: url)
            let from = AppleMailAdapter.emailAddresses(in: headers?["from"] ?? "")
            if own.isDisjoint(with: from) { return .foreign }
        }
        if !known.isEmpty {
            // Known-message skip on the header-only Message-ID (falling
            // back to the filename, the same identity write() records).
            // A header/parser normalization mismatch only costs the
            // shortcut — the write-side dedupe still catches the item.
            let h = headers ?? AppleMailAdapter.headerValues(at: url)
            let headerID = h["message-id"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if known.contains(headerID ?? url.lastPathComponent) { return .known }
        }
        guard let rfc822 = EmlxFile.rfc822Content(of: url) else { return .unparseable }
        let parsed = MailMessageParser.parse(rfc822)
        if let own = ownAddresses, own.isDisjoint(with: parsed.from) { return .foreign }
        let raw = RawItem(
            externalID: parsed.messageID ?? url.lastPathComponent, kind: .email,
            authoredAt: parsed.date,
            authoredAtConfidence: parsed.date != nil ? .embedded : nil,
            accountHint: parsed.from.first,
            recipients: parsed.to + parsed.cc,
            threadID: parsed.inReplyTo ?? parsed.references.first,
            rawText: parsed.textBody ?? "")
        if parsed.textBody == nil { return .noBody(raw, from: parsed.from.first) }
        return .parsed(raw, from: parsed.from.first)
    }
}
