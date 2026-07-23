import Testing
import Foundation
import GRDB
@testable import Writekin

struct ContaminationScanTests {

    // MARK: - metrics()

    @Test func meanSentenceLenAndCVHandComputed() {
        // Sentences: "One two three" (3 words), "Four five" (2 words).
        // mean = (3+2)/2 = 2.5
        // population variance = ((3-2.5)^2 + (2-2.5)^2)/2 = (0.25+0.25)/2 = 0.25
        // stdDev = 0.5, cv = 0.5/2.5 = 0.2
        let r = ContaminationScan.metrics(texts: ["One two three. Four five."])
        #expect(r.meanLen == 2.5)
        #expect(abs(r.cv - 0.2) < 1e-9)
    }

    @Test func emDashPer1kHandComputed() {
        // "This is really — truly great news today" splits into 8
        // whitespace-separated tokens (the em dash is its own token), with
        // 1 em dash. emDashPer1k = 1/8 * 1000 = 125.0
        let r = ContaminationScan.metrics(texts: ["This is really — truly great news today"])
        #expect(abs(r.emDash - 125.0) < 1e-9)
    }

    @Test func ticsPer1kHandComputed() {
        // "Let's delve into this vibrant tapestry of ideas" = 8 words, contains
        // "delve" and "vibrant" and "tapestry" = 3 tic hits.
        // ticsPer1k = 3/8 * 1000 = 375
        let r = ContaminationScan.metrics(texts: ["Let's delve into this vibrant tapestry of ideas"])
        #expect(abs(r.tics - 375.0) < 1e-9)
    }

    @Test func listLineRatioHandComputed() {
        // 4 non-empty lines, 2 start with a list marker => ratio 0.5
        let text = "- first point\nsome prose here\n* second point\nmore prose"
        let r = ContaminationScan.metrics(texts: [text])
        #expect(abs(r.listRatio - 0.5) < 1e-9)
    }

    @Test func metricsOnEmptyTextsAreZero() {
        let r = ContaminationScan.metrics(texts: [])
        #expect(r.emDash == 0)
        #expect(r.tics == 0)
        #expect(r.meanLen == 0)
        #expect(r.cv == 0)
        #expect(r.listRatio == 0)
    }

    // MARK: - compositeScore() with ScanSettings

    @Test func compositeScoreDefaultSettingsMatchesAllSignalsEnabled() {
        let m = MonthMetrics(month: "2021-01", items: 10, emDashPer1k: 2, ticsPer1k: 3,
                              meanSentenceLen: 5, sentenceLenCV: 0.2, listLineRatio: 0.1)
        let expected = ContaminationScan.emDashWeight * m.emDashPer1k
            + ContaminationScan.ticsWeight * m.ticsPer1k
            + ContaminationScan.listRatioWeight * m.listLineRatio
        #expect(ContaminationScan.compositeScore(m) == expected)
        #expect(ContaminationScan.compositeScore(m, settings: ScanSettings()) == expected)
    }

    @Test func compositeScoreZeroesDisabledSignals() {
        let m = MonthMetrics(month: "2021-01", items: 10, emDashPer1k: 2, ticsPer1k: 3,
                              meanSentenceLen: 5, sentenceLenCV: 0.2, listLineRatio: 0.1)
        var settings = ScanSettings()
        settings.emDashEnabled = false
        let expected = ContaminationScan.ticsWeight * m.ticsPer1k + ContaminationScan.listRatioWeight * m.listLineRatio
        #expect(ContaminationScan.compositeScore(m, settings: settings) == expected)
    }

    @Test func compositeScoreOnlyOneSignalEnabled() {
        let m = MonthMetrics(month: "2021-01", items: 10, emDashPer1k: 2, ticsPer1k: 3,
                              meanSentenceLen: 5, sentenceLenCV: 0.2, listLineRatio: 0.1)
        var settings = ScanSettings()
        settings.phrasesEnabled = false
        settings.listFormattingEnabled = false
        #expect(ContaminationScan.compositeScore(m, settings: settings) == ContaminationScan.emDashWeight * m.emDashPer1k)
    }

    // MARK: - propose() with ScanSettings sensitivity

    @Test func proposeLowSensitivityRequiresBiggerSustainedStreak() {
        // A clean 3-month streak far above threshold -- enough for
        // `.normal`'s 3-month requirement, but `.low` requires 4, so this
        // must return nil under `.low` even though the same data proposes a
        // cutoff under `.normal` (see `adjacentMonthsAllowStreak`'s shape).
        let months = (0..<8).map { String(format: "2021-%02d", $0 + 1) }
        var composite = [1.0, 1.1, 0.9, 1.0, 1.1]
        composite += [20.0, 20.0, 20.0]
        var settings = ScanSettings()
        settings.sensitivity = .low
        let cutoff = ContaminationScan.propose(composite: composite, months: months, baselineEndIndex: 5, settings: settings)
        #expect(cutoff == nil)

        let normalCutoff = ContaminationScan.propose(composite: composite, months: months, baselineEndIndex: 5)
        #expect(normalCutoff == months[5])
    }

    @Test func proposeHighSensitivityFiresOnSmallerSustainedStreak() {
        // Mirrors `adjacentMonthsAllowStreak`'s shape, but only a 2-month
        // streak -- too short for `.normal` (needs 3), but exactly enough
        // for `.high` (needs 2), proving the sensitivity substitution.
        let baselineMonths = (1...6).map { String(format: "2021-%02d", $0) }
        let months = baselineMonths + ["2023-01", "2023-02"]
        var composite = [1.0, 1.1, 0.9, 1.0, 1.1, 0.9]
        composite += [20.0, 20.0]
        var settings = ScanSettings()
        settings.sensitivity = .high
        let cutoff = ContaminationScan.propose(composite: composite, months: months, baselineEndIndex: 6, settings: settings)
        #expect(cutoff == "2023-01")

        // The same data under `.normal` sensitivity must NOT fire -- only
        // 2 consecutive months, short of the 3 `.normal` requires.
        let normalCutoff = ContaminationScan.propose(composite: composite, months: months, baselineEndIndex: 6)
        #expect(normalCutoff == nil)
    }

    @Test func proposeHighSensitivityLowerZThresholdFiresWhereNormalDoesNot() {
        // Baseline [1.0, 1.2, 0.8, 1.1, 0.9, 1.0]: mean 1.0, sigma ~0.1291.
        // A sustained bump to 1.16 z-scores to ~1.24 -- above `.high`'s
        // z=1.0 threshold but below `.normal`'s z=1.5, so it must fire under
        // `.high` and stay silent under `.normal`, proving the zThreshold
        // substitution independent of the streak-length one above.
        let months = (0..<9).map { String(format: "2021-%02d", $0 + 1) }
        var composite = [1.0, 1.2, 0.8, 1.1, 0.9, 1.0]
        composite += [1.16, 1.16, 1.16]
        var settings = ScanSettings()
        settings.sensitivity = .high
        let cutoff = ContaminationScan.propose(composite: composite, months: months, baselineEndIndex: 6, settings: settings)
        #expect(cutoff == months[6])

        let normalCutoff = ContaminationScan.propose(composite: composite, months: months, baselineEndIndex: 6)
        #expect(normalCutoff == nil)
    }

    // MARK: - propose()

    @Test func proposeReturnsMonthAtPlantedDrift() {
        let months = (0..<12).map { String(format: "2021-%02d", $0 % 12 + 1) }
        // Baseline: first 6 months flat around 1.0. Drift planted at index 6:
        // months 6,7,8.. jump far above baseline mean/sigma.
        var composite = [1.0, 1.1, 0.9, 1.0, 1.1, 0.9]
        composite += Array(repeating: 20.0, count: 6)
        let cutoff = ContaminationScan.propose(composite: composite, months: months, baselineEndIndex: 6)
        #expect(cutoff == months[6])
    }

    @Test func proposeReturnsNilForFlatNoise() {
        let months = (0..<12).map { String(format: "2021-%02d", $0 % 12 + 1) }
        let composite: [Double] = [1.0, 1.1, 0.9, 1.05, 0.95, 1.0, 1.02, 0.98, 1.03, 0.97, 1.01, 0.99]
        let cutoff = ContaminationScan.propose(composite: composite, months: months, baselineEndIndex: 6)
        #expect(cutoff == nil)
    }

    @Test func proposeGuardsZeroSigma() {
        let months = ["2021-01", "2021-02", "2021-03", "2021-04"]
        // Baseline (first 2) is perfectly flat -> sigma == 0. Must not
        // crash/produce NaN/Inf. Only 2 months (not the required 3) exceed
        // the threshold afterward, so this correctly returns nil.
        let composite: [Double] = [5.0, 5.0, 100.0, 100.0]
        let cutoff = ContaminationScan.propose(composite: composite, months: months, baselineEndIndex: 2)
        #expect(cutoff == nil)
    }

    @Test func proposeRequiresThreeConsecutiveMonths() {
        let months = (0..<8).map { String(format: "2021-%02d", $0 + 1) }
        var composite = [1.0, 1.1, 0.9, 1.0, 1.1]
        // Only 2 consecutive months exceed threshold before dropping back.
        composite += [20.0, 20.0, 1.0]
        let cutoff = ContaminationScan.propose(composite: composite, months: months, baselineEndIndex: 5)
        #expect(cutoff == nil)
    }

    @Test func gapMonthBreaksStreak() {
        // Drift planted at 2023-01, 2023-02, 2023-04 — 03 is missing
        // (dropped by per-month filtering upstream), so the streak spans a
        // real calendar gap and must NOT be reported.
        let baselineMonths = (1...6).map { String(format: "2021-%02d", $0) }
        let months = baselineMonths + ["2023-01", "2023-02", "2023-04"]
        var composite = [1.0, 1.1, 0.9, 1.0, 1.1, 0.9]
        composite += [20.0, 20.0, 20.0]
        let cutoff = ContaminationScan.propose(composite: composite, months: months, baselineEndIndex: 6)
        #expect(cutoff == nil)
    }

    @Test func adjacentMonthsAllowStreak() {
        // Same shape, but 2023-03 is present too — a true consecutive
        // 3-month streak — so this one should fire.
        let baselineMonths = (1...6).map { String(format: "2021-%02d", $0) }
        let months = baselineMonths + ["2023-01", "2023-02", "2023-03"]
        var composite = [1.0, 1.1, 0.9, 1.0, 1.1, 0.9]
        composite += [20.0, 20.0, 20.0]
        let cutoff = ContaminationScan.propose(composite: composite, months: months, baselineEndIndex: 6)
        #expect(cutoff == "2023-01")
    }

    // MARK: - metrics() with customPhrases

    @Test func customPhrasesAreCountedAlongsideBuiltIns() {
        // "circle back" is not in TicLexicon.words, so it doesn't count by
        // default -- only with it supplied as a customPhrase.
        let text = "Let's circle back on this tomorrow, five words total"
        let withoutCustom = ContaminationScan.metrics(texts: [text])
        #expect(withoutCustom.tics == 0)

        let withCustom = ContaminationScan.metrics(texts: [text], customPhrases: ["circle back"])
        #expect(withCustom.tics > 0)
    }

    @Test func customPhrasesDoNotSuppressBuiltInMatches() {
        // A custom phrase must be additive, not a replacement for the
        // built-in lexicon -- both "delve" (built-in) and "circle back"
        // (custom) should count in the same pass.
        let text = "Let's delve into this circle back plan today"
        let builtInOnly = ContaminationScan.metrics(texts: [text]).tics
        let withCustomAdded = ContaminationScan.metrics(texts: [text], customPhrases: ["circle back"]).tics
        #expect(builtInOnly > 0, "built-in \u{201C}delve\u{201D} hit expected even without custom phrases")
        #expect(withCustomAdded > builtInOnly, "adding a custom phrase must add hits, not replace the built-in ones")
    }

    // MARK: - metrics() with disabledBuiltinPhrases

    @Test func disabledBuiltinPhraseStopsCounting() {
        let text = "Let's delve into this vibrant tapestry of ideas"
        let allEnabled = ContaminationScan.metrics(texts: [text])
        #expect(allEnabled.tics > 0)

        // Disabling every built-in phrase actually present in the text
        // (delve, vibrant, tapestry) should zero the tics rate out entirely.
        let disabled = ContaminationScan.metrics(
            texts: [text], disabledBuiltinPhrases: ["delve", "vibrant", "tapestry"])
        #expect(disabled.tics == 0)
    }

    @Test func disabledBuiltinPhraseDoesNotAffectOtherBuiltIns() {
        // Only "delve" is disabled -- "vibrant"/"tapestry" hits must still
        // count, so the rate drops but doesn't hit zero.
        let text = "Let's delve into this vibrant tapestry of ideas"
        let allEnabled = ContaminationScan.metrics(texts: [text]).tics
        let oneDisabled = ContaminationScan.metrics(texts: [text], disabledBuiltinPhrases: ["delve"]).tics
        #expect(oneDisabled > 0)
        #expect(oneDisabled < allEnabled)
    }

    @Test func disabledBuiltinPhrasesCombineWithCustomPhrases() {
        // Disabling a built-in and adding a custom phrase both take effect
        // together: the disabled built-in stops counting, the custom phrase
        // starts.
        let text = "Let's delve into this circle back plan today"
        let r = ContaminationScan.metrics(
            texts: [text], customPhrases: ["circle back"], disabledBuiltinPhrases: ["delve"])
        // "delve" disabled contributes 0, "circle back" custom contributes 1
        // hit -- so tics should come from the custom phrase alone, not from
        // "delve" too.
        let customOnly = ContaminationScan.metrics(texts: [text], customPhrases: ["circle back"]).tics
        let withDelveDisabled = r.tics
        #expect(withDelveDisabled < customOnly, "disabling \u{201C}delve\u{201D} should drop its contribution even with a custom phrase active")
    }

    /// Scan-level: a disabled built-in phrase must stop contributing to the
    /// composite score computed via `ScanSettings.disabledBuiltinPhrases`,
    /// not just to the raw `metrics()` tics rate -- i.e. the effective
    /// needle set change actually reaches `compositeScore` through
    /// `MonthMetrics.ticsPer1k`.
    @Test func disabledBuiltinPhraseZeroesCompositeContributionFromTics() {
        let text = "Let's delve into this plan today with clear steps"
        let allEnabled = ContaminationScan.metrics(texts: [text])
        var settings = ScanSettings()
        settings.emDashEnabled = false
        settings.listFormattingEnabled = false
        // Only the phrases signal counts, so compositeScore is driven
        // entirely by ticsPer1k.
        let withDelve = MonthMetrics(month: "2024-01", items: 1, emDashPer1k: 0,
                                      ticsPer1k: allEnabled.tics, meanSentenceLen: 0,
                                      sentenceLenCV: 0, listLineRatio: 0)
        #expect(ContaminationScan.compositeScore(withDelve, settings: settings) > 0)

        settings.disabledBuiltinPhrases = ["delve"]
        let disabledMetrics = ContaminationScan.metrics(
            texts: [text], disabledBuiltinPhrases: settings.disabledBuiltinPhrases)
        let withoutDelve = MonthMetrics(month: "2024-01", items: 1, emDashPer1k: 0,
                                         ticsPer1k: disabledMetrics.tics, meanSentenceLen: 0,
                                         sentenceLenCV: 0, listLineRatio: 0)
        #expect(ContaminationScan.compositeScore(withoutDelve, settings: settings) == 0)
    }

    // MARK: - baselineEndIndex()/baselineIsWeak() with a custom eraCutoff

    @Test func baselineEndIndexRespectsCustomEraCutoff() {
        let months = (1...8).map { String(format: "2020-%02d", $0) } + ["2022-01", "2022-02"]
        // Default cutoff "2022-01": index 8 has >=6 preceding months, so the
        // real pre-era baseline is used.
        #expect(ContaminationScan.baselineEndIndex(months: months) == 8)
        // A much earlier custom cutoff finds no month before it, so it falls
        // back to the first-half heuristic instead -- a different index,
        // proving the parameter actually changes the outcome.
        #expect(ContaminationScan.baselineEndIndex(months: months, eraCutoff: "2020-01") == 5)
    }

    @Test func baselineIsWeakRespectsCustomEraCutoff() {
        let months = (1...8).map { String(format: "2020-%02d", $0) } + ["2022-01", "2022-02"]
        #expect(!ContaminationScan.baselineIsWeak(months: months))
        // Every month is at/after this custom (very early) cutoff, so the
        // fallback baseline itself has no clean pre-era data -- weak.
        #expect(ContaminationScan.baselineIsWeak(months: months, eraCutoff: "2020-01"))
    }

    // MARK: - isNextMonth()

    @Test func isNextMonthHandlesYearRollover() {
        #expect(ContaminationScan.isNextMonth("2022-01", after: "2021-12"))
        #expect(ContaminationScan.isNextMonth("2021-07", after: "2021-06"))
        #expect(!ContaminationScan.isNextMonth("2021-08", after: "2021-06"))
        #expect(!ContaminationScan.isNextMonth("2021-06", after: "2021-06"))
    }

    // MARK: - baselineIsWeak()

    @Test func baselineIsWeakFalseWithSufficientPreBaseline() {
        let months = (1...6).map { String(format: "2021-%02d", $0) } + ["2022-01", "2022-02"]
        #expect(!ContaminationScan.baselineIsWeak(months: months))
    }

    @Test func baselineIsWeakTrueWhenAllPostContaminationEra() {
        let months = ["2023-01", "2023-03", "2023-05"]
        #expect(ContaminationScan.baselineIsWeak(months: months))
    }

    // MARK: - run()

    func seededDB() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "apple_mail", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)

            let cleanText = "Hi there, just checking in. Hope you are doing well. Talk soon."
            let tickyText = """
            Let's delve into this vibrant tapestry — it's truly a game-changer. \
            Furthermore, this is a robust, seamless, comprehensive approach. \
            Moreover, we must leverage this pivotal, cutting-edge landscape.
            """

            var idx = 0
            // Clean baseline months: 2021-01 .. 2021-06, 4 emails each.
            for month in 1...6 {
                for _ in 0..<4 {
                    idx += 1
                    var item = Item.stub(sourceId: s.id!, externalId: "e\(idx)", rawText: cleanText)
                    item.state = "kept"
                    item.kind = "email"
                    item.cleanText = cleanText
                    item.authoredAt = Self.date(year: 2021, month: month, day: 10)
                    try item.insert(dbc)
                }
            }
            // Ticky/contaminated months: 2022-01 .. 2022-04, 4 emails each.
            for month in 1...4 {
                for _ in 0..<4 {
                    idx += 1
                    var item = Item.stub(sourceId: s.id!, externalId: "e\(idx)", rawText: tickyText)
                    item.state = "kept"
                    item.kind = "email"
                    item.cleanText = tickyText
                    item.authoredAt = Self.date(year: 2022, month: month, day: 10)
                    try item.insert(dbc)
                }
            }
        }
        return db
    }

    static func date(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    @Test func runDetectsCutoffAtContaminationOnset() async throws {
        let db = try seededDB()
        let timelines = try await ContaminationScan.run(db)
        let email = try #require(timelines.first { $0.medium == "email" })
        #expect(email.months.count == 10)
        let cutoff = try #require(email.proposedCutoff)
        #expect(cutoff == "2022-01")
    }

    @Test func weakBaselineFlagged() async throws {
        // Only post-2022 history, sparse (just enough items per month to
        // survive the >=3-items filter) — there's no pre-2022 data at all,
        // so whatever baseline gets used is inherently unreliable.
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "apple_mail", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let text = "Hi there, just checking in. Hope you are doing well. Talk soon."
            var idx = 0
            for month in 1...4 {
                for _ in 0..<3 {
                    idx += 1
                    var item = Item.stub(sourceId: s.id!, externalId: "w\(idx)", rawText: text)
                    item.state = "kept"
                    item.kind = "email"
                    item.cleanText = text
                    item.authoredAt = Self.date(year: 2023, month: month, day: 10)
                    try item.insert(dbc)
                }
            }
        }
        let timelines = try await ContaminationScan.run(db)
        let email = try #require(timelines.first { $0.medium == "email" })
        #expect(email.baselineIsWeak)
    }

    @Test func runIgnoresNonKeptItems() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "apple_mail", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var item = Item.stub(sourceId: s.id!, externalId: "x1", rawText: "hello")
            item.state = "dropped"
            item.kind = "email"
            item.cleanText = "hello world"
            item.authoredAt = Self.date(year: 2021, month: 1, day: 1)
            try item.insert(dbc)
        }
        let timelines = try await ContaminationScan.run(db)
        #expect(timelines.isEmpty)
    }

    /// `settings.minItemsPerMonth` threads all the way into `run()`'s
    /// per-month filter -- a month with exactly 2 kept items is dropped
    /// under the default (3) but survives once the settings knob is lowered
    /// to 2, proving the fixture's outcome actually depends on the setting
    /// rather than only on the hardcoded `ContaminationScan.minItemsPerMonth`
    /// constant.
    @Test func minItemsPerMonthSettingThreadsIntoRun() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "apple_mail", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let text = "Hi there, just checking in. Hope you are doing well."
            for i in 0..<2 {
                var item = Item.stub(sourceId: s.id!, externalId: "m\(i)", rawText: text)
                item.state = "kept"
                item.kind = "email"
                item.cleanText = text
                item.authoredAt = Self.date(year: 2021, month: 3, day: 10)
                try item.insert(dbc)
            }
        }

        let defaultTimelines = try await ContaminationScan.run(db)
        #expect(defaultTimelines.isEmpty, "2 items is below the default minItemsPerMonth of 3")

        var lowered = ScanSettings()
        lowered.minItemsPerMonth = 2
        let loweredTimelines = try await ContaminationScan.run(db, settings: lowered)
        let email = try #require(loweredTimelines.first { $0.medium == "email" })
        #expect(email.months.count == 1)
    }

    /// `settings.baselineEraMonth` threads into `run()`'s
    /// `baselineEndIndex`/`baselineIsWeak` calls -- moving the era cutoff
    /// earlier than any month in the fixture forces the first-half fallback
    /// baseline, flipping `baselineIsWeak` from false to true relative to
    /// the default cutoff, on the exact same corpus.
    @Test func baselineEraMonthSettingThreadsIntoRun() async throws {
        let db = try seededDB()
        let defaultTimelines = try await ContaminationScan.run(db)
        let defaultEmail = try #require(defaultTimelines.first { $0.medium == "email" })
        #expect(!defaultEmail.baselineIsWeak)

        var earlyEra = ScanSettings()
        earlyEra.baselineEraMonth = "2019-01"
        let earlyTimelines = try await ContaminationScan.run(db, settings: earlyEra)
        let earlyEmail = try #require(earlyTimelines.first { $0.medium == "email" })
        #expect(earlyEmail.baselineIsWeak)
    }

    @Test func progressCallbackIsInvoked() async throws {
        let db = try seededDB()

        // Just verify that run() works with a progress callback
        // and doesn't crash. The callback signature is what matters here.
        let timelines = try await ContaminationScan.run(db) { processed, total in
            // Callback is invoked; we just verify it doesn't crash
            _ = (processed, total)
        }

        // Verify that the scan still produces results when progress callback is used
        #expect(!timelines.isEmpty, "Scan with progress callback should produce results")
        let email = try #require(timelines.first { $0.medium == "email" })
        #expect(email.months.count == 10, "Email medium should have 10 months of data")
    }

    /// Root cause of the "progress bar hits N/N, then nothing appears for a
    /// long stretch" symptom: `run()` used to report progress only while
    /// bucketing rows by medium/month (cheap), then spend the bulk of its
    /// time computing per-month metrics (em-dash/tic-lexicon scanning across
    /// every kept item's text) with zero further progress calls -- so the
    /// bar already read "done" while the real work was still running.
    /// Progress must span the metrics phase too, so the bar doesn't lie
    /// about completion.
    @Test func progressSpansMetricsPhaseNotJustBucketing() async throws {
        let db = try seededDB()
        // 6 baseline months * 4 + 4 contaminated months * 4 = 40 kept items.
        let itemCount = 40

        final class Calls: @unchecked Sendable {
            private var values: [(Int, Int)] = []
            func record(_ processed: Int, _ total: Int) { values.append((processed, total)) }
            func snapshot() -> [(Int, Int)] { values }
        }
        let calls = Calls()
        let timelines = try await ContaminationScan.run(db) { processed, total in
            calls.record(processed, total)
        }
        #expect(!timelines.isEmpty)

        let recorded = calls.snapshot()
        #expect(recorded.count > itemCount, "Metrics phase must also report progress")

        // The bucketing-phase progress calls (the first `itemCount` of them)
        // must not already claim completion -- there's still a whole metrics
        // pass left to run at that point.
        let bucketingPhase = recorded.prefix(itemCount)
        #expect(bucketingPhase.allSatisfy { $0.0 != $0.1 })

        // The scan is only truly done on the last call.
        let last = try #require(recorded.last)
        #expect(last.0 == last.1)
    }
}
