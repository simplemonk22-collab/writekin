import Foundation

struct DocumentIngestor: SourceIngestor {
    static let kind = SourceKind.fileSystem

    var roots: [URL]?
    var writer: CorpusWriter

    init(roots: [URL]? = nil, writer: CorpusWriter) {
        self.roots = roots
        self.writer = writer
    }

    func ingest(into writer: CorpusWriter,
                progress: @Sendable (IngestProgress) -> Void) async throws {
        let sourceID = try await writer.sourceID(for: Self.kind)
        var tally = IngestProgress(phase: .readingDocuments)
        progress(tally)
        // Settings › Sources › Documents type toggles: disabled formats are
        // skipped outright — not enumerated, not recorded as drops.
        let disabledTypes = await DocumentTypeStore.disabledTypeIDs(settings: writer.settingsStore)
        let allowedExtensions = DocumentTypeStore.allowedExtensions(disabledTypeIDs: disabledTypes)
        let searchRoots = roots ?? FileSystemAdapter().roots
        // Buffered batch writes — one transaction per chunk instead of one
        // per document; each flushed file's size:mtime fingerprint is
        // recorded in the same breath so the NEXT ingest can skip it before
        // extraction ever runs. Fingerprints land only after their items'
        // write succeeds, so a cancelled run re-examines those files.
        var buffer: [RawItem] = []
        var bufferFingerprints: [(path: String, value: String)] = []
        func flush() async throws {
            guard !buffer.isEmpty else { return }
            // updateChanged: an edited document (same path, new content)
            // updates its row in place and re-enters the pass pipeline.
            for result in try await writer.writeBatch(buffer, sourceID: sourceID,
                                                      accountID: nil,
                                                      updateChanged: true) {
                switch result {
                case .inserted, .updated: tally.itemsLanded += 1
                default: tally.skipped += 1
                }
            }
            try await writer.setFileFingerprints(bufferFingerprints)
            buffer.removeAll(keepingCapacity: true)
            bufferFingerprints.removeAll(keepingCapacity: true)
            progress(tally)
        }
        let fm = FileManager.default
        for root in searchRoots {
            tally.phase = .reading(root.lastPathComponent)
            progress(tally)
            // Serial pre-pass: the size:mtime fingerprint skip needs the
            // writer, and it's cheap — only files that actually need
            // extraction go on the work list for the parallel stage.
            var pending: [(url: URL, fingerprint: String)] = []
            for url in FileSystemAdapter.candidateFiles(under: root)
            where allowedExtensions.contains(url.pathExtension.lowercased()) {
                try Task.checkCancellation()
                // Pre-extraction skip: an unchanged file (same size + mtime
                // as when it was last fully processed) can't produce a new
                // outcome — extraction (the expensive part: PDFKit, rich-
                // text importers) is skipped entirely.
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? Int) ?? 0
                let mtimeEpoch = Int(((attrs?[.modificationDate] as? Date)
                    ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970)
                let fingerprint = "\(size):\(mtimeEpoch)"
                if let stored = try? await writer.fileFingerprint(path: url.path),
                   stored == fingerprint {
                    tally.skipped += 1
                    continue
                }
                pending.append((url, fingerprint))
            }
            // Parallel extraction (packaging plan Task 8), chunked so memory
            // stays bounded; the writer interaction below stays serial.
            var index = 0
            while index < pending.count {
                try Task.checkCancellation()
                let upper = min(index + Self.extractChunkSize, pending.count)
                let chunk = Array(pending[index..<upper])
                index = upper
                for outcome in try await Self.extractChunk(chunk) {
                    switch outcome {
                    case .formatUnsupported(let raw, let fingerprint):
                        try await writer.writeDropped(raw, sourceID: sourceID,
                                                      accountID: nil,
                                                      dropReason: "format_unsupported")
                        try await writer.setFileFingerprint(path: raw.externalID,
                                                            value: fingerprint)
                        tally.skipped += 1
                    case .unparseable(let raw, let fingerprint):
                        try await writer.writeDropped(raw, sourceID: sourceID,
                                                      accountID: nil,
                                                      dropReason: "unparseable")
                        // Recorded too: re-attempting a file that failed to
                        // parse only makes sense once it changes.
                        try await writer.setFileFingerprint(path: raw.externalID,
                                                            value: fingerprint)
                        tally.unparseable += 1
                    case .extracted(let raw, let fingerprint):
                        buffer.append(raw)
                        bufferFingerprints.append((raw.externalID, fingerprint))
                        if buffer.count >= 100 { try await flush() }
                    }
                }
                progress(tally)
            }
        }
        try await flush()
        try await writer.markSynced(sourceID: sourceID)
        progress(tally)
    }

    /// Files handed to the parallel extraction stage per round — bounds how
    /// many extracted documents sit in memory at once.
    static let extractChunkSize = 100

    /// Extraction workers per chunk — same sizing rationale as
    /// `AppleMailIngestor.parseWorkers`.
    static var extractWorkers: Int {
        max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    /// What the parallel stage decided about one document. The fingerprint
    /// rides along so the serial stage records it with the same timing the
    /// serial version had (dropped files immediately, kept files at flush).
    enum ExtractOutcome: Sendable {
        case formatUnsupported(RawItem, fingerprint: String)
        case unparseable(RawItem, fingerprint: String)
        case extracted(RawItem, fingerprint: String)
    }

    /// Extracts one chunk on up to `extractWorkers` concurrent workers,
    /// contiguous slices reassembled in order — no writer, no tally.
    static func extractChunk(
        _ items: [(url: URL, fingerprint: String)]
    ) async throws -> [ExtractOutcome] {
        guard !items.isEmpty else { return [] }
        let workers = min(extractWorkers, items.count)
        let sliceSize = (items.count + workers - 1) / workers
        let slices = stride(from: 0, to: items.count, by: sliceSize).map {
            Array(items[$0..<min($0 + sliceSize, items.count)])
        }
        return try await withThrowingTaskGroup(of: (Int, [ExtractOutcome]).self) { group in
            for (sliceIndex, slice) in slices.enumerated() {
                group.addTask {
                    var outcomes: [ExtractOutcome] = []
                    outcomes.reserveCapacity(slice.count)
                    for item in slice {
                        try Task.checkCancellation()
                        outcomes.append(Self.extract(url: item.url,
                                                     fingerprint: item.fingerprint))
                    }
                    return (sliceIndex, outcomes)
                }
            }
            var collected = [[ExtractOutcome]](repeating: [], count: slices.count)
            for try await (sliceIndex, outcomes) in group {
                collected[sliceIndex] = outcomes
            }
            return collected.flatMap { $0 }
        }
    }

    /// The pure per-file stage: authored-date sniff + text extraction.
    static func extract(url: URL, fingerprint: String) -> ExtractOutcome {
        let (date, confidence) = DocumentTextExtractor.authoredDate(of: url)
        var raw = RawItem(
            externalID: url.path, kind: .doc,
            authoredAt: date, authoredAtConfidence: confidence,
            accountHint: nil, recipients: [], threadID: nil, rawText: "")
        if url.pathExtension.lowercased() == "pages" {
            return .formatUnsupported(raw, fingerprint: fingerprint)
        }
        guard let text = DocumentTextExtractor.text(of: url), !text.isEmpty else {
            return .unparseable(raw, fingerprint: fingerprint)
        }
        raw.rawText = text
        return .extracted(raw, fingerprint: fingerprint)
    }
}
