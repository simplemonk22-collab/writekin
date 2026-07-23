import Foundation
import GRDB
import NaturalLanguage

struct CleanPass {
    /// Version of the sms cleaning rules (`AttachmentPathLine` stripping).
    /// Bump whenever those rules change: Re-apply Filters compares this
    /// against the `clean.sms.version` setting and force-re-cleans every
    /// resettable sms once when they differ, so rule improvements reach
    /// texts already on disk — not just future ingests.
    static let smsCleanerVersion = 3

    /// Version of the email cleaning rules (mbox-bleed truncation, stray
    /// header-line stripping, MIME plumbing stripping, device/app signature
    /// footer stripping) in `MailTextCleaner`.
    /// Bump whenever those rules change: Re-apply Filters compares this
    /// against the `clean.email.version` setting and force-re-cleans every
    /// resettable email once when they differ, mirroring `smsCleanerVersion`.
    static let emailCleanerVersion = 6

    /// Version of the doc cleaning rules (`MarkdownStripper` application) in
    /// the doc branch below. Bump whenever those rules change: Re-apply
    /// Filters compares this against the `clean.doc.version` setting and
    /// force-re-cleans every resettable doc once when they differ, mirroring
    /// `smsCleanerVersion`/`emailCleanerVersion`.
    static let docCleanerVersion = 3

    /// Markdown filename extensions, mirroring `DocumentTextExtractor`'s
    /// recognized markdown extensions — used to decide whether a `doc`
    /// item's raw text is markdown source that needs `MarkdownStripper`.
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown"]

    let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    /// Minimal projection of the columns cleaning actually reads, so each
    /// 500-row batch doesn't drag every column (clean_text, recipients,
    /// context_text, ...) through the row cache. `lang` rides along solely
    /// to decide whether language detection is needed: a version-heal
    /// re-clean preserves the item's previously detected language.
    struct Candidate: Decodable, FetchableRecord, Sendable {
        var id: Int64
        var kind: String
        var externalId: String?
        var rawText: String
        var lang: String?

        enum CodingKeys: String, CodingKey {
            case id, kind, lang
            case externalId = "external_id"
            case rawText = "raw_text"
        }
    }

    /// The computed, immutable output of the CPU-only cleaning phase for one
    /// candidate — everything except language detection, which is serial
    /// (NLLanguageRecognizer is not Sendable-safe).
    private struct CleanOutput: Sendable {
        var cleanText: String
        var wordCount: Int
    }

    /// `@unchecked Sendable` shuttle for the results buffer: each
    /// `concurrentPerform` iteration writes only its own index, so the
    /// distinct-slot writes never race.
    private struct ResultSlots: @unchecked Sendable {
        let base: UnsafeMutableBufferPointer<CleanOutput?>
    }

    /// Pure clean-text derivation for one item: no database access, no shared
    /// mutable state — safe to run concurrently across a batch.
    static func cleanedText(kind: String, externalId: String?, rawText: String) -> String {
        if kind == "email" {
            return MailTextCleaner.clean(rawText)
        }
        var strippedRaw = kind == "sms"
            ? rawText.components(separatedBy: "\n")
                .filter { !AttachmentPathLine.matches($0) }
                .joined(separator: "\n")
            : rawText
        // Markdown source's syntax (headings, emphasis
        // markers, list bullets, links, tables, ...) isn't
        // voice — strip it to prose before the whitespace
        // collapse below. `raw_text` keeps the original
        // markdown so re-clean can always redo this.
        if kind == "doc",
           let externalId,
           Self.markdownExtensions.contains(
               (externalId as NSString).pathExtension.lowercased()) {
            strippedRaw = MarkdownStripper.strip(strippedRaw)
        }
        return strippedRaw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Compute phase: cleaned text + word count for the whole batch in
    /// parallel. Pure CPU work on immutable inputs; results land in
    /// distinct slots of a preallocated buffer.
    private static func computeOutputs(for batch: [Candidate]) -> [CleanOutput] {
        var results = [CleanOutput?](repeating: nil, count: batch.count)
        results.withUnsafeMutableBufferPointer { buffer in
            let slots = ResultSlots(base: buffer)
            DispatchQueue.concurrentPerform(iterations: batch.count) { i in
                let candidate = batch[i]
                let cleaned = cleanedText(kind: candidate.kind,
                                          externalId: candidate.externalId,
                                          rawText: candidate.rawText)
                let words = cleaned
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }.count
                slots.base[i] = CleanOutput(cleanText: cleaned, wordCount: words)
            }
        }
        return results.map { $0! }
    }

    func run(progress: @Sendable (Int) -> Void = { _ in },
             isCancelled: @Sendable () -> Bool = { false }) throws {
        var processed = 0
        while true {
            if isCancelled() { return }
            let batch = try db.writer.read { dbc in
                try Candidate.fetchAll(dbc, sql: """
                    SELECT id, kind, external_id, raw_text, lang
                    FROM items
                    WHERE clean_text IS NULL AND state <> 'filtered_out'
                    LIMIT 500
                    """)
            }
            if batch.isEmpty { break }
            let outputs = Self.computeOutputs(for: batch)
            try db.writer.write { dbc in
                // One recognizer per batch, reset between items — creating a
                // fresh NLLanguageRecognizer per item is measurably expensive.
                // Language detection stays in this serial write phase because
                // NLLanguageRecognizer is not Sendable-safe.
                let recognizer = NLLanguageRecognizer()
                let withLang = try dbc.cachedStatement(sql: """
                    UPDATE items SET clean_text = ?, word_count = ?, lang = ? WHERE id = ?
                    """)
                let withoutLang = try dbc.cachedStatement(sql: """
                    UPDATE items SET clean_text = ?, word_count = ? WHERE id = ?
                    """)
                for (candidate, output) in zip(batch, outputs) {
                    if candidate.lang == nil {
                        recognizer.reset()
                        recognizer.processString(output.cleanText)
                        let lang = recognizer.dominantLanguage?.rawValue
                        try withLang.execute(
                            arguments: [output.cleanText, output.wordCount, lang, candidate.id])
                    } else {
                        // Re-cleans (version heals) preserve the previously
                        // detected language: cleaning doesn't change what
                        // language an item is written in.
                        try withoutLang.execute(
                            arguments: [output.cleanText, output.wordCount, candidate.id])
                    }
                }
            }
            processed += batch.count
            progress(processed)
        }
    }
}
