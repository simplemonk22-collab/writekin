import Testing
import Foundation
import GRDB
@testable import Writekin

/// Fixture notes: a single "kept" email item (audience "friend", mode
/// "casual", account 1) large enough to serve as an exemplar via the
/// ExemplarRetriever fill-up path, matching `Self.register` in every test
/// unless noted.
struct ComposeEngineTests {
    private func seedItem(_ db: AppDatabase) throws {
        try db.writer.write { dbc in
            var source = Source(id: nil, kind: "apple_mail", configJson: "{}", lastSyncedAt: nil)
            try source.insert(dbc)
            var account = Account(id: nil, addressOrHandle: "friend@example.com")
            try account.insert(dbc)

            let words = (0..<45).map { "word\($0)" }.joined(separator: " ")
            var item = Item(id: nil, sourceId: source.id!, accountId: account.id!,
                             externalId: UUID().uuidString, kind: "email",
                             authoredAt: Date(timeIntervalSince1970: 1000),
                             recipientsJson: "[]", threadId: nil, rawText: words,
                             cleanText: words, wordCount: nil, lang: "en",
                             sha256: UUID().uuidString, simhash64: nil, provenance: "native",
                             state: "kept", dropReason: nil, medium: nil, audience: "friend",
                             mode: "casual", labelSource: nil, qualityScore: nil,
                             dateConfidence: nil)
            try item.insert(dbc)
        }
    }

    private static let register = RegisterQuery(
        medium: "email", audience: "friend", mode: "casual", accountID: 1)

    @Test func systemContainsTagLineAndProfileFragment() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let fake = FakeGenerator(script: ["Rewritten output text."])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "test-model")

        let request = ComposeRequest(draft: "Original draft text.", register: Self.register)
        _ = try await engine.compose(request) { _ in }

        let prompt = try #require(fake.receivedPrompts.first)
        #expect(prompt.system.contains("[medium: email] [audience: friend] [mode: casual]"))
        #expect(prompt.system.contains("Contractions:"))
        #expect(prompt.system.hasPrefix(
            "You rewrite drafts in the author's personal voice. Preserve the "
            + "draft's meaning and facts; change only expression."))
    }

    @Test func messagesAlternateAndEndWithDraft() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let fake = FakeGenerator(script: ["Rewritten output text."])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "test-model")

        let request = ComposeRequest(draft: "Original draft text.", register: Self.register)
        _ = try await engine.compose(request) { _ in }

        let prompt = try #require(fake.receivedPrompts.first)
        // Exemplars are system-context reference material in BOTH modes now;
        // the conversation is exactly one user turn ending with the draft.
        #expect(prompt.messages.count == 1)
        let last = try #require(prompt.messages.last)
        #expect(last.role == "user")
        #expect(last.text == "Rewrite this draft in my voice, keeping its meaning:\n\nOriginal draft text.")
        #expect(prompt.system.contains("word0"))   // the seeded exemplar text moved into system
    }

    @Test func streamsAndReturnsGeneratedText() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let fake = FakeGenerator(script: ["Rewritten output text."])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "test-model")

        nonisolated(unsafe) var streamed = ""
        let request = ComposeRequest(draft: "Original draft text.", register: Self.register)
        let result = try await engine.compose(request) { streamed += $0 }

        #expect(result == "Rewritten output text.")
        #expect(streamed == result)
    }

    @Test func recordsGenerationFingerprint() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let fake = FakeGenerator(script: ["Rewritten output text."])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "test-model-ref")

        let request = ComposeRequest(draft: "Original draft text.", register: Self.register)
        let result = try await engine.compose(request) { _ in }

        let row = try await db.writer.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT * FROM generations ORDER BY id DESC LIMIT 1")
        }
        let row2 = try #require(row)
        #expect(row2["sha256"] as String? == sha256Hex(canonicalize(result)))
        #expect(row2["simhash64"] as Int64? == simhash64(of: result))
        #expect(row2["register"] as String? == "[medium: email] [audience: friend] [mode: casual]")
        #expect(row2["model_ref"] as String? == "test-model-ref")
        #expect(row2["created_at"] as Date? != nil)
    }

    @Test func rewriteModeIsDefaultAndPromptShapeIsPinned() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let fake = FakeGenerator(script: ["Rewritten output text."])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "test-model")

        // No `mode:` argument — pins that the default stays `.rewrite`.
        // Exemplars deliberately live in the SYSTEM context in rewrite mode
        // too (reference-only): as few-shot chat turns, a draft whose
        // vocabulary matched a strong exemplar made the model COPY the
        // exemplar verbatim (it emitted the author's actual résumé) instead
        // of rewriting the draft.
        let request = ComposeRequest(draft: "Original draft text.", register: Self.register)
        _ = try await engine.compose(request) { _ in }

        let prompt = try #require(fake.receivedPrompts.first)
        #expect(prompt.system.hasPrefix(
            "You rewrite drafts in the author's personal voice."))
        #expect(prompt.system.contains("Never copy sentences or facts from the writing examples"))
        #expect(prompt.system.contains("Examples of the author's real writing"))
        #expect(prompt.messages.count == 1)
        let last = try #require(prompt.messages.last)
        #expect(last.text == "Rewrite this draft in my voice, keeping its meaning:\n\nOriginal draft text.")
    }

    @Test func avoidPhrasesAppearInSystemForBothModes() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        for mode in [ComposeMode.rewrite, .generate] {
            let fake = FakeGenerator(script: ["Output."])
            let engine = ComposeEngine(db: db, generator: fake, modelRef: "m",
                                       avoidPhrases: ["blend", "delve"])
            let request = ComposeRequest(draft: "Some text.", register: Self.register, mode: mode)
            _ = try await engine.compose(request) { _ in }
            let prompt = try #require(fake.receivedPrompts.first)
            #expect(prompt.system.contains("even when the draft or instruction contains them"))
            #expect(prompt.system.contains("in any form (no -s, -ed, -ing"))
            #expect(prompt.system.contains("say it: blend, delve."))
        }
    }

    @Test func generateModePromptAsksToWriteNotRewrite() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let fake = FakeGenerator(script: ["Fresh generated text."])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "test-model")

        let instruction = "a short text telling Dana dinner moved to 8"
        let request = ComposeRequest(
            draft: instruction, register: Self.register, mode: .generate)
        _ = try await engine.compose(request) { _ in }

        let prompt = try #require(fake.receivedPrompts.first)
        // Same system context as rewrite mode: tags + style profile block.
        #expect(prompt.system.contains("[medium: email] [audience: friend] [mode: casual]"))
        #expect(prompt.system.contains("Contractions:"))

        let last = try #require(prompt.messages.last)
        #expect(last.text.contains(instruction))
        #expect(!last.text.contains("Rewrite this draft"))
        #expect(!prompt.system.contains("rewrite drafts"))
        // The anti-restate directive is load-bearing: without it a small
        // model "writes this in my voice" by casualizing the instruction
        // text itself instead of following it.
        #expect(last.text.contains("Instruction: "))
        #expect(last.text.contains("Do not restate the instruction"))
        #expect(prompt.system.contains("Never repeat, rephrase, or rewrite the instruction"))
        // Exemplars live in the SYSTEM context in generate mode — as chat
        // turns they form a rewrite-shaped few-shot pattern that out-pulls
        // the instruction. The instruction must be the only chat turn.
        #expect(prompt.messages.count == 1)
        #expect(prompt.system.contains("Examples of the author's real writing"))
    }

    @Test func generateModeRecordsFingerprintOfGeneratedText() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let fake = FakeGenerator(script: ["Fresh generated text."])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "test-model-ref")

        let request = ComposeRequest(
            draft: "a short text telling Dana dinner moved to 8",
            register: Self.register, mode: .generate)
        let result = try await engine.compose(request) { _ in }

        let row = try await db.writer.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT * FROM generations ORDER BY id DESC LIMIT 1")
        }
        let row2 = try #require(row)
        #expect(row2["sha256"] as String? == sha256Hex(canonicalize(result)))
        #expect(row2["simhash64"] as Int64? == simhash64(of: result))
        #expect(row2["model_ref"] as String? == "test-model-ref")
    }

    @Test func emptyRegisterOmitsAllTagDims() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let fake = FakeGenerator(script: ["Rewritten output text."])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "test-model")

        let emptyRegister = RegisterQuery(medium: nil, audience: nil, mode: nil, accountID: nil)
        let request = ComposeRequest(draft: "Original draft text.", register: emptyRegister)
        _ = try await engine.compose(request) { _ in }

        let prompt = try #require(fake.receivedPrompts.first)
        #expect(!prompt.system.contains("[medium:"))
        #expect(!prompt.system.contains("[audience:"))
        #expect(!prompt.system.contains("[mode:"))

        let row = try await db.writer.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT * FROM generations ORDER BY id DESC LIMIT 1")
        }
        let row2 = try #require(row)
        #expect((row2["register"] as String?) == "")
    }

    /// A leaked avoid-word is fixed by WORD SURGERY: the model supplies
    /// only the replacement, the splice is mechanical — every other
    /// character of the output is byte-identical (the past→next regression
    /// class is structurally impossible).
    @Test func leakedAvoidWordIsRepairedBySurgicalReplacement() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let fake = FakeGenerator(script: [
            "Over the past 7 years we blended AI with web apps. It works.",
            "combined"])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "m",
                                   avoidPhrases: ["blend"])
        let request = ComposeRequest(draft: "Summarize.", register: Self.register)
        let final = try await engine.compose(request) { _ in }
        #expect(final == "Over the past 7 years we combined AI with web apps. It works.")
        let replacementPrompt = fake.receivedPrompts[1]
        #expect(replacementPrompt.system.contains("\"blended\""))
        #expect(replacementPrompt.messages.last?.text
                == "Over the past 7 years we blended AI with web apps")
    }

    /// Multiple occurrences are fixed one at a time; a capitalized match
    /// gets a capitalized replacement.
    @Test func multipleLeaksAreEachReplacedWithCasePreserved() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let fake = FakeGenerator(script: [
            "Blend the colors. Then we blend the sounds.",
            "mix", "mix"])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "m",
                                   avoidPhrases: ["blend"])
        let request = ComposeRequest(draft: "Explain.", register: Self.register)
        let final = try await engine.compose(request) { _ in }
        #expect(final == "Mix the colors. Then we mix the sounds.")
    }

    /// An unusable suggestion (itself banned) ends enforcement with the
    /// original text intact — never a mangled splice.
    @Test func bannedSuggestionKeepsOriginalText() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let fake = FakeGenerator(script: ["We blended the ideas.", "blending"])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "m",
                                   avoidPhrases: ["blend"])
        let request = ComposeRequest(draft: "Combine.", register: Self.register)
        let final = try await engine.compose(request) { _ in }
        #expect(final == "We blended the ideas.")
        #expect(fake.receivedPrompts.count == 2)   // one attempt, then stop
    }

    @Test func leakOccurrenceFindsMatchAndSentence() throws {
        let text = "First sentence. We blended things here! Last part."
        let leak = try #require(ComposeEngine.firstLeakOccurrence(
            in: text, avoidWords: ["blend"]))
        #expect(leak.matched == "blended")
        #expect(leak.sentence == "We blended things here")
        #expect(ComposeEngine.firstLeakOccurrence(in: "all clean", avoidWords: ["blend"]) == nil)
    }

    /// The observed failure shape: asked for one word, the adapter rewrote
    /// the whole sentence with "mix" in blend's slot — extraction pulls
    /// "mix" out and the engine splices it, rest byte-identical.
    @Test func sentenceShapedReplyStillYieldsTheWord() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let output = "Over the past 7+ years, I delivered projects that blend AI with web apps. More text."
        let reply = "Over the past 7+ years, I delivered projects that mix AI with web apps"
        let fake = FakeGenerator(script: [output, reply])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "m",
                                   avoidPhrases: ["blend"])
        let request = ComposeRequest(draft: "Summarize.", register: Self.register)
        let final = try await engine.compose(request) { _ in }
        #expect(final == "Over the past 7+ years, I delivered projects that mix AI with web apps. More text.")
    }

    @Test func extractReplacementAlignsChangedSlot() {
        let original = "I delivered projects that blend AI with web apps"
        #expect(ComposeEngine.extractReplacement(
            originalSentence: original,
            reply: "I delivered projects that mix AI with web apps",
            matched: "blend") == "mix")
        // Multi-word replacement in the slot.
        #expect(ComposeEngine.extractReplacement(
            originalSentence: original,
            reply: "I delivered projects that bring together AI with web apps",
            matched: "blend") == "bring together")
        // Truncated reply (suffix never matches) → nil, not a guess.
        #expect(ComposeEngine.extractReplacement(
            originalSentence: original,
            reply: "I delivered projects that mix",
            matched: "blend") == nil)
        // Rewrite that changed unrelated words too → nil.
        #expect(ComposeEngine.extractReplacement(
            originalSentence: original,
            reply: "I shipped several efforts that mix AI plus web apps",
            matched: "blend") == nil)
        // Changed slot doesn't contain the banned word → nil.
        #expect(ComposeEngine.extractReplacement(
            originalSentence: original,
            reply: "I delivered projects that blend AI with web tools",
            matched: "blend") == nil)
    }

    /// Chunks always reassemble to the exact original — the mechanical
    /// guarantee the chunked rewrite is built on.
    @Test func chunkDraftReassemblesByteForByte() {
        let draft = """
        First sentence here. Second one follows! A third sentence with more words in it?

        New paragraph starts. It keeps going with several more words to cross the target. \
        And continues past the boundary for good measure. Then ends.
        """
        let chunks = ComposeEngine.chunkDraft(draft, targetWords: 12)
        #expect(chunks.count > 1)
        #expect(chunks.joined() == draft)
        // Short drafts stay whole.
        #expect(ComposeEngine.chunkDraft("Tiny note.", targetWords: 50) == ["Tiny note."])
    }

    /// Long rewrites go chunk by chunk: each prompt carries the full draft
    /// as read-only context, later prompts carry the rewritten-so-far text,
    /// and the pieces reassemble with original separators.
    @Test func longRewriteIsChunkedWithRollingContext() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let sentence = "This sentence pads the draft with exactly ten filler words."
        let draft = Array(repeating: sentence, count: 12).joined(separator: " ")   // ~120 words
        // Replies sized like real chunk rewrites (the per-chunk sanity
        // check rejects collapsed pieces — that's a separate test).
        let pieceOne = "Piece ONE rewritten: " + Array(repeating: "alpha", count: 30).joined(separator: " ") + "."
        let pieceTwo = "Piece TWO rewritten: " + Array(repeating: "beta", count: 30).joined(separator: " ") + "."
        let fake = FakeGenerator(script: [pieceOne, pieceTwo])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "m")
        let request = ComposeRequest(draft: draft, register: Self.register)
        let final = try await engine.compose(request) { _ in }
        #expect(fake.receivedPrompts.count >= 2)
        #expect(final.contains("Piece ONE rewritten"))
        #expect(final.contains("Piece TWO rewritten"))
        let first = fake.receivedPrompts[0]
        #expect(first.system.contains("one part at a time"))
        #expect(first.system.contains("for context only"))
        #expect(first.system.contains(sentence))   // full draft present
        let second = fake.receivedPrompts[1]
        #expect(second.system.contains("Already rewritten so far"))
        #expect(second.system.contains("Piece ONE rewritten"))
    }

    /// The chunked path streams ACCEPTED parts, not raw model tokens — so
    /// the live text a user watches is byte-identical to the final result
    /// (the raw token feed showed glued, echo-riddled soup).
    @Test func chunkedStreamMatchesFinalExactly() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let sentence = "This sentence pads the draft with exactly ten filler words."
        let draft = "## Heading\n\n"
            + Array(repeating: sentence, count: 12).joined(separator: " ")
        let piece = "Rewritten: " + Array(repeating: "alpha", count: 30).joined(separator: " ") + "."
        let fake = FakeGenerator(script: [piece, piece])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "m")
        nonisolated(unsafe) var streamed = ""
        // .sections: auto would one-pass this draft now that it contains
        // structure (see autoOnePassesStructuredDrafts).
        let final = try await engine.compose(
            ComposeRequest(draft: draft, register: Self.register,
                           rewriteStyle: .sections)) { streamed += $0 }
        #expect(streamed == final)
        #expect(final.hasPrefix("## Heading\n\n"))   // structure passed through
    }

    /// Auto style one-passes STRUCTURED documents (chunking a markdown doc
    /// is slow and echo-prone); long plain prose still chunks.
    @Test func autoOnePassesStructuredDrafts() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let sentence = "This sentence pads the draft with exactly ten filler words."
        let structured = "## Heading\n\n"
            + Array(repeating: sentence, count: 12).joined(separator: " ")
        let fake = FakeGenerator(script: [
            "One-pass rewrite: "
                + Array(repeating: sentence, count: 6).joined(separator: " ")])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "m")
        _ = try await engine.compose(
            ComposeRequest(draft: structured, register: Self.register)) { _ in }
        #expect(fake.receivedPrompts.count == 1)
    }

    /// Every generation reports a phase timing — the observations the
    /// per-phase realize ETA learns from. Chunked runs emit one `.chunk`
    /// per prose segment; one-pass runs emit `.onePass`.
    @Test func generationsEmitPhaseTimings() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let sentence = "This sentence pads the draft with exactly ten filler words."
        let draft = Array(repeating: sentence, count: 12).joined(separator: " ")
        let piece = "Rewritten: " + Array(repeating: "alpha", count: 30).joined(separator: " ") + "."
        let fake = FakeGenerator(script: [piece, piece])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "m")
        nonisolated(unsafe) var timings: [ComposeTimings.PhaseTiming] = []
        _ = try await engine.compose(
            ComposeRequest(draft: draft, register: Self.register,
                           rewriteStyle: .sections),
            onTiming: { timings.append($0) }) { _ in }
        #expect(timings.count == fake.receivedPrompts.count)
        #expect(timings.allSatisfy { $0.kind == .chunk && $0.units > 0 })
    }

    /// A reply shares almost no content words with the draft; a rewrite
    /// keeps most of them — the overlap heuristic behind the anti-reply
    /// guard.
    @Test func looksLikeReplyDetectsAnswersNotRewrites() {
        let draft = "Adds a single-line text field to the top of the popover where you "
            + "can type an event naturally and have the fields filled automatically."
        #expect(ComposeEngine.looksLikeReply(
            draft: draft,
            output: "This is amazing! Super helpful for me. Just one question — how "
                + "hard would it be to make this work in another language?"))
        #expect(!ComposeEngine.looksLikeReply(
            draft: draft,
            output: "Adds a single-line text field at the popover's top so you can "
                + "type an event naturally and the fields get filled automatically."))
        // Tiny drafts: overlap is meaningless, never flagged.
        #expect(!ComposeEngine.looksLikeReply(draft: "Sounds good, see you then.",
                                              output: "Great, thanks!"))
    }

    /// A one-pass rewrite that comes back as a REPLY retries once with the
    /// hardened instruction; a good retry is returned.
    @Test func onePassReplyRetriesWithHardenedPrompt() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let sentence = "This sentence pads the draft with exactly ten filler words."
        let draft = Array(repeating: sentence, count: 10).joined(separator: " ")
        let reply = "This is amazing! Just one question — could it work in Spanish?"
        let rewrite = "Rewritten piece: "
            + Array(repeating: sentence, count: 10).joined(separator: " ")
        let fake = FakeGenerator(script: [reply, rewrite])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "m")
        let final = try await engine.compose(
            ComposeRequest(draft: draft, register: Self.register,
                           rewriteStyle: .onePass)) { _ in }
        #expect(final.contains("Rewritten piece"))
        #expect(fake.receivedPrompts.count == 2)
        #expect(fake.receivedPrompts[1].system.contains("MATERIAL to rewrite"))
    }

    /// Two replies in a row surface an honest error instead of shipping a
    /// conversation nobody asked for.
    @Test func onePassReplyTwiceThrows() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let sentence = "This sentence pads the draft with exactly ten filler words."
        let draft = Array(repeating: sentence, count: 10).joined(separator: " ")
        let reply = "This is amazing! Just one question — could it work in Spanish?"
        let fake = FakeGenerator(script: [reply, reply])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "m")
        await #expect(throws: ComposeEngine.ComposeError.repliedInsteadOfRewriting) {
            _ = try await engine.compose(
                ComposeRequest(draft: draft, register: Self.register,
                               rewriteStyle: .onePass)) { _ in }
        }
    }

    /// Punctuation/case/whitespace differences alone mean the model echoed
    /// the draft — real rephrasing never survives the normalization equal.
    @Test func rewriteCameBackUnchangedIgnoresPunctuationAndCase() {
        let draft = "Adds a `single-line` field to the popover. It fills the fields for you."
        #expect(ComposeEngine.rewriteCameBackUnchanged(
            draft: draft,
            output: "Adds a single-line field to the popover. It fills the fields for you"))
        #expect(ComposeEngine.rewriteCameBackUnchanged(
            draft: draft,
            output: "adds a single-line field to the popover it fills the fields for you."))
        #expect(!ComposeEngine.rewriteCameBackUnchanged(
            draft: draft,
            output: "Adds a single-line field to the popover that fills every field for you."))
    }

    /// An echoed one-pass rewrite retries once with the anti-echo nudge; a
    /// real rephrase from the retry is used. A second echo stands (with the
    /// UI notice) — never an error, and never a forced paraphrase.
    @Test func onePassEchoRetriesWithNudge() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let sentence = "This sentence pads the draft with exactly ten filler words."
        let draft = Array(repeating: sentence, count: 10).joined(separator: " ")
        let rephrase = "Rephrased: " + Array(repeating: sentence, count: 10).joined(separator: " ")
        let fake = FakeGenerator(script: [draft, rephrase])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "m")
        let final = try await engine.compose(
            ComposeRequest(draft: draft, register: Self.register,
                           rewriteStyle: .onePass)) { _ in }
        #expect(final.contains("Rephrased"))
        #expect(fake.receivedPrompts.count == 2)
        #expect(fake.receivedPrompts[1].system.contains("Do not copy the draft verbatim"))

        let stubborn = FakeGenerator(script: [draft, draft])
        let stubbornEngine = ComposeEngine(db: db, generator: stubborn, modelRef: "m")
        let echoed = try await stubbornEngine.compose(
            ComposeRequest(draft: draft, register: Self.register,
                           rewriteStyle: .onePass)) { _ in }
        #expect(ComposeEngine.rewriteCameBackUnchanged(draft: draft, output: echoed))
    }

    /// `autoPath` is the ONE shared decision behind both the engine's
    /// chunked-vs-one-pass choice and the UI's "Auto → …" caption.
    @Test func autoPathClassifiesDrafts() {
        let sentence = "This sentence pads the draft with exactly ten filler words."
        #expect(ComposeEngine.autoPath(for: "Quick note about lunch plans today.")
            == .onePassShort)
        #expect(ComposeEngine.autoPath(
            for: "## Heading\n\n" + Array(repeating: sentence, count: 12)
                .joined(separator: " "))
            == .onePassStructured)
        #expect(ComposeEngine.autoPath(
            for: Array(repeating: sentence, count: 12).joined(separator: " "))
            == .chunkedLongProse)
    }

    /// One-pass output budget scales with draft length (a 700-word doc
    /// truncated at the old flat 1024), bounded on both ends.
    @Test func onePassMaxTokensScalesWithDraft() {
        #expect(ComposeEngine.onePassMaxTokens(for: "short draft") == 1024)
        let long = Array(repeating: "word", count: 700).joined(separator: " ")
        #expect(ComposeEngine.onePassMaxTokens(for: long) == 2100)
        let huge = Array(repeating: "word", count: 3000).joined(separator: " ")
        #expect(ComposeEngine.onePassMaxTokens(for: huge) == 4096)
    }

    /// A prose chunk's output can never legitimately BEGIN with structure —
    /// leading heading/fence/comment/blank lines are context echo and get
    /// stripped (the doubled-"## Summary" bug); interior lines survive.
    @Test func stripStructuralPrefixDropsLeadingStructureOnly() {
        #expect(ComposeEngine.stripStructuralPrefix(
            from: "## Summary\n\nAdds a field to the popover.")
            == "Adds a field to the popover.")
        #expect(ComposeEngine.stripStructuralPrefix(
            from: "Prose first. Then a heading:\n## Later")
            == "Prose first. Then a heading:\n## Later")
        #expect(ComposeEngine.stripStructuralPrefix(from: "## Only structure") == "")
    }

    /// A chunk that merely replays the previous chunk's rewrite (visible in
    /// its rolling context) is treated as empty and falls back to the
    /// original chunk — never a duplicated sentence in the output.
    @Test func stripLeadingEchoCatchesContextReplay() {
        let previous = "I got a good sense of the flow here."
        // Echo + continuation: continuation survives.
        #expect(ComposeEngine.stripLeadingEcho(
            of: previous, from: previous + " And then some new words.")
            == "And then some new words.")
        // Pure echo (byte-exact or reflowed): empty, so sanity rejects it.
        #expect(ComposeEngine.stripLeadingEcho(of: previous, from: previous) == "")
        #expect(ComposeEngine.stripLeadingEcho(
            of: previous, from: "I got a good  sense of\nthe flow here.") == "")
        // Unrelated pieces pass untouched.
        #expect(ComposeEngine.stripLeadingEcho(of: previous, from: "Fresh text.")
            == "Fresh text.")
        #expect(ComposeEngine.stripLeadingEcho(of: "", from: "Fresh text.") == "Fresh text.")
    }

    /// A chunk whose rewrite collapses is kept as ORIGINAL text — the
    /// blast radius of a bad generation is one chunk.
    @Test func collapsedChunkFallsBackToOriginal() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let sentence = "This sentence pads the draft with exactly ten filler words."
        let draft = Array(repeating: sentence, count: 12).joined(separator: " ")
        // Every chunk rewrite collapses to two words.
        let fake = FakeGenerator(script: ["Too short."])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "m")
        let request = ComposeRequest(draft: draft, register: Self.register)
        let final = try await engine.compose(request) { _ in }
        #expect(final == draft)   // all chunks fell back
    }

    /// The style knob overrides auto in both directions: onePass keeps a
    /// long draft single-generation; sections chunks a mid-length one.
    @Test func rewriteStyleKnobOverridesAuto() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let sentence = "This sentence pads the draft with exactly ten filler words."
        let longDraft = Array(repeating: sentence, count: 12).joined(separator: " ")

        // The fake "rewrite" must reuse the draft's content words or the
        // anti-reply guard (correctly) flags it as an answer.
        let onePassFake = FakeGenerator(script: [
            "Single-shot rewrite: "
                + Array(repeating: sentence, count: 6).joined(separator: " ")])
        let onePassEngine = ComposeEngine(db: db, generator: onePassFake, modelRef: "m")
        _ = try await onePassEngine.compose(
            ComposeRequest(draft: longDraft, register: Self.register,
                           rewriteStyle: .onePass)) { _ in }
        #expect(onePassFake.receivedPrompts.count == 1)

        let midDraft = Array(repeating: sentence, count: 6).joined(separator: " ") // ~60 words
        let piece = Array(repeating: "gamma", count: 25).joined(separator: " ") + "."
        let sectionsFake = FakeGenerator(script: [piece])
        let sectionsEngine = ComposeEngine(db: db, generator: sectionsFake, modelRef: "m")
        _ = try await sectionsEngine.compose(
            ComposeRequest(draft: midDraft, register: Self.register,
                           rewriteStyle: .sections)) { _ in }
        #expect(sectionsFake.receivedPrompts.count > 1)
    }

    /// Markdown structure never reaches the model (regression: sending
    /// "## Summary" as a 2-word chunk let an echo-and-continue reply pass
    /// the tiny-chunk sanity window and duplicate the document's opening).
    /// Headings, fenced code, HTML comments, and blank lines are
    /// passthrough segments; prose paragraphs are the only rewrite ones —
    /// and reassembly stays byte-exact.
    @Test func chunkSegmentsPassMarkdownStructureThrough() {
        let draft = """
        ## Summary

        Adds a single-line text field to the top of the popover where you \
        can type an event the way you would say it out loud and have the \
        app fill in every field for you without touching the mouse at all.

        ```
        Meeting with Bob at Cafe Luna for 30 minutes this Friday at 2pm
        ```

        <!-- screenshot: quick-entry field -->

        As you type, recognized pieces of the phrase are underlined in the \
        field with a color per field type so you can tell at a glance \
        whether it understood you correctly before you commit to it.
        """
        let segments = ComposeEngine.chunkSegments(draft)
        #expect(segments.map(\.text).joined() == draft)
        let rewritten = segments.filter(\.rewrite).map(\.text)
        // Exactly the two prose paragraphs get rewritten…
        #expect(rewritten.count == 2)
        #expect(rewritten.allSatisfy { $0.hasPrefix("Adds") || $0.hasPrefix("As you type") })
        // …and no structure text is ever in a rewrite segment.
        #expect(!rewritten.contains { $0.contains("##") || $0.contains("```")
            || $0.contains("<!--") || $0.contains("Meeting with Bob at Cafe Luna") })
    }

    /// A fenced block's CONTENTS pass through even when they look like
    /// prose, and short fragments (under `minRewriteChunkWords`) are never
    /// sent for rewriting.
    @Test func chunkSegmentsSkipShortFragments() {
        let draft = "Ok.\n\nThis sentence is long enough to be worth actually rewriting in voice."
        let segments = ComposeEngine.chunkSegments(draft)
        #expect(segments.map(\.text).joined() == draft)
        let rewritten = segments.filter(\.rewrite).map(\.text)
        #expect(rewritten.count == 1)
        #expect(rewritten.first?.hasPrefix("This sentence") == true)
    }

    /// CJK full-width terminators split sentences too (i18n Tier A) —
    /// and reassembly stays byte-exact.
    @Test func chunkDraftSplitsOnCJKTerminators() {
        let draft = "これは最初の文です。二つ目の文はもっと長くなります。三つ目です！最後の文ですか？"
        let chunks = ComposeEngine.chunkDraft(draft, targetWords: 1)
        #expect(chunks.count > 1)
        #expect(chunks.joined() == draft)
    }

    @Test func promptsCarryLanguageClauses() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let fake = FakeGenerator(script: ["Rewritten output text."])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "m")
        _ = try await engine.compose(
            ComposeRequest(draft: "Original draft text.", register: Self.register)) { _ in }
        #expect(fake.receivedPrompts.first?.system
            .contains("same language as the draft") == true)
    }

    @Test func lengthAffinityOrderPrefersCloseness() {
        // target 100: counts 12, 95, 400, 110 → 95, 110, 12, 400
        #expect(ExemplarRetriever.lengthAffinityOrder(wordCounts: [12, 95, 400, 110],
                                                      target: 100) == [1, 3, 0, 2])
    }

    @Test func replacementSanitizerStripsCeremony() {
        #expect(ComposeEngine.sanitizeReplacement("\"combined\".\n") == "combined")
        #expect(ComposeEngine.sanitizeReplacement("  mixed together, ") == "mixed together")
        #expect(ComposeEngine.isValidReplacement("combined", avoidWords: ["blend"]))
        #expect(!ComposeEngine.isValidReplacement("blending", avoidWords: ["blend"]))
        #expect(!ComposeEngine.isValidReplacement("", avoidWords: ["blend"]))
        #expect(!ComposeEngine.isValidReplacement("a whole new sentence rewritten entirely here",
                                                  avoidWords: ["blend"]))
    }

    /// No leak → no second generation (the cleanup pass costs nothing when
    /// the ban held).
    @Test func cleanOutputSkipsCleanupPass() async throws {
        let db = try AppDatabase.inMemory()
        try seedItem(db)
        let fake = FakeGenerator(script: ["We combined the two ideas."])
        let engine = ComposeEngine(db: db, generator: fake, modelRef: "m",
                                   avoidPhrases: ["blend"])
        let request = ComposeRequest(draft: "Combine the ideas.", register: Self.register)
        _ = try await engine.compose(request) { _ in }
        #expect(fake.receivedPrompts.count == 1)
    }
}
