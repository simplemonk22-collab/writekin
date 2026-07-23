import Foundation
import GRDB

struct FilterPass {
    let db: AppDatabase
    var config: FilterConfig
    /// Per-medium (item `kind`) AI-contamination cutoff month, "YYYY-MM".
    /// Items of that kind authored on/after the first of that month are
    /// dropped with `past_cutoff`. Populated from `cutoff.<medium>` settings.
    var cutoffs: [String: String]

    init(db: AppDatabase, config: FilterConfig = FilterConfig(), cutoffs: [String: String] = [:]) {
        self.db = db
        self.config = config
        self.cutoffs = cutoffs
    }

    private static let boilerplateMarkers = [
        "this is an automatic reply", "out of office", "auto-reply",
        "invitation:", "accepted:", "declined:", "begin:vcalendar", ".ics"
    ]

    private static let gameSquares: Set<Character> = ["🟩","🟨","🟥","🟦","🟪","🟧","⬜","⬛","🟫","🟢","🟡","🔴","🔵","🟣","🟠","⚪","⚫"]
    private static let gameMarkers = [
        "wordle", "connections\npuzzle", "mini crossword in", "bracket city",
        "heardle", "immaculate grid", "daily dozen trivia",
    ]
    private static let gameScoreRegex = try! NSRegularExpression(pattern: #"#?\d+ \d+/\d+"#)

    /// Standalone-sufficient markers: a case-insensitive substring hit
    /// anywhere in the first 300 chars is enough on its own to call it a
    /// game share, no companion evidence required.
    private static let gameShareStrongMarkers = [
        "minute cryptic", "alphadots", "solvers so far", "community par",
        "semantle", "poople",
        // "<Game> #N" share templates: the literal "#" after the game name is
        // share-sheet boilerplate nobody types in prose, so no companion
        // emoji-grid/score evidence is needed (a Strands share whose grid is
        // all 🎆/🇺🇸 has no colored squares at all).
        "strands #", "pips #", "framed #", "#foximax", "connections puzzle #",
    ]
    /// "I solved" plus a named puzzle elsewhere in the text is a strong-enough
    /// pair to call it a game share (e.g. "I solved the ... Mini Crossword in 1:41!").
    private static let gameSharePairPuzzleWords = [
        "crossword", "wordle", "strands", "connections", "pips", "alphadots", "sudoku",
    ]

    /// Minimal projection of the columns filtering actually reads. `raw_text`
    /// is only ever used for its *length* (the quote-ratio denominator), so
    /// it's fetched as `LENGTH(raw_text)` — SQLite's LENGTH() counts Unicode
    /// scalars for text values — instead of dragging full message bodies
    /// through every batch.
    struct Candidate: Decodable, FetchableRecord, Sendable {
        var id: Int64
        var kind: String
        var externalId: String?
        var cleanText: String?
        var wordCount: Int?
        var lang: String?
        var authoredAt: Date?
        var rawTextLength: Int

        enum CodingKeys: String, CodingKey {
            case id, kind, lang
            case externalId = "external_id"
            case cleanText = "clean_text"
            case wordCount = "word_count"
            case authoredAt = "authored_at"
            case rawTextLength = "raw_text_length"
        }

        /// Adapter for full-record callers (tests): mirrors what the SQL
        /// projection fetches, including `LENGTH(raw_text)` semantics —
        /// SQLite counts Unicode scalars, so this does too.
        init(_ item: Item) {
            id = item.id ?? 0
            kind = item.kind
            externalId = item.externalId
            cleanText = item.cleanText
            wordCount = item.wordCount
            lang = item.lang
            authoredAt = item.authoredAt
            rawTextLength = item.rawText.unicodeScalars.count
        }
    }

    static let candidateSQL = """
        SELECT id, kind, external_id, clean_text, word_count, lang, authored_at,
               LENGTH(raw_text) AS raw_text_length
        FROM items WHERE state = 'ingested' LIMIT 500
        """

    func run(progress: @Sendable (Int) -> Void = { _ in },
             isCancelled: @Sendable () -> Bool = { false }) throws {
        var processed = 0
        while true {
            if isCancelled() { return }
            let batch = try db.writer.read { dbc in
                try Candidate.fetchAll(dbc, sql: Self.candidateSQL)
            }
            if batch.isEmpty { break }
            try db.writer.write { dbc in
                let update = try dbc.cachedStatement(sql: """
                    UPDATE items SET state = ?, drop_reason = ? WHERE id = ?
                    """)
                for candidate in batch {
                    if let reason = dropReason(for: candidate) {
                        try update.execute(arguments: ["filtered_out", reason, candidate.id])
                    } else {
                        try update.execute(arguments: ["kept", nil, candidate.id])
                    }
                }
            }
            processed += batch.count
            progress(processed)
        }
    }

    /// Full-record convenience overload; the pass itself runs on `Candidate`
    /// projections (see `run`).
    func dropReason(for item: Item) -> String? {
        dropReason(for: Candidate(item))
    }

    func dropReason(for item: Candidate) -> String? {
        let clean = item.cleanText ?? ""
        if config.gameShareEnabled, Self.isGameShare(clean) { return "game_share" }
        // Messages renders tapbacks from some devices as literal text
        // ("Reacted 😭 to “their message…”") — the quoted part is the *other*
        // person's message and none of it is the user's prose.
        if item.kind == "sms", clean.hasPrefix("Reacted "),
           clean.contains(" to “") {
            return "boilerplate"
        }
        if item.kind == "doc", Self.isFormDocument(externalId: item.externalId, cleanText: clean) {
            return "form_document"
        }
        // AI-chat prompts: a prompt that's mostly code is the machine's
        // language, not the author's voice, and a very long prompt is
        // almost always a paste (logs, crash reports, someone else's text)
        // rather than composed writing.
        if item.kind == "chat" {
            if Self.containsCode(clean) { return "code_content" }
            if (item.wordCount ?? 0) > 300 { return "likely_paste" }
        }
        if let cutoffMonth = cutoffs[item.kind], let authoredAt = item.authoredAt,
           let cutoffDate = Self.firstOfMonthUTC(cutoffMonth), authoredAt >= cutoffDate {
            return "past_cutoff"
        }
        let words = item.wordCount ?? 0
        let minWords = (item.kind == "sms" || item.kind == "chat")
            ? config.minWordsChat : config.minWordsEmailDoc
        if words < minWords { return "too_short" }
        if let required = config.requiredLang, let lang = item.lang, lang != required {
            return "non_english"
        }
        if item.kind == "email", item.rawTextLength > 0 {
            // Numerator and denominator both count Unicode scalars: the
            // denominator comes from SQLite's LENGTH(raw_text) (scalar count),
            // so the numerator matches units instead of counting grapheme
            // clusters. Identical for ASCII text; consistent for emoji.
            let ratio = Double(clean.unicodeScalars.count) / Double(item.rawTextLength)
            if ratio < config.quoteRatioFloor { return "quote_dominated" }
        }
        let tokens = clean.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        if !tokens.isEmpty {
            let urlTokens = tokens.filter {
                $0.hasPrefix("http://") || $0.hasPrefix("https://") || $0.hasPrefix("www.")
            }
            if Double(urlTokens.count) / Double(tokens.count) > config.urlTokenRatioCeiling {
                return "url_dominated"
            }
        }
        // Check for boilerplate markers in the first 300 characters (case-insensitive)
        let firstChars = String(clean.prefix(300)).lowercased()
        if Self.boilerplateMarkers.contains(where: firstChars.contains) {
            return "boilerplate"
        }

        // Special handling for "unsubscribe": only mark as boilerplate if in first 300 chars
        // AND the message is short (word count < 60)
        if firstChars.contains("unsubscribe") && words < 60 {
            return "boilerplate"
        }

        return nil
    }

    /// Parses a "YYYY-MM" cutoff month into the UTC instant of that month's
    /// first day at midnight, so `authoredAt >= cutoffDate` matches every
    /// item authored during or after the cutoff month. Returns nil for a
    /// malformed month string rather than throwing — an unparseable cutoff
    /// simply never matches.
    private static func firstOfMonthUTC(_ month: String) -> Date? {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let mon = Int(parts[1]),
              mon >= 1, mon <= 12 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year
        components.month = mon
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        return calendar.date(from: components)
    }

    /// Form, legal, and financial documents: NDAs, tax forms (1099, W-2, W-9), receipts,
    /// invoices, purchase orders, statements of work, tax returns, lease agreements.
    /// Detected via filename tokens/substrings or content markers in first 500 chars.
    private static func isFormDocument(externalId: String?, cleanText: String) -> Bool {
        // Check filename (last path component, lowercased)
        if let filename = extractFilename(externalId) {
            if filenameMatchesFormMarker(filename) {
                return true
            }
        }

        // Check content markers in first 500 chars
        let firstFiveHundred = String(cleanText.prefix(500)).lowercased()
        return contentMatchesFormMarker(firstFiveHundred)
    }

    /// Extract the filename (last path component) from externalId, handling both
    /// URI schemes and plain paths. Returns nil for empty/invalid externalId.
    private static func extractFilename(_ externalId: String?) -> String? {
        guard let id = externalId, !id.isEmpty else { return nil }
        // Use NSString's lastPathComponent to extract the filename
        return (id as NSString).lastPathComponent.lowercased()
    }

    /// Check if filename contains any form document markers.
    /// Short markers (nda, 1099, w2, w2form, w9, w9form, 401k, paystub) are matched as tokens.
    /// Long markers are substring matches that handle underscores/dashes/spaces as separators.
    private static func filenameMatchesFormMarker(_ filename: String) -> Bool {
        // Check long substring markers with flexible separators (underscore, dash, space all equivalent)
        let longMarkers = [
            "non.disclosure", "receipt", "invoice",
            "purchase.order", "statement.of.work", "tax.return", "lease.agreement",
            "confidentiality.agreement", "arbitration", "paystub", "pay.stub", "payslip",
            "offer.letter", "benefits.summary"
        ]
        // Normalize: replace all separators (spaces, underscores, dashes) with a single character
        let normalizedFilename = filename
            .replacingOccurrences(of: " ", with: ".")
            .replacingOccurrences(of: "_", with: ".")
            .replacingOccurrences(of: "-", with: ".")
        for marker in longMarkers {
            if normalizedFilename.contains(marker) { return true }
        }

        // Check short token markers by splitting on non-alphanumerics
        let shortTokens = ["nda", "1099", "w2", "w9", "w2form", "w9form", "401k", "paystub"]
        let fileTokens = filename.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        for token in fileTokens {
            if shortTokens.contains(token) { return true }
        }

        // Also check for W2/W9 as consecutive separate tokens (e.g., "Employee_W-2" → ["employee", "w", "2"])
        for i in 0..<(fileTokens.count - 1) {
            if fileTokens[i] == "w" && (fileTokens[i + 1] == "2" || fileTokens[i + 1] == "9") {
                return true
            }
        }

        return false
    }

    /// Check if content contains form document markers in the first 500 chars.
    /// Markers must appear at the start or in a specific phrase context.
    private static func contentMatchesFormMarker(_ firstFiveHundred: String) -> Bool {
        let markers = [
            "this mutual non-disclosure agreement",
            "this non-disclosure agreement",
            "form 1099",
            "receipt #",
            "invoice #",
            "invoice number",
            "amount due",
            "this agreement is entered into",
            "this confidentiality agreement",
            "binding arbitration",
            "401(k)",
            "earnings statement",
            "direct deposit",
            "gross pay",
            "net pay"
        ]

        for marker in markers {
            if firstFiveHundred.contains(marker) { return true }
        }

        return false
    }

    /// Puzzle-share texts (Wordle/Connections/Strands/NYT Mini/Bracket City/Pips/FoxiMax etc.)
    /// are emoji grids + boilerplate — not the user's voice. Checked before too_short so
    /// short shares (which are common) still get classified accurately.
    private static func isGameShare(_ cleanText: String) -> Bool {
        let squareCount = cleanText.reduce(into: 0) { count, char in
            if gameSquares.contains(char) { count += 1 }
        }
        if squareCount >= 6 { return true }
        let lowered = cleanText.lowercased()
        let firstChars = String(lowered.prefix(300))
        if gameShareStrongMarkers.contains(where: firstChars.contains) { return true }
        if lowered.contains("i solved"),
           gameSharePairPuzzleWords.contains(where: lowered.contains) {
            return true
        }
        guard gameMarkers.contains(where: lowered.contains) else { return false }
        if squareCount >= 1 { return true }
        let range = NSRange(cleanText.startIndex..<cleanText.endIndex, in: cleanText)
        return gameScoreRegex.firstMatch(in: cleanText, range: range) != nil
    }

    /// Code detection for AI-chat prompts: a fence anywhere is decisive;
    /// otherwise a meaningful share of tokens carrying code punctuation
    /// (braces, semicolons, arrows, paths ending in code extensions) in a
    /// message of real length. Prose brushing past a symbol or two never
    /// trips it.
    static func containsCode(_ text: String) -> Bool {
        if text.contains("```") { return true }
        let tokens = text.split { $0.isWhitespace }
        guard tokens.count >= 12 else { return false }
        let codey = tokens.filter { token in
            token.contains("{") || token.contains("}") || token.contains(");")
                || token.contains("();") || token.hasSuffix(";")
                || token.contains("->") || token.contains("=>")
                || token.contains("</") || token.contains("==")
        }.count
        return Double(codey) / Double(tokens.count) > 0.08
    }

    /// Undo filter-pass decisions (kept + pass-applied drops) so a re-tuned
    /// config can re-run. Insert-time drops are never touched.
    func resetFilterDecisions() throws {
        let passReasons = ["too_short", "non_english", "quote_dominated",
                           "url_dominated", "boilerplate", "near_duplicate", "game_share",
                           "past_cutoff", "form_document", "code_content", "likely_paste"]
        try db.writer.write { dbc in
            try dbc.execute(sql: """
                UPDATE items SET state = 'ingested', drop_reason = NULL, simhash64 = NULL
                WHERE state = 'kept'
                   OR (state = 'filtered_out' AND drop_reason IN (\(passReasons
                        .map { "'\($0)'" }.joined(separator: ","))))
                """)
            // Clear "model_failed" markers too (ONLY those — real model and
            // manual labels are untouched): Re-apply Filters is the explicit
            // retry path for items the labeler couldn't classify, instead of
            // silent re-attempts on every ingest.
            try dbc.execute(sql: """
                UPDATE items SET label_source = NULL
                WHERE label_source = 'model_failed' AND mode IS NULL
                """)
        }
    }
}
