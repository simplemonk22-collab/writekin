import Foundation
import GRDB

/// Per-month, per-medium indicator values used to detect AI-generated-content
/// contamination creeping into the corpus over time.
struct MonthMetrics: Sendable, Equatable, Codable {
    var month: String  // "YYYY-MM"
    var items: Int
    var emDashPer1k: Double
    var ticsPer1k: Double
    var meanSentenceLen: Double
    var sentenceLenCV: Double
    var listLineRatio: Double
}

/// A medium's (email/sms/doc) full timeline of monthly metrics plus a
/// combined composite score per month and a proposed contamination cutoff
/// month, if the drift-detection heuristic found one.
struct MediumTimeline: Sendable, Equatable, Codable {
    var medium: String
    var months: [MonthMetrics]
    /// Combined per-month indicator score (weighted sum of raw metrics; see
    /// `ContaminationScan.compositeScore`). NOT pre-z-scored — `propose()`
    /// z-scores this against the baseline window itself, so this same raw
    /// array can be fed directly to `propose()` in isolation for testing.
    var composite: [Double]
    var proposedCutoff: String?
    /// True when `baselineEndIndex()` had to fall back to a first-half
    /// baseline because too few pre-2022 months survived filtering, AND that
    /// fallback itself has no clean pre-contamination-era anchor (its first
    /// month is already at/after 2022-01). The UI should caption proposals
    /// built on a weak baseline as low-confidence.
    var baselineIsWeak: Bool = false
}

enum ContaminationScan {
    /// Months with fewer than this many kept items are dropped from the
    /// timeline entirely — too few samples to compute a stable rate/ratio,
    /// and including them would inject noise into both the baseline mean/σ
    /// and the sustained-streak scan.
    static let minItemsPerMonth = 3

    /// Composite weights. Em-dash and tic rates are already expressed
    /// per-1000-words so they sit on a comparable scale to each other; list-
    /// line ratio is a 0...1 fraction so it needs a scale factor to
    /// contribute meaningfully alongside them. Sentence length / CV are
    /// reported in `MonthMetrics` for display but deliberately excluded from
    /// the composite: at the item counts we expect per month they are too
    /// noisy to add signal beyond the em-dash/tic/list-format indicators.
    /// Internal (not `private`) so `TimelineView`'s "how the score works"
    /// explainer can quote these exact numbers instead of hardcoding a copy
    /// that could drift out of sync with the real scoring.
    static let emDashWeight = 1.0
    static let ticsWeight = 1.0
    static let listRatioWeight = 100.0

    /// Z-score threshold a month's composite must exceed, sustained for
    /// `sustainedMonths` consecutive months, before `propose()` will flag a
    /// cutoff.
    static let zThreshold = 1.5
    static let sustainedMonths = 3

    /// First month considered "AI era" for baseline purposes (see
    /// `baselineEndIndex`) — also quoted by `TimelineView`'s explainer.
    static let baselineEraCutoff = "2022-01"

    static func run(_ db: AppDatabase, settings: ScanSettings = ScanSettings(), progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> [MediumTimeline] {
        // Fetch total count of kept items for progress tracking
        let totalItems = try await db.writer.read { dbc in
            try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM items
                WHERE state = 'kept' AND authored_at IS NOT NULL AND clean_text IS NOT NULL
                """) ?? 0
        }

        let rows = try await db.writer.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT kind, strftime('%Y-%m', authored_at) AS month, clean_text
                FROM items
                WHERE state = 'kept' AND authored_at IS NOT NULL AND clean_text IS NOT NULL
                ORDER BY kind, month
                """)
        }

        // Progress spans TWO passes over the same `totalItems` rows: bucketing
        // them by medium/month (cheap), then computing per-month metrics
        // (em-dash/tic-lexicon scanning across every item's text -- the
        // actually expensive part). Reporting only the bucketing pass would
        // let the progress bar hit "N/N" long before the scan is actually
        // done, since every row counts once per pass, the total work is
        // `totalItems * 2`.
        let totalWork = totalItems * 2

        var textsByMediumMonth: [String: [String: [String]]] = [:]
        var processedCount = 0
        for row in rows {
            let kind: String = row["kind"]
            let month: String = row["month"]
            let text: String = row["clean_text"]
            textsByMediumMonth[kind, default: [:]][month, default: []].append(text)
            processedCount += 1
            progress(processedCount, totalWork)
        }

        var timelines: [MediumTimeline] = []
        for medium in textsByMediumMonth.keys.sorted() {
            let byMonth = textsByMediumMonth[medium]!
            var monthMetrics: [MonthMetrics] = []
            for month in byMonth.keys.sorted() {
                let texts = byMonth[month]!
                processedCount += texts.count
                progress(processedCount, totalWork)
                guard texts.count >= settings.minItemsPerMonth else { continue }
                let m = metrics(texts: texts, customPhrases: settings.customPhrases,
                                 disabledBuiltinPhrases: settings.disabledBuiltinPhrases)
                monthMetrics.append(MonthMetrics(
                    month: month, items: texts.count,
                    emDashPer1k: m.emDash, ticsPer1k: m.tics,
                    meanSentenceLen: m.meanLen, sentenceLenCV: m.cv,
                    listLineRatio: m.listRatio))
            }
            guard !monthMetrics.isEmpty else { continue }

            let months = monthMetrics.map(\.month)
            let composite = monthMetrics.map { compositeScore($0, settings: settings) }
            let baseline = baselineEndIndex(months: months, eraCutoff: settings.baselineEraMonth)
            let cutoff = propose(composite: composite, months: months, baselineEndIndex: baseline, settings: settings)
            timelines.append(MediumTimeline(medium: medium, months: monthMetrics,
                                             composite: composite, proposedCutoff: cutoff,
                                             baselineIsWeak: baselineIsWeak(months: months, eraCutoff: settings.baselineEraMonth)))
        }
        return timelines
    }

    /// Weighted sum of the enabled signals only -- a signal `settings`
    /// disables contributes 0 to the composite rather than being scaled
    /// down, so disabling every signal but one lets that one dominate
    /// exactly as if the others didn't exist. Internal (not `private`) so
    /// `ScanSettings`-aware callers (tests, `ContaminationModel`) can call it
    /// directly instead of only through `run`.
    static func compositeScore(_ m: MonthMetrics, settings: ScanSettings = ScanSettings()) -> Double {
        var score = 0.0
        if settings.emDashEnabled { score += emDashWeight * m.emDashPer1k }
        if settings.phrasesEnabled { score += ticsWeight * m.ticsPer1k }
        if settings.listFormattingEnabled { score += listRatioWeight * m.listLineRatio }
        return score
    }

    /// Minimum number of surviving pre-2022 months required to trust the
    /// "months strictly before 2022-01" baseline. Fewer than this and a
    /// single unlucky/unrepresentative month could dominate the baseline
    /// mean/σ, silently shrinking the baseline onto too little data.
    private static let minBaselineMonths = 6

    /// Baseline = months strictly before "2022-01", provided at least
    /// `minBaselineMonths` of them survived per-month filtering. Falls back
    /// to the first half of the timeline when there's no month at/after
    /// 2022-01 to anchor against (all months already in/after the assumed
    /// AI era, or none of them reach it), or when too few pre-2022 months
    /// survived to trust as a baseline on their own. See `baselineIsWeak`
    /// for when this fallback itself has no clean data to fall back onto.
    static func baselineEndIndex(months: [String], eraCutoff: String = baselineEraCutoff) -> Int {
        if let idx = months.firstIndex(where: { $0 >= eraCutoff }), idx >= minBaselineMonths {
            return idx
        }
        return max(1, months.count / 2)
    }

    /// True when `baselineEndIndex()` had to use the first-half fallback
    /// (too few, or zero, surviving pre-2022 months) AND that fallback
    /// itself starts at/after 2022-01 — i.e. there is no clean
    /// pre-contamination-era data left in the timeline at all, so whatever
    /// baseline gets used is likely contaminated. `run()` surfaces this via
    /// `MediumTimeline.baselineIsWeak` so the UI can caption the proposal as
    /// low-confidence instead of silently trusting it.
    static func baselineIsWeak(months: [String], eraCutoff: String = baselineEraCutoff) -> Bool {
        guard let first = months.first else { return true }
        if let idx = months.firstIndex(where: { $0 >= eraCutoff }), idx >= minBaselineMonths {
            return false
        }
        return first >= eraCutoff
    }

    /// Pure, directly-testable metrics computation over a set of texts
    /// (typically all kept items for one medium+month).
    ///
    /// - emDash: count of em-dash ("—") characters per 1000 words.
    /// - tics: count of `TicLexicon.words` phrase hits (case-insensitive
    ///   substring match against lowercased text) per 1000 words.
    /// - meanLen: mean sentence length in words. Sentences are split on
    ///   `.`/`!`/`?`.
    /// - cv: coefficient of variation of sentence length (population
    ///   stdDev / mean). Population (not sample) stdDev is used so a single
    ///   text with 2+ sentences still yields a defined value; guarded to 0
    ///   when there are no sentences or mean is 0.
    /// - listRatio: fraction of non-empty lines that look like a list item
    ///   (start with "-", "*", "•", or "<number>." / "<number>)").
    static func metrics(texts: [String], customPhrases: [String] = [], disabledBuiltinPhrases: Set<String> = []) -> (emDash: Double, tics: Double, meanLen: Double, cv: Double, listRatio: Double) {
        guard !texts.isEmpty else { return (0, 0, 0, 0, 0) }

        let phraseData = ticPhraseData(customPhrases: customPhrases, disabledBuiltinPhrases: disabledBuiltinPhrases)
        var totalWords = 0
        var emDashCount = 0
        var ticsCount = 0
        var sentenceLengths: [Double] = []
        var totalLines = 0
        var listLines = 0

        for text in texts {
            // Lowercased exactly once per item -- the 40-entry tic lexicon
            // is matched against this single lowercased copy below, instead
            // of each phrase re-deriving its own comparison.
            let lower = text.lowercased()

            emDashCount += text.unicodeScalars.reduce(0) { $1.value == 0x2014 ? $0 + 1 : $0 }

            ticsCount += countTicOccurrences(in: lower, phraseData: phraseData)

            let words = wordTokens(text)
            totalWords += words.count

            let sentences = text
                .components(separatedBy: TextBoundaries.terminatorCharacterSet)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for sentence in sentences {
                let wc = wordTokens(sentence).count
                if wc > 0 { sentenceLengths.append(Double(wc)) }
            }

            let lines = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            totalLines += lines.count
            listLines += lines.filter(isListLine).count
        }

        let meanLen = sentenceLengths.isEmpty ? 0 : sentenceLengths.reduce(0, +) / Double(sentenceLengths.count)
        let variance = sentenceLengths.isEmpty
            ? 0
            : sentenceLengths.reduce(0) { $0 + pow($1 - meanLen, 2) } / Double(sentenceLengths.count)
        let cv = meanLen > 0 ? sqrt(variance) / meanLen : 0

        let emDashPer1k = totalWords > 0 ? Double(emDashCount) / Double(totalWords) * 1000 : 0
        let ticsPer1k = totalWords > 0 ? Double(ticsCount) / Double(totalWords) * 1000 : 0
        let listRatio = totalLines > 0 ? Double(listLines) / Double(totalLines) : 0

        return (emDashPer1k, ticsPer1k, meanLen, cv, listRatio)
    }

    /// Scalar-level whitespace split with an ASCII fast path -- same
    /// approach as `StyleProfiler.wordTokens`, whose perf fix this mirrors:
    /// `Character.isWhitespace`/`split(whereSeparator:)` on `Character` do
    /// per-grapheme Unicode property lookups, which dominated `metrics`'
    /// runtime in debug builds at real-corpus scale.
    private static func wordTokens(_ text: String) -> [String] {
        text.unicodeScalars
            .split { scalar in
                scalar.value == 32 || (scalar.value >= 9 && scalar.value <= 13)
                    || (scalar.value > 127 && scalar.properties.isWhitespace)
            }
            .map { String(String.UnicodeScalarView($0)) }
    }

    /// `TicLexicon.words` pre-converted to `Data` once, so the common case
    /// (no custom phrases) never re-derives them per call.
    private static let baseTicPhraseData: [Data] = TicLexicon.words.map { Data($0.utf8) }

    /// The needle set `countTicOccurrences` searches for: `TicLexicon.words`
    /// minus any `disabledBuiltinPhrases` (from `ScanSettings`, per-phrase
    /// checkboxes in the Timeline settings tab), plus any user-added
    /// `customPhrases` (from `ScanSettings.customPhrases` -- already
    /// lowercased by the UI before being stored, but lowercased again here
    /// defensively). Falls back to the precomputed `baseTicPhraseData` when
    /// there are no custom phrases and nothing disabled, avoiding a rebuild
    /// on every call in the common case.
    private static func ticPhraseData(customPhrases: [String], disabledBuiltinPhrases: Set<String> = []) -> [Data] {
        guard !customPhrases.isEmpty || !disabledBuiltinPhrases.isEmpty else { return baseTicPhraseData }
        let builtins = disabledBuiltinPhrases.isEmpty
            ? TicLexicon.words
            : TicLexicon.words.filter { !disabledBuiltinPhrases.contains($0) }
        // Empty phrases are filtered defensively: an empty `Data` needle
        // would match trivially at every position in
        // `Data.range(of:in:)`, corrupting the count (and, since
        // `searchStart` never advances past a zero-length match at
        // `endIndex`, risking an infinite loop).
        let extra = customPhrases.map { $0.lowercased() }.filter { !$0.isEmpty }
        return (builtins + extra).map { Data($0.utf8) }
    }

    /// Counts occurrences of every phrase in `phraseData` within `lower`
    /// (already lowercased). Byte-level matching is safe because every
    /// lexicon phrase is plain ASCII (no grapheme/canonical-equivalence
    /// subtlety vs the old Character-based `components(separatedBy:)`), and
    /// the search goes through `Data.range(of:)` — optimized Foundation code
    /// — rather than a hand-rolled Swift byte loop, whose per-access bounds
    /// checks made a DEBUG build spend ~2s per item here (live-sampled: 100%
    /// of scan time in the manual loop). Non-overlapping: resume past each
    /// match, matching `components(separatedBy:).count - 1` semantics.
    private static func countTicOccurrences(in lower: String, phraseData: [Data]) -> Int {
        let haystack = Data(lower.utf8)
        guard !haystack.isEmpty else { return 0 }
        var count = 0
        for needle in phraseData {
            var searchStart = haystack.startIndex
            while let match = haystack.range(of: needle, in: searchStart..<haystack.endIndex) {
                count += 1
                searchStart = match.upperBound
            }
        }
        return count
    }

    private static func isListLine(_ line: String) -> Bool {
        if line.hasPrefix("-") || line.hasPrefix("*") || line.hasPrefix("\u{2022}") {
            return true
        }
        // "1." / "12)" style ordered-list markers.
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return false }
        let rest = line.dropFirst(digits.count)
        return rest.hasPrefix(".") || rest.hasPrefix(")")
    }

    /// Finds the earliest month at which the composite score, z-scored
    /// against the baseline window `composite[0..<baselineEndIndex]`,
    /// exceeds `zThreshold` for `sustainedMonths` consecutive months.
    /// Returns the *first* month of that streak, or nil if no such streak
    /// exists (including when the baseline has zero variance — see below).
    static func propose(composite: [Double], months: [String], baselineEndIndex: Int, settings: ScanSettings = ScanSettings()) -> String? {
        guard composite.count == months.count, !composite.isEmpty,
              baselineEndIndex > 0, baselineEndIndex <= composite.count else { return nil }

        let zThreshold = settings.effectiveZThreshold
        let sustainedMonths = settings.effectiveStreakMonths

        let baseline = Array(composite[0..<baselineEndIndex])
        let mean = baseline.reduce(0, +) / Double(baseline.count)
        let variance = baseline.reduce(0) { $0 + pow($1 - mean, 2) } / Double(baseline.count)

        // Guard σ = 0 (perfectly flat, or single-month, baseline): dividing
        // by an exact zero would produce Inf/NaN z-scores. Floor σ to a tiny
        // epsilon instead of bailing out entirely — a baseline with zero
        // variance (e.g. an era that never used em-dashes or tic words at
        // all) is common, and a later month that departs from that flat
        // baseline is still a real, meaningful signal. The `sustainedMonths`
        // consecutive-month requirement below still protects against a
        // single-month blip being reported as a cutoff.
        let sigma = max(sqrt(variance), 1e-6)

        let zScores = composite.map { ($0 - mean) / sigma }

        var streak = 0
        for i in 0..<zScores.count {
            // `months` only contains surviving (post-filter) calendar
            // months, so consecutive array indices can hide a real calendar
            // gap (a month dropped for having too few items). A streak must
            // not be allowed to span such a gap, or a filtered-out month
            // could stitch together two unrelated bursts into a false
            // "3 consecutive months" cutoff.
            if i > 0, !isNextMonth(months[i], after: months[i - 1]) {
                streak = 0
            }
            if zScores[i] > zThreshold {
                streak += 1
                if streak >= sustainedMonths {
                    return months[i - sustainedMonths + 1]
                }
            } else {
                streak = 0
            }
        }
        return nil
    }

    /// True when `month` is exactly one calendar month after `previous`
    /// (both "YYYY-MM"). Pure string/integer arithmetic — no `Calendar`/
    /// `Date` involved, so it can't be thrown off by time zones or DST.
    /// Malformed input (wrong shape, non-numeric, out-of-range month) is
    /// treated as "not adjacent" rather than trapping.
    static func isNextMonth(_ month: String, after previous: String) -> Bool {
        guard let prev = yearMonth(previous), let cur = yearMonth(month) else { return false }
        let prevIndex = prev.year * 12 + (prev.month - 1)
        let curIndex = cur.year * 12 + (cur.month - 1)
        return curIndex == prevIndex + 1
    }

    private static func yearMonth(_ s: String) -> (year: Int, month: Int)? {
        let parts = s.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]),
              m >= 1, m <= 12 else { return nil }
        return (y, m)
    }
}
