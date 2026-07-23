import Foundation
import GRDB

/// Dimensions used to select the register (voice) an author writes in for a
/// given context. `medium` maps to `Item.kind` (email/sms/doc/chat);
/// `accountID` maps to `Item.accountId`.
struct RegisterQuery: Sendable, Equatable, Hashable {
    var medium: String?
    var audience: String?
    var mode: String?
    var accountID: Int64?
}

/// Aggregate writing-style statistics for a pool of kept items, plus a
/// compact human-readable summary for prompting a generation model.
struct StyleProfile: Sendable, Equatable {
    var itemCount: Int = 0
    var meanSentenceLen: Double = 0
    var sentenceLenSD: Double = 0
    var contractionRate: Double = 0
    var exclamationPer1k: Double = 0
    var emojiPer1k: Double = 0
    /// Mean characters per word — a cheap formality proxy ("utilize
    /// considerable" vs "use a lot" shows up here immediately).
    var meanWordLen: Double = 0
    var questionPer1k: Double = 0
    /// Dashes per 1k words — the classic LLM punctuation tell, only
    /// meaningful against the author's own baseline. Counts EVERY dash
    /// form as one habit (typographic —/–, plain-text "--" and " - "):
    /// a corpus check showed the author's dashes are overwhelmingly typed
    /// "--"/" - " while models emit "—" — counting only "—" mis-profiled
    /// a heavy dash user as rare. See `StyleProfiler.dashCount`.
    var emDashPer1k: Double = 0
    var topGreetings: [String] = []
    var topSignoffs: [String] = []
    var favoritePhrases: [String] = []

    /// Contraction-rate cutoffs for the "frequent"/"occasional"/"rare"
    /// bucketing used by both `promptBlock()` and `VoiceProfileContent` —
    /// pinned here as the single source of truth so the Voice Profile page's
    /// display never drifts out of sync with what actually steers generation.
    static let contractionFrequentThreshold = 0.15
    static let contractionOccasionalThreshold = 0.05

    /// The same "frequent"/"occasional"/"rare" bucket `promptBlock()` embeds
    /// in its prose, exposed standalone so callers (e.g. the inspector) can
    /// pair it with the raw percentage without duplicating the thresholds.
    static func contractionBucket(forRate rate: Double) -> String {
        if rate >= contractionFrequentThreshold {
            return "frequent"
        } else if rate >= contractionOccasionalThreshold {
            return "occasional"
        } else {
            return "rare"
        }
    }

    /// Deterministic, threshold-based prose block meant to be dropped into a
    /// generation prompt. Wording is intentionally simple and stable so it
    /// can be substring-matched by tests rather than compared verbatim.
    func promptBlock() -> String {
        guard itemCount > 0 else {
            return "No writing samples available for this register yet."
        }
        var lines: [String] = []

        let variability = (meanSentenceLen > 0 && sentenceLenSD / meanSentenceLen > 0.3)
            ? "varies widely" : "fairly consistent"
        lines.append("Average sentence: \(Int(meanSentenceLen.rounded())) words (\(variability)).")

        lines.append("Contractions: \(Self.contractionBucket(forRate: contractionRate)).")

        if exclamationPer1k > 20 {
            lines.append("Uses exclamation marks often.")
        }
        if emojiPer1k > 20 {
            lines.append("Uses emoji often.")
        }
        if !favoritePhrases.isEmpty {
            lines.append("Favorite phrases: \(favoritePhrases.prefix(4).joined(separator: ", ")).")
        }
        if let greeting = topGreetings.first {
            lines.append("Typical greeting: '\(greeting)'.")
        }
        if let signoff = topSignoffs.first {
            lines.append("Typical signoff: '\(signoff)'.")
        }
        return lines.joined(separator: " ")
    }
}

/// Thread-safe box for `StyleProfiler`'s per-query cache. `StyleProfiler`
/// itself is a value type so it can be freely passed around, but the cache
/// needs shared, lockable storage — mirrors the pattern used by
/// `CancelFlag` elsewhere in the app.
private final class ProfileCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RegisterQuery: StyleProfile] = [:]
    /// Corpus-wide n-gram counts + total, shared by every register's
    /// favorite-phrases lift computation. Building this walks (a sample of)
    /// the whole kept corpus, so it must not be redone per register.
    private var baseline: ([String: Int], Int)?

    func get(_ key: RegisterQuery) -> StyleProfile? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func set(_ value: StyleProfile, for key: RegisterQuery) {
        lock.lock(); storage[key] = value; lock.unlock()
    }

    func getBaseline() -> ([String: Int], Int)? {
        lock.lock(); defer { lock.unlock() }
        return baseline
    }

    func setBaseline(_ value: ([String: Int], Int)) {
        lock.lock(); baseline = value; lock.unlock()
    }

    func clear() {
        lock.lock(); storage.removeAll(); baseline = nil; lock.unlock()
    }
}

/// Computes ``StyleProfile``s describing how an author writes in a given
/// register (medium/audience/mode/account), so a generation prompt can be
/// steered toward their actual voice.
///
/// Definitions (chosen simply and pinned by tests, since the brief leaves
/// them open):
/// - A "sentence" is a run of text ending in `.`, `!`, or `?` (or the final
///   trailing text with no terminal punctuation).
/// - A "word" is a whitespace-delimited token.
/// - A contraction is a word matching `[A-Za-z]+['’][A-Za-z]+` (either apostrophe).
/// - `contractionRate` is contraction-words / total-words across the pool.
/// - `exclamationPer1k`/`emojiPer1k` are counts of `!` characters / emoji
///   scalars per 1,000 words across the pool.
/// - Greeting/signoff are only derived from `kind == "email"` items: the
///   first (resp. last) non-empty line of `cleanText`, lowercased, kept only
///   if it is <= 6 (resp. <= 5) words. The most frequent values are
///   reported.
/// - `favoritePhrases` are 2-3-grams (built from lowercased, punctuation-
///   stripped tokens) that appear at least 5 times in the query pool, are
///   less than 50% stopwords, and have the highest lift — (query frequency)
///   / (kept-corpus baseline frequency, computed once from a stride sample
///   and cached until `invalidateCache()`), each Laplace-smoothed by 1 so a
///   phrase's lift depends on its relative concentration rather than its
///   raw count.
struct StyleProfiler: Sendable {
    let db: AppDatabase
    private let cache = ProfileCache()

    /// Below this many matched items, the query is progressively relaxed
    /// (see ``matchedItems(_:query:)``) so the profile is computed from a
    /// statistically meaningful pool. Also the threshold Compose's UI uses
    /// (via `StyleProfile.itemCount`) to decide whether to warn that results
    /// may be generic for a thinly-represented register.
    static let minPoolSize = 30

    /// Stats are computed from at most this many items (evenly stride-
    /// sampled) per pool. On a real corpus the relaxation ladder can land on
    /// tens of thousands of items; profiling them all made the first Compose
    /// realize spin for many minutes, and a 2,000-item sample estimates the
    /// same rates. `StyleProfile.itemCount` still reports the full matched
    /// count — the thin-profile warning is about representation, not sample
    /// size. Sized so a debug (unoptimized) build still profiles in seconds:
    /// 2,000 was measurably still minutes of n-gram dictionary work there.
    static let statsSampleCap = 600

    /// Item-sample cap for EXPANDED phrase requests (the Voice tab's
    /// "Show 500+"): the 600-item default keeps every realize fast, but it
    /// also caps how many phrases can ever clear the 5-occurrence /
    /// 3-item bar (~77 on a real corpus). On-demand requests trade seconds
    /// for depth; still bounded so a huge corpus can't balloon the n-gram
    /// dictionary into hundreds of MB.
    static let expandedSampleCap = 5_000

    init(db: AppDatabase) {
        self.db = db
    }

    /// Drops all cached profiles. Callers should invalidate whenever the
    /// underlying `items` table changes (new ingest, relabeling, etc.).
    func invalidateCache() {
        cache.clear()
    }

    /// The default `favoritePhrases` cap — what the engine's prompt block
    /// and the compact profile views use. The Voice tab can request more
    /// via `phraseCap` (those requests bypass the profile cache, which only
    /// stores default-cap profiles).
    static let defaultPhraseCap = 50

    func profile(for query: RegisterQuery,
                 phraseCap: Int = StyleProfiler.defaultPhraseCap) async throws -> StyleProfile {
        if phraseCap == Self.defaultPhraseCap, let cached = cache.get(query) {
            return cached
        }
        let items = try await db.writer.read { dbc in
            try Self.matchedItems(dbc, query: query)
        }
        let baseline: ([String: Int], Int)
        if let cached = cache.getBaseline() {
            baseline = cached
        } else {
            let texts = try await db.writer.read { dbc in
                try String.fetchAll(dbc, sql: """
                    SELECT clean_text FROM items
                    WHERE state = 'kept' AND clean_text IS NOT NULL
                    ORDER BY id
                    """)
            }
            var counts: [String: Int] = [:]
            var total = 0
            for text in Self.sample(texts, cap: Self.statsSampleCap) where !text.isEmpty {
                for run in Self.tokenRuns(text) {
                    Self.countNGrams(run, into: &counts, total: &total)
                }
            }
            baseline = (counts, total)
            cache.setBaseline(baseline)
        }
        let built = Self.buildProfile(items: items,
                                       baselineCounts: baseline.0, baselineTotal: baseline.1,
                                       phraseCap: phraseCap,
                                       sampleCap: phraseCap > Self.defaultPhraseCap
                                           ? Self.expandedSampleCap : Self.statsSampleCap)
        if phraseCap == Self.defaultPhraseCap {
            cache.set(built, for: query)
        }
        return built
    }

    /// Em-dash-equivalents in `text`: typographic — and –, plus the
    /// plain-text spellings "--" and " - ". One definition shared by the
    /// profiler and `VoiceCheck` so the author's habit and the output's
    /// are measured identically regardless of which spelling either used.
    static func dashCount(in text: String) -> Int {
        let em = text.filter { $0 == "—" || $0 == "–" }.count
        let doubleHyphen = text.components(separatedBy: "--").count - 1
        let spacedHyphen = text.components(separatedBy: " - ").count - 1
        return em + doubleHyphen + spacedHyphen
    }

    /// Evenly stride-samples `xs` down to `cap` elements (identity when
    /// already within the cap) — deterministic, spread across the whole
    /// collection rather than truncating to its head.
    static func sample<T>(_ xs: [T], cap: Int) -> [T] {
        guard xs.count > cap, cap > 0 else { return xs }
        let stride = Double(xs.count) / Double(cap)
        return (0..<cap).map { xs[Int(Double($0) * stride)] }
    }

    // MARK: - Fallback ladder

    /// Relaxes `query` one dimension at a time — drop `accountID`, then
    /// `audience`, then `mode` — stopping as soon as the matched pool
    /// reaches ``minPoolSize``. If even dropping every dimension but
    /// `medium` isn't enough, the whole kept corpus (medium included) is
    /// used as a last resort.
    private static func matchedItems(_ dbc: Database, query: RegisterQuery) throws -> [Item] {
        let rungs: [RegisterQuery] = [
            query,
            RegisterQuery(medium: query.medium, audience: query.audience,
                          mode: query.mode, accountID: nil),
            RegisterQuery(medium: query.medium, audience: nil,
                          mode: query.mode, accountID: nil),
            RegisterQuery(medium: query.medium, audience: nil,
                          mode: nil, accountID: nil),
            RegisterQuery(medium: nil, audience: nil, mode: nil, accountID: nil)
        ]
        var last: [Item] = []
        for rung in rungs {
            let items = try fetch(dbc, query: rung)
            last = items
            if items.count >= minPoolSize {
                return items
            }
        }
        return last
    }

    private static func fetch(_ dbc: Database, query: RegisterQuery) throws -> [Item] {
        var request = Item.filter(Column("state") == "kept")
        if let medium = query.medium {
            request = request.filter(Column("kind") == medium)
        }
        if let audience = query.audience {
            request = request.filter(Column("audience") == audience)
        }
        if let mode = query.mode {
            request = request.filter(Column("mode") == mode)
        }
        if let accountID = query.accountID {
            request = request.filter(Column("account_id") == accountID)
        }
        return try request.fetchAll(dbc)
    }

    // MARK: - Profile construction

    /// A small, pragmatic stopword list: standard short English function
    /// words plus the closed set of filler words used by this app's own
    /// greeting/signoff conventions (e.g. "hey", "cheers") so those don't
    /// crowd out more distinctive multi-word phrases.
    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "of", "at", "by", "for", "to", "in", "on",
        "is", "are", "was", "were", "be", "been", "being", "have", "has", "had",
        "do", "does", "did", "will", "would", "should", "could", "can",
        "i", "you", "he", "she", "it", "we", "they",
        "this", "that", "these", "those", "my", "your", "his", "her", "its", "our", "their",
        "not", "so", "as", "up", "out", "then", "than", "too", "very", "just", "also",
        "hey", "cheers", "s", "let's", "it's", "don't", "think", "great", "meet"
    ]

    private static func buildProfile(items: [Item],
                                      baselineCounts: [String: Int],
                                      baselineTotal: Int,
                                      phraseCap: Int = defaultPhraseCap,
                                      sampleCap: Int = statsSampleCap) -> StyleProfile {
        var profile = StyleProfile()
        profile.itemCount = items.count
        guard !items.isEmpty else { return profile }
        let pool = sample(items, cap: sampleCap)

        var sentenceLens: [Int] = []
        var totalWords = 0
        var totalWordChars = 0
        var totalContractions = 0
        var totalExclamations = 0
        var totalEmoji = 0
        var totalQuestions = 0
        var totalEmDashes = 0
        var greetingCounts: [String: Int] = [:]
        var signoffCounts: [String: Int] = [:]
        var queryNGramCounts: [String: Int] = [:]
        // Distinct-item counts per phrase: a phrase repeated inside ONE
        // document (a contacts note's "amy cell", a form's "abc university")
        // can clear the raw-occurrence bar all by itself; requiring spread
        // across items separates "how the author talks" from "what one file says".
        var queryNGramDocFreq: [String: Int] = [:]
        var queryNGramTotal = 0

        for item in pool {
            guard let text = item.cleanText, !text.isEmpty else { continue }

            for sentence in sentences(in: text) {
                sentenceLens.append(wordTokens(sentence).count)
            }

            let words = wordTokens(text)
            totalWords += words.count
            totalWordChars += words.reduce(0) { $0 + $1.count }
            totalContractions += words.filter(isContraction).count
            totalExclamations += text.filter { $0 == "!" }.count
            totalEmoji += emojiCount(in: text)
            totalQuestions += text.filter { $0 == "?" }.count
            totalEmDashes += Self.dashCount(in: text)

            if item.kind == "email" {
                let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                // URL boundary lines are service footers/link shares, not
                // how anyone greets or signs off (a Google Drive footer's
                // support URL was mined as a top "signoff") — belt to the
                // cleaner's boilerplate suspenders.
                if let first = lines.first, wordTokens(first).count <= 6,
                   !isURLLine(first) {
                    greetingCounts[first.lowercased(), default: 0] += 1
                }
                if let last = lines.last, wordTokens(last).count <= 5,
                   !isURLLine(last) {
                    signoffCounts[last.lowercased(), default: 0] += 1
                }
            }

            var seenInItem: Set<String> = []
            for run in Self.tokenRuns(text) {
                countNGrams(run, into: &queryNGramCounts, total: &queryNGramTotal)
                for n in 2...3 where run.count >= n {
                    for start in 0...(run.count - n) {
                        seenInItem.insert(run[start..<(start + n)].joined(separator: " "))
                    }
                }
            }
            for phrase in seenInItem { queryNGramDocFreq[phrase, default: 0] += 1 }
        }

        profile.meanSentenceLen = sentenceLens.isEmpty
            ? 0 : Double(sentenceLens.reduce(0, +)) / Double(sentenceLens.count)
        if !sentenceLens.isEmpty {
            let mean = profile.meanSentenceLen
            let variance = sentenceLens.reduce(0.0) { $0 + pow(Double($1) - mean, 2) }
                / Double(sentenceLens.count)
            profile.sentenceLenSD = variance.squareRoot()
        }
        profile.contractionRate = totalWords == 0 ? 0 : Double(totalContractions) / Double(totalWords)
        profile.exclamationPer1k = totalWords == 0
            ? 0 : Double(totalExclamations) / Double(totalWords) * 1000
        profile.emojiPer1k = totalWords == 0
            ? 0 : Double(totalEmoji) / Double(totalWords) * 1000
        profile.meanWordLen = totalWords == 0
            ? 0 : Double(totalWordChars) / Double(totalWords)
        profile.questionPer1k = totalWords == 0
            ? 0 : Double(totalQuestions) / Double(totalWords) * 1000
        profile.emDashPer1k = totalWords == 0
            ? 0 : Double(totalEmDashes) / Double(totalWords) * 1000

        profile.topGreetings = topEntries(greetingCounts, limit: 3)
        profile.topSignoffs = topEntries(signoffCounts, limit: 3)
        profile.favoritePhrases = favoritePhrases(
            queryCounts: queryNGramCounts, queryTotal: queryNGramTotal,
            docFreq: queryNGramDocFreq,
            baselineCounts: baselineCounts, baselineTotal: baselineTotal,
            cap: phraseCap)

        return profile
    }

    private static func favoritePhrases(queryCounts: [String: Int], queryTotal: Int,
                                         docFreq: [String: Int] = [:],
                                         baselineCounts: [String: Int],
                                         baselineTotal: Int,
                                         cap: Int = defaultPhraseCap) -> [String] {
        let minCount = 5
        var candidates: [(phrase: String, lift: Double)] = []
        for (phrase, count) in queryCounts where count >= minCount {
            // Spread requirement: at least 3 distinct items must use the
            // phrase (when doc-frequency data is available), so one file
            // repeating itself can't mint a "favorite" phrase.
            if !docFreq.isEmpty, docFreq[phrase, default: 0] < 3 { continue }
            let words = phrase.split(separator: " ")
            let stopwordCount = words.filter { stopwords.contains(String($0)) }.count
            if Double(stopwordCount) / Double(words.count) >= 0.5 { continue }
            // A phrase whose identity hinges on a digit is context, not
            // voice — addresses ("106 ann arbor"), receipt/spec lines
            // ("45.00*usd 50lbs/25kg"), notification footers ("1 comment"),
            // clock times ("6:00 am"), section numbers. All observed winning
            // on lift in real corpora. Any token containing a digit
            // disqualifies the phrase.
            if words.contains(where: { $0.contains { $0.isNumber } }) { continue }

            let baselineCount = baselineCounts[phrase] ?? 0
            let queryFrac = (Double(count) + 1) / (Double(queryTotal) + 1)
            let baselineFrac = (Double(baselineCount) + 1) / (Double(baselineTotal) + 1)
            candidates.append((phrase, queryFrac / baselineFrac))
        }
        candidates.sort {
            $0.lift != $1.lift ? $0.lift > $1.lift : $0.phrase < $1.phrase
        }
        // Overlap dedupe, two rules:
        // 1. Absorption: a phrase is dropped when a LONGER candidate
        //    word-contains it with comparable frequency (>= 80% of its
        //    count) — "ann arbor" and "arbor mi" are both absorbed by
        //    "ann arbor mi", regardless of rank order. A sub-gram that also
        //    lives an independent life (much higher count) survives.
        // 2. Greedy containment: among what remains, never select two
        //    phrases where one word-contains the other.
        let absorbed: Set<String> = Set(candidates.compactMap { candidate in
            let padded = " " + candidate.phrase + " "
            let hasAbsorber = candidates.contains { other in
                other.phrase != candidate.phrase
                    && (" " + other.phrase + " ").contains(padded)
                    && Double(queryCounts[other.phrase] ?? 0)
                        >= 0.8 * Double(queryCounts[candidate.phrase] ?? 1)
            }
            return hasAbsorber ? candidate.phrase : nil
        })
        var selected: [String] = []
        for candidate in candidates where !absorbed.contains(candidate.phrase) {
            let words = " " + candidate.phrase + " "
            let overlaps = selected.contains { picked in
                (" " + picked + " ").contains(words) || words.contains(" " + picked + " ")
            }
            if !overlaps { selected.append(candidate.phrase) }
            if selected.count == cap { break }
        }
        return selected

    }

    private static func topEntries(_ counts: [String: Int], limit: Int) -> [String] {
        counts.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.prefix(limit).map(\.key)
    }

    /// Token runs that respect sentence and line boundaries — n-grams are
    /// only built WITHIN a run. Without this, the counter fused a signature
    /// line into the next paragraph (a name line + "On Tue…" → "name on tue"),
    /// minting phrases the author never wrote as phrases.
    static func tokenRuns(_ text: String) -> [[String]] {
        text.components(separatedBy: TextBoundaries.terminatorAndNewlineCharacterSet)
            .map { normalizedTokens($0) }
            .filter { $0.count >= 2 }
    }

    /// Counts every 2-3-gram of `tokens` directly into `counts` — no
    /// intermediate array of (phrase, n) tuples, which at corpus scale was
    /// millions of short-lived allocations per profile build. 4-grams were
    /// dropped for speed: they almost never clear the `minCount` threshold,
    /// but they dominated the dictionary's size.
    private static func countNGrams(_ tokens: [String],
                                     into counts: inout [String: Int],
                                     total: inout Int) {
        for n in 2...3 where tokens.count >= n {
            for start in 0...(tokens.count - n) {
                counts[tokens[start..<(start + n)].joined(separator: " "), default: 0] += 1
                total += 1
            }
        }
    }

    // MARK: - Text helpers

    private static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    /// Scalar-level whitespace split with an ASCII fast path.
    /// `Character.isWhitespace` does per-grapheme Unicode property lookups —
    /// it was the hot frame in a minutes-long Compose hang on a real corpus,
    /// where this function runs several times per item across thousands of
    /// items.
    private static func wordTokens(_ text: String) -> [String] {
        text.unicodeScalars
            .split { scalar in
                scalar.value == 32 || (scalar.value >= 9 && scalar.value <= 13)
                    || (scalar.value > 127 && scalar.properties.isWhitespace)
            }
            .map { String(String.UnicodeScalarView($0)) }
    }

    private static func isURLLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.contains("://") || lowered.hasPrefix("www.")
    }

    /// Lowercased tokens with leading/trailing punctuation stripped (but
    /// internal punctuation like an apostrophe in "don't" preserved), used
    /// only for n-gram phrase extraction so phrases don't end up glued to
    /// trailing commas/periods.
    private static func normalizedTokens(_ text: String) -> [String] {
        wordTokens(text).compactMap { token -> String? in
            let cleaned = token.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    /// Shared with `VoiceCheck` so profile stats and output checks measure
    /// identically. Matches every apostrophe-like character seen in real
    /// text — straight ', curly ’ (the straight-only version undercounted
    /// autocorrected corpus text), plus acute ´ and modifier ʼ for
    /// completeness (zero corpus hits today, but model output is measured
    /// with the same definition). Backtick is deliberately excluded: its
    /// corpus appearances are code/markdown, not contractions.
    static func isContraction(_ word: String) -> Bool {
        word.range(of: "[A-Za-z]+['’´ʼ][A-Za-z]+", options: .regularExpression) != nil
    }

    static func emojiCount(in text: String) -> Int {
        text.unicodeScalars.filter { $0.properties.isEmojiPresentation }.count
    }
}
