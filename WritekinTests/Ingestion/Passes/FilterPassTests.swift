import Testing
import Foundation
import GRDB
@testable import Writekin

struct FilterPassTests {
    func seed(_ db: AppDatabase, kind: String, clean: String, lang: String? = "en",
              raw: String? = nil, externalId: String = UUID().uuidString) throws {
        try db.writer.write { dbc in
            let sid: Int64
            if let s = try Source.fetchOne(dbc), let id = s.id { sid = id }
            else {
                var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
                try s.insert(dbc); sid = s.id!
            }
            var item = Item.stub(sourceId: sid, externalId: externalId,
                                 rawText: raw ?? clean)
            item.kind = kind
            item.cleanText = clean
            item.wordCount = clean.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.count
            item.lang = lang
            try item.insert(dbc)
        }
    }

    func dropReasons(_ db: AppDatabase) throws -> [String?] {
        try db.writer.read { try Item.fetchAll($0).map(\.dropReason) }
    }

    @Test func shortSMSKeptLongEnoughEmailRules() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "sms", clean: "one two three four five six seven eight")
        try seed(db, kind: "email", clean: "too short for an email")
        try FilterPass(db: db).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first { $0.kind == "sms" }?.state == "kept")
        #expect(items.first { $0.kind == "email" }?.dropReason == "too_short")
    }

    @Test func flagsNonEnglish() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "sms", clean: "hola amigo como estas hoy dime algo por favor gracias",
                 lang: "es")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["non_english"])
    }

    @Test func flagsQuoteDominated() throws {
        let db = try AppDatabase.inMemory()
        let quoted = Array(repeating: "> quoted line of text here", count: 40)
            .joined(separator: "\n")
        try seed(db, kind: "email",
                 clean: "ok sounds good to me thanks a lot see you there my friend yes",
                 raw: quoted + "\nok")
        // clean/raw ratio tiny → quote_dominated even though word count passes 8.
        var config = FilterConfig()
        config.minWordsEmailDoc = 5
        try FilterPass(db: db, config: config).run()
        #expect(try dropReasons(db) == ["quote_dominated"])
    }

    @Test func flagsURLDominated() throws {
        let db = try AppDatabase.inMemory()
        let urls = Array(repeating: "https://example.com/x", count: 20).joined(separator: " ")
        try seed(db, kind: "sms", clean: "check these " + urls)
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["url_dominated"])
    }

    @Test func flagsBoilerplate() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "email", clean: String(
            repeating: "word ", count: 40) + "this is an automatic reply while I am away")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["boilerplate"])
    }

    @Test func boilerplateMarkerDeepInLongMailIsKept() throws {
        let db = try AppDatabase.inMemory()
        // Create text with normal prose in first 300 chars (50 words) but "declined:" after char 300
        let normalProse = String(repeating: "This is normal message content that should pass the filter. ", count: 6)
        let deepMarker = String(repeating: " filler ", count: 20) + "declined: I cannot attend"
        let fullText = normalProse + deepMarker
        try seed(db, kind: "email", clean: fullText)
        try FilterPass(db: db).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first?.state == "kept")
        #expect(items.first?.dropReason == nil)
    }

    @Test func icsInviteIsBoilerplate() throws {
        let db = try AppDatabase.inMemory()
        // BEGIN:VCALENDAR at the start with 30+ words to pass minWordsEmailDoc
        let icsContent = "BEGIN:VCALENDAR VERSION:2.0 PRODID:-//Company BEGIN:VEVENT UID:123 DTSTART:20250101T100000Z DTEND:20250101T110000Z SUMMARY:Meeting LOCATION:Room DESCRIPTION:reservation confirmed with all necessary details included for scheduling purposes and calendar integration and meeting confirmation email notification sent today please"
        try seed(db, kind: "email", clean: icsContent)
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["boilerplate"])
    }

    @Test func shortUnsubscribeFooterIsBoilerplate() throws {
        let db = try AppDatabase.inMemory()
        // Case A: 30-word message with unsubscribe footer (should be boilerplate, as 30 < 60)
        let shortUnsubscribe = "unsubscribe from these alerts and notifications for product updates and marketing messages you can manage preferences and settings here thank you for using our service today and goodbye forever later"
        try seed(db, kind: "email", clean: shortUnsubscribe, externalId: "short_unsub")

        // Case B: long message (100+ words) mentioning unsubscribe early (should NOT be boilerplate as 100 > 60)
        let longMessage = "unsubscribe option available in settings " + String(repeating: "This is substantial content about our product updates and features. We provide comprehensive information and detailed explanations about our services. ", count: 3)
        try seed(db, kind: "email", clean: longMessage, externalId: "long_unsub")

        try FilterPass(db: db).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        let shortResult = items.first { $0.externalId == "short_unsub" }?.dropReason
        let longResult = items.first { $0.externalId == "long_unsub" }?.state

        #expect(shortResult == "boilerplate")
        #expect(longResult == "kept")
    }

    /// Coordinator streams "n of total" progress from the pass's cumulative
    /// callback, so it must fire more than once for a multi-batch run and end
    /// exactly at the row count.
    @Test func progressReportsIncreasingCumulativeCounts() throws {
        let db = try AppDatabase.inMemory()
        for i in 0..<1200 {
            try seed(db, kind: "sms", clean: "one two three four five six seven eight",
                    externalId: "row\(i)")
        }
        final class Counts: @unchecked Sendable {
            private var values: [Int] = []
            func record(_ n: Int) { values.append(n) }
            func snapshot() -> [Int] { values }
        }
        let counts = Counts()
        try FilterPass(db: db).run(progress: { counts.record($0) })
        let values = counts.snapshot()
        #expect(values.count >= 2)
        #expect(values == values.sorted())
        #expect(values.last == 1200)
    }

    @Test func wordleGridIsGameShare() throws {
        let db = try AppDatabase.inMemory()
        let wordle = "Wordle 1,492 4/6\n⬜🟨⬜⬜⬜\n🟩🟩⬜⬜🟩\n🟩🟩🟩🟩🟩"
        try seed(db, kind: "sms", clean: wordle)
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["game_share"])
    }

    @Test func gameShareDisabledKeepsWordleGrid() throws {
        let db = try AppDatabase.inMemory()
        let wordle = "Wordle 1,492 4/6\n⬜🟨⬜⬜⬜\n🟩🟩⬜⬜🟩\n🟩🟩🟩🟩🟩 also here are eight words to pass the length check"
        try seed(db, kind: "sms", clean: wordle)
        var config = FilterConfig()
        config.gameShareEnabled = false
        try FilterPass(db: db, config: config).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first?.state == "kept")
        #expect(items.first?.dropReason == nil)
    }

    @Test func strandsShareIsGameShare() throws {
        let db = try AppDatabase.inMemory()
        let strands = "Strands #867 \u{201C}A healthy breakfast\u{201D}\n🟡🔵🔵🔵\n🔵🔵🔵"
        try seed(db, kind: "sms", clean: strands)
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["game_share"])
    }

    @Test func mentionOfWordleInProseIsNotGameShare() throws {
        let db = try AppDatabase.inMemory()
        let prose = "we played wordle at lunch today and it was a lot of fun for everyone in the office. " +
            String(repeating: "We chatted about work and plans for the weekend and other things too. ", count: 4)
        try seed(db, kind: "email", clean: prose)
        try FilterPass(db: db).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first?.state == "kept")
        #expect(items.first?.dropReason == nil)
    }

    @Test func strandsShareWithoutColoredSquaresIsGameShare() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "sms",
                 clean: "Strands #853 \u{201C}Happy 4th of July!\u{201D} 🎆🎆🎆🎆 🇺🇸🎆")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["game_share"])
    }

    @Test func semantleShareIsGameShare() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "sms",
                 clean: "I solved Semantle #47 in 25 guesses. My first guess had a similarity of 8.07.")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["game_share"])
    }

    @Test func poopleLinkPreviewIsGameShare() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "sms",
                 clean: "https://poople.io/ Daily Word Game The game where you turn words into poop! New game every day. Can you find the shortest path?")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["game_share"])
    }

    @Test func reactionMessageIsBoilerplate() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "sms",
                 clean: "Reacted 😭 to \u{201C}that thing you said about the trip yesterday and how it all went sideways\u{201D}")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["boilerplate"])
    }

    @Test func proseStartingWithReactedIsNotBoilerplate() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "sms",
                 clean: "Reacted pretty fast when I saw the news honestly, called mom right away and we talked for an hour about what happens next")
        try FilterPass(db: db).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first?.state == "kept")
        #expect(items.first?.dropReason == nil)
    }

    @Test func pastCutoffDropsItemAuthoredAtOrAfterCutoffMonth() throws {
        let db = try AppDatabase.inMemory()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imap", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var item = Item.stub(sourceId: s.id!, externalId: "after",
                                 rawText: "plenty of real words here to pass the length checks yes indeed and then some more words follow along nicely to be safe here today thanks a bunch more good words appear right now")
            item.kind = "email"
            item.cleanText = item.rawText
            item.wordCount = 34
            item.lang = "en"
            item.authoredAt = formatter.date(from: "2023-07-15T00:00:00Z")
            try item.insert(dbc)
        }
        try FilterPass(db: db, cutoffs: ["email": "2023-06"]).run()
        #expect(try dropReasons(db) == ["past_cutoff"])
    }

    @Test func pastCutoffKeepsItemAuthoredBeforeCutoffMonth() throws {
        let db = try AppDatabase.inMemory()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imap", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var item = Item.stub(sourceId: s.id!, externalId: "before",
                                 rawText: "plenty of real words here to pass the length checks yes indeed and then some more words follow along nicely to be safe here today thanks a bunch more good words appear right now")
            item.kind = "email"
            item.cleanText = item.rawText
            item.wordCount = 34
            item.lang = "en"
            item.authoredAt = formatter.date(from: "2023-05-15T00:00:00Z")
            try item.insert(dbc)
        }
        try FilterPass(db: db, cutoffs: ["email": "2023-06"]).run()
        #expect(try dropReasons(db) == [nil])
    }

    @Test func pastCutoffOnlyAffectsConfiguredMedium() throws {
        let db = try AppDatabase.inMemory()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var item = Item.stub(sourceId: s.id!, externalId: "sms-after",
                                 rawText: "one two three four five six seven eight")
            item.kind = "sms"
            item.cleanText = item.rawText
            item.wordCount = 9
            item.lang = "en"
            item.authoredAt = formatter.date(from: "2024-01-15T00:00:00Z")
            try item.insert(dbc)
        }
        // Only "email" has a cutoff — sms is unaffected even though it's well after.
        try FilterPass(db: db, cutoffs: ["email": "2023-06"]).run()
        #expect(try dropReasons(db) == [nil])
    }

    @Test func resetFilterDecisionsRestoresPastCutoffRows() throws {
        let db = try AppDatabase.inMemory()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imap", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var item = Item.stub(sourceId: s.id!, externalId: "after",
                                 rawText: "plenty of real words here to pass the length checks yes indeed and then some more words follow along nicely to be safe here today thanks a bunch more good words appear right now")
            item.kind = "email"
            item.cleanText = item.rawText
            item.wordCount = 34
            item.lang = "en"
            item.authoredAt = formatter.date(from: "2023-07-15T00:00:00Z")
            try item.insert(dbc)
        }
        let pass = FilterPass(db: db, cutoffs: ["email": "2023-06"])
        try pass.run()
        try pass.resetFilterDecisions()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first?.state == "ingested")
        #expect(items.first?.dropReason == nil)
    }

    /// `not_your_writing` is a manual, account-level "ignore this account's
    /// mail" decision (see `AccountAdmin.excludeFromCorpus`), not a filter
    /// pass's own drop reason -- it must survive `resetFilterDecisions`
    /// exactly like an insert-time drop (`self_generated`,
    /// `format_unsupported`, etc.), never silently un-excluded by a re-tuned
    /// filter config's reset.
    @Test func resetFilterDecisionsLeavesNotYourWritingUntouched() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "email", clean: "short one")
        try db.writer.write { dbc in
            let sid = try Source.fetchOne(dbc)!.id!
            var excluded = Item.stub(sourceId: sid, externalId: "excluded", rawText: "server artifact mail")
            excluded.state = "filtered_out"; excluded.dropReason = "not_your_writing"
            try excluded.insert(dbc)
        }
        let pass = FilterPass(db: db)
        try pass.run()
        try pass.resetFilterDecisions()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first { $0.externalId == "excluded" }?.state == "filtered_out")
        #expect(items.first { $0.externalId == "excluded" }?.dropReason == "not_your_writing")
    }

    @Test func minuteCrypticIsGameShare() throws {
        let db = try AppDatabase.inMemory()
        let text = "Minute Cryptic - 2 July, 2026 \"In public? Kissing? Ew!\" (3) " +
            "⚪️🟣🟣🟣🟣🟣 🤝 1 hints – matched the community par (101,590 solvers so far)."
        try seed(db, kind: "sms", clean: text)
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["game_share"])
    }

    @Test func alphadotsShareIsGameShare() throws {
        let db = try AppDatabase.inMemory()
        let text = "I solved today's Alphadots in 2:01 and used 0 plots. " +
            "Think you can do better? Play now at bloomberg.com/alphadots"
        try seed(db, kind: "sms", clean: text)
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["game_share"])
    }

    @Test func miniCrosswordSolvedPairIsGameShare() throws {
        let db = try AppDatabase.inMemory()
        let text = "I solved the 7/18/2026 New York Times Mini Crossword in 1:41!"
        try seed(db, kind: "sms", clean: text)
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["game_share"])
    }

    @Test func iSolvedWorkEmailIsNotGameShare() throws {
        let db = try AppDatabase.inMemory()
        let text = "I solved the problem with the deployment pipeline this morning after a long debugging " +
            "session with the infra team, and I wanted to walk everyone through exactly what happened " +
            "and how we fixed it so future incidents go faster and smoother for the whole engineering group."
        try seed(db, kind: "email", clean: text)
        try FilterPass(db: db).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first?.state == "kept")
        #expect(items.first?.dropReason == nil)
    }

    @Test func crosswordMentionWithoutISolvedIsNotGameShare() throws {
        let db = try AppDatabase.inMemory()
        let text = "we did the crossword together sunday morning over coffee and it was really relaxing " +
            "and fun, we should make it a regular weekend tradition going forward from now on for sure."
        try seed(db, kind: "sms", clean: text)
        try FilterPass(db: db).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first?.state == "kept")
        #expect(items.first?.dropReason == nil)
    }

    @Test func resetRestoresOnlyFilterDecisions() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "email", clean: "short one")
        try db.writer.write { dbc in
            let sid = try Source.fetchOne(dbc)!.id!
            var pre = Item.stub(sourceId: sid, externalId: "pre", rawText: "generated")
            pre.state = "filtered_out"; pre.dropReason = "self_generated"
            try pre.insert(dbc)
        }
        let pass = FilterPass(db: db)
        try pass.run()
        try pass.resetFilterDecisions()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first { $0.externalId == "pre" }?.dropReason == "self_generated")
        #expect(items.first { $0.externalId != "pre" }?.state == "ingested")
    }

    /// The quote-ratio denominator is now fetched as SQLite's LENGTH(raw_text)
    /// (a Unicode-scalar count) instead of materializing raw_text in Swift.
    /// Pin the equivalence: SQL LENGTH == String.unicodeScalars.count even for
    /// multi-scalar emoji, and the Item-taking dropReason overload agrees with
    /// the projection-based one.
    @Test func sqlLengthMatchesUnicodeScalarCountForQuoteRatio() throws {
        let db = try AppDatabase.inMemory()
        let raw = "héllo 👋🏽 family 👨‍👩‍👧‍👦 the quoted > original text lives here below the reply"
        try seed(db, kind: "email", clean: "short reply", raw: raw)
        let sqlLength = try db.writer.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT LENGTH(raw_text) FROM items")
        }
        #expect(sqlLength == raw.unicodeScalars.count)

        let item = try db.writer.read { try Item.fetchOne($0) }!
        let candidate = try db.writer.read { dbc in
            try FilterPass.Candidate.fetchAll(dbc, sql: FilterPass.candidateSQL).first
        }!
        var config = FilterConfig()
        config.minWordsEmailDoc = 2  // reach the quote-ratio check
        let pass = FilterPass(db: db, config: config)
        #expect(pass.dropReason(for: item) == pass.dropReason(for: candidate))
        #expect(pass.dropReason(for: candidate) == "quote_dominated")
    }

    @Test func formDocumentConfidentialityAgreementFilename() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "some document text here to satisfy word count requirements for testing purposes",
                 externalId: "Confidentiality_Agreement_signed.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func formDocumentPaystubFilename() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "earnings and compensation details for employee payment processing and records management",
                 externalId: "2019-paystub-march.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func formDocument401kEnrollmentFilename() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "retirement plan enrollment information for employee benefits and investment choices today",
                 externalId: "401k-enrollment.docx")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func formDocumentBindingArbitrationContent() throws {
        let db = try AppDatabase.inMemory()
        let content = "the parties agree to binding arbitration for all disputes and claims arising from this employment relationship and agreement"
        try seed(db, kind: "doc", clean: content, externalId: "employment-contract.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func agreementInProseIsNotFormDocument() throws {
        let db = try AppDatabase.inMemory()
        let essay = "we had a great meeting with the client last week. unfortunately, we couldn't reach an agreement on the final terms. " +
            String(repeating: "the team is following up with more detailed proposals and updated pricing information for their review. ", count: 5)
        try seed(db, kind: "email", clean: essay, externalId: "client-email.msg")
        try FilterPass(db: db).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first?.state == "kept")
        #expect(items.first?.dropReason == nil)
    }
}
