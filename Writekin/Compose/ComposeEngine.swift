import Foundation
import GRDB
import os

/// Which of the two Compose flows a ``ComposeRequest`` represents. Both
/// modes share the same system context (register tag line + style profile +
/// voice exemplars) — only the final user instruction differs.
enum ComposeMode: String, Sendable {
    case rewrite
    case generate
}

/// A request to realize text in the author's voice for a given register.
/// In `.rewrite` mode `draft` is the existing text to rewrite; in
/// `.generate` mode `draft` holds the instruction describing what to write
/// (there is no existing draft to preserve the meaning of).
struct ComposeRequest: Sendable {
    var draft: String
    var register: RegisterQuery
    var mode: ComposeMode = .rewrite
    var rewriteStyle: RewriteStyle = .auto
}

/// How a rewrite is generated. `.auto` (the default — unset knobs must
/// still behave well): long drafts go section-by-section for length
/// fidelity, short ones in one pass. The explicit options exist because
/// both strategies have value — one pass maximizes global flow; sections
/// maximize length/structure fidelity on long drafts.
enum RewriteStyle: String, CaseIterable, Sendable {
    case auto, onePass, sections
}

/// GRDB record backing the `generations` table (created in migration v1),
/// used to fingerprint completed generations for later dedupe/audit.
private struct GenerationRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "generations"

    var id: Int64?
    var createdAt: Date
    var sha256: String
    var simhash64: Int64?
    var register: String?
    var modelRef: String?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case sha256
        case simhash64
        case register
        case modelRef = "model_ref"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Assembles a generation prompt from a draft plus the author's style
/// profile and best-matching exemplars, runs it through a
/// ``TextGenerating`` backend, and records a fingerprint of the output for
/// later dedupe/audit.
///
/// Prompt assembly (wording is an exact contract, pinned by tests):
/// - System message: a fixed instruction line, then a tag line built from
///   the request's non-nil register dimensions in §8 grammar order
///   (medium, audience, mode), then the style profile's `promptBlock()` —
///   each on its own line.
/// - Few-shot messages: each exemplar is preceded by a fixed "user" primer
///   message, then given as an "assistant" message with the exemplar text.
/// - Final message: a fixed "user" instruction plus the draft.
struct ComposeEngine: Sendable {
    private let db: AppDatabase
    private let generator: any TextGenerating
    private let modelRef: String
    private let profiler: StyleProfiler
    private let retriever: ExemplarRetriever
    private let avoidPhrases: [String]

    /// Sensible defaults for on-device rewrite generations: long enough for
    /// most drafts, and a temperature that stays reasonably faithful to the
    /// exemplars/profile while still varying phrasing.
    static let defaultMaxTokens = 1024
    static let defaultTemperature = 0.7

    private static let systemHeaderRewrite =
        "You rewrite drafts in the author's personal voice. Preserve the "
        + "draft's meaning and facts; change only expression. Never copy "
        + "sentences or facts from the writing examples — they show how the "
        + "author sounds, not what to say. Keep the rewrite about the same "
        + "length as the draft. Avoid assistant-flavored phrasing "
        + "(\u{201C}delve\u{201D}, \u{201C}moreover\u{201D}, \u{201C}furthermore\u{201D}, \u{201C}it's worth noting\u{201D}), "
        + "em-dash overuse, and bulleted lists unless the draft itself uses "
        + "them. Write in the same language as the draft. Output only the "
        + "rewritten text."
    private static let systemHeaderGenerate =
        "You write new text in the author's personal voice. The user gives an "
        + "instruction describing what to write; you produce the text it asks "
        + "for. Never repeat, rephrase, or rewrite the instruction itself — "
        + "answer it. Avoid assistant-flavored phrasing (\u{201C}delve\u{201D}, "
        + "\u{201C}moreover\u{201D}, \u{201C}furthermore\u{201D}, \u{201C}it's worth noting\u{201D}), em-dash "
        + "overuse, and bulleted lists unless the examples use them. Write "
        + "in the same language as the instruction. Output only the written "
        + "text."
    private static let rewriteInstructionPrefix =
        "Rewrite this draft in my voice, keeping its meaning:\n\n"
    /// Deliberately NOT "write this in my voice: <instruction>" — a small
    /// model reads "write this" as "render this text" and casualizes the
    /// instruction instead of following it (observed: "who is your favorite
    /// person" → "who is your fav person"). Task framing plus a trailing
    /// directive makes instruction-following unmistakable even against the
    /// few-shot rewrite-shaped pattern of the style exemplars.
    private static let generateInstructionPrefix = "Instruction: "
    private static let generateInstructionSuffix =
        "\n\nNow write the text that fulfills this instruction, as me, in my "
        + "voice. Do not restate the instruction — produce the text it asks for."

    /// - Parameters:
    ///   - profiler: Reuses a caller-supplied, already-warm `StyleProfiler`
    ///     (e.g. `AppEnvironment.styleProfiler`) so repeated Compose
    ///     realizations for the same register hit its cache instead of
    ///     re-scanning the kept corpus every time. Defaults to a fresh,
    ///     uncached one for callers (tests) that don't need sharing.
    ///   - retriever: Same idea; defaults to a fresh `ExemplarRetriever`.
    ///   - avoidPhrases: The user's curated not-my-voice vocabulary (the
    ///     Timeline scan's effective phrase list: enabled built-ins plus
    ///     custom additions) — Compose tells the model to avoid them, so the
    ///     words the app hunts in your history are the words it suppresses
    ///     in its output.
    init(db: AppDatabase, generator: any TextGenerating, modelRef: String,
         profiler: StyleProfiler? = nil, retriever: ExemplarRetriever? = nil,
         avoidPhrases: [String] = []) {
        self.db = db
        self.generator = generator
        self.modelRef = modelRef
        self.profiler = profiler ?? StyleProfiler(db: db)
        self.retriever = retriever ?? ExemplarRetriever(db: db)
        self.avoidPhrases = avoidPhrases
    }

    /// What the engine is doing RIGHT NOW beyond plain generation — the
    /// guards and passes that used to run invisibly behind a static
    /// "Realizing…" spinner. Typed (localized at render) so the UI can
    /// narrate honestly: a user watching a retry deserves to know the
    /// first attempt was rejected and why.
    enum Status: Sendable, Equatable {
        /// Chunked rewrite progress — 1-based over PROSE segments only
        /// (structure passes through instantly).
        case rewritingPart(index: Int, total: Int)
        /// The model answered the draft instead of rewriting — retrying
        /// with the hardened instruction.
        case retryingAfterReply
        /// The model copied the draft back — asking for a real rephrase.
        case retryingAfterEcho
        /// Post-generation word surgery on avoid-list leaks.
        case replacingAvoidedWords
    }

    func compose(
        _ request: ComposeRequest,
        onStatus: @escaping @Sendable (Status) -> Void = { _ in },
        onTiming: @escaping @Sendable (ComposeTimings.PhaseTiming) -> Void = { _ in },
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        /// Times one generation and reports it as a phase observation —
        /// feeds the per-model, per-phase ETA rates.
        func timed(_ kind: ComposeTimings.PhaseKind,
                   _ generate: () async throws -> String) async rethrows -> String {
            let clock = ContinuousClock()
            let start = clock.now
            let result = try await generate()
            let seconds = Double((clock.now - start).components.seconds)
                + Double((clock.now - start).components.attoseconds) * 1e-18
            let units = kind == .replacement
                ? 1 : max(1, result.split(whereSeparator: \.isWhitespace).count)
            onTiming(ComposeTimings.PhaseTiming(kind: kind, units: units, seconds: seconds))
            return result
        }
        let profile = try await profiler.profile(for: request.register)
        let exemplars = try await retriever.exemplars(for: request.draft, register: request.register)
        let tagLine = Self.tagLine(for: request.register)
        let prompt = Self.assemblePrompt(
            mode: request.mode, draft: request.draft, tagLine: tagLine,
            profile: profile, exemplars: exemplars, avoidPhrases: avoidPhrases)

        let output: String
        let segments = Self.chunkSegments(request.draft)
        let chunked: Bool = {
            guard request.mode == .rewrite,
                  segments.filter(\.rewrite).count > 1 else { return false }
            switch request.rewriteStyle {
            case .onePass: return false
            case .sections: return true
            case .auto:
                return Self.autoPath(for: request.draft) == .chunkedLongProse
            }
        }()
        if chunked {
            // Long-draft rewrites collapse: the adapter's chat-trained
            // length prior "corrects" 100 words down to 15. Structural fix
            // (not a retry loop): rewrite chat-sized chunks one at a time —
            // each is already near the model's comfort length, so there's
            // nothing to collapse — with the FULL draft and the rewritten-
            // so-far text as read-only context so seams connect. The
            // harness owns the structure; the model only ever writes voice —
            // structure segments (markdown headings, code fences, comments,
            // too-short fragments) are copied through without a generation.
            // The chunked path does NOT stream raw model tokens: that feed
            // interleaves every chunk's unvetted output with no structure
            // segments or whitespace tails — glued, echo-riddled soup for
            // anyone watching mid-run. Instead each ACCEPTED part streams
            // the moment it lands, so the live text is always well-formed
            // and byte-identical to the final.
            var parts: [String] = []
            var previousAccepted = ""
            let proseTotal = segments.filter(\.rewrite).count
            var proseIndex = 0
            for segment in segments {
                // A Stop press lands at the next chunk boundary — partial
                // streamed output stays (it's well-formed by construction).
                try Task.checkCancellation()
                if segment.rewrite {
                    proseIndex += 1
                    onStatus(.rewritingPart(index: proseIndex, total: proseTotal))
                }
                guard segment.rewrite else {
                    parts.append(segment.text)
                    onToken(segment.text)
                    // Structure counts as "previous" too: the model echoes
                    // a just-passed heading from its full-draft context at
                    // the start of the next prose chunk (observed as a
                    // doubled "## Summary").
                    let trimmed = segment.text
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { previousAccepted = trimmed }
                    continue
                }
                var core = segment.text
                while let last = core.last, last.isWhitespace { core.removeLast() }
                let tail = String(segment.text.dropFirst(core.count))
                let soFar = parts.joined()
                let piece = try await timed(.chunk) {
                    try await generator.generate(
                        prompt: Self.assembleChunkPrompt(
                            chunk: core, fullDraft: request.draft,
                            rewrittenSoFar: soFar, tagLine: tagLine,
                            profile: profile, exemplars: exemplars,
                            avoidPhrases: avoidPhrases),
                        maxTokens: Self.defaultMaxTokens,
                        temperature: Self.defaultTemperature, onToken: { _ in })
                }
                // Echo guards, in order: strip a replay of the previous
                // part (structure or rewrite), then any leading
                // structure-shaped lines — a prose chunk's rewrite can
                // never legitimately BEGIN with a heading/fence/comment,
                // since structure never enters a rewrite chunk. A piece
                // reduced to nothing fails the sanity floor below, so the
                // original chunk stands instead of a duplicate.
                let cleaned = Self.stripStructuralPrefix(
                    from: Self.stripLeadingEcho(
                        of: previousAccepted,
                        from: piece.trimmingCharacters(in: .whitespacesAndNewlines)))
                // Per-chunk sanity: a wildly shrunken or exploded piece is
                // discarded for the ORIGINAL chunk — blast radius of a
                // misbehaving generation is one chunk, never the draft.
                let coreWords = core.split(whereSeparator: \.isWhitespace).count
                let pieceWords = cleaned.split(whereSeparator: \.isWhitespace).count
                let sane = pieceWords >= max(3, coreWords * 2 / 5) && pieceWords <= coreWords * 4
                let accepted = sane ? cleaned : core
                previousAccepted = accepted
                parts.append(accepted + tail)
                onToken(accepted + tail)
            }
            output = parts.joined()
        } else {
            var onePass = try await timed(.onePass) {
                try await generator.generate(
                    prompt: prompt,
                    maxTokens: Self.onePassMaxTokens(for: request.draft),
                    temperature: Self.defaultTemperature, onToken: onToken)
            }
            // The chat prior sometimes wins over the rewrite instruction:
            // the model ANSWERS the draft ("This is amazing! Just one
            // question…") instead of rewriting it. A rewrite necessarily
            // reuses most of the draft's content words; a reply shares
            // almost none — so low overlap means reply, and the harness
            // retries once with a hardened instruction rather than
            // shipping a conversation nobody asked for.
            if request.mode == .rewrite,
               Self.looksLikeReply(draft: request.draft, output: onePass) {
                onStatus(.retryingAfterReply)
                let reinforced = ComposedPrompt(
                    system: prompt.system + "\n" + Self.antiReplyClause,
                    messages: prompt.messages)
                let retry = try await timed(.onePass) {
                    try await generator.generate(
                        prompt: reinforced,
                        maxTokens: Self.onePassMaxTokens(for: request.draft),
                        temperature: Self.defaultTemperature, onToken: { _ in })
                }
                guard !Self.looksLikeReply(draft: request.draft, output: retry) else {
                    throw Self.ComposeError.repliedInsteadOfRewriting
                }
                onePass = retry
            }
            // The opposite failure: the model COPIES the draft back nearly
            // verbatim (differing only in punctuation/case), doing no
            // rewriting at all. One nudged retry; if the model still
            // echoes, the echo stands and the view shows an honest
            // "nothing changed" notice (an already-in-voice draft is a
            // legitimate reason — never force a paraphrase).
            if request.mode == .rewrite,
               Self.rewriteCameBackUnchanged(draft: request.draft, output: onePass) {
                onStatus(.retryingAfterEcho)
                let nudged = ComposedPrompt(
                    system: prompt.system + "\n" + Self.antiEchoClause,
                    messages: prompt.messages)
                let retry = try await timed(.onePass) {
                    try await generator.generate(
                        prompt: nudged,
                        maxTokens: Self.onePassMaxTokens(for: request.draft),
                        temperature: Self.defaultTemperature, onToken: { _ in })
                }
                if !Self.rewriteCameBackUnchanged(draft: request.draft, output: retry),
                   !Self.looksLikeReply(draft: request.draft, output: retry) {
                    onePass = retry
                }
            }
            output = onePass
        }

        // ENFORCE the avoid-list, don't just request it: the system prompt
        // asks nicely, but a fine-tuned model (trained to imitate voice,
        // not follow instructions) leaks banned words anyway. Lesson from
        // two failed designs: never let the model REGENERATE text to fix a
        // word — a whole-text (or even whole-sentence) rewrite re-rolls
        // every token, and a temp-0 14B happily flipped "past 7+ years"
        // to "next 7+ years" while fixing "blend". Instead the model is
        // asked ONLY for a replacement word; the splice is mechanical
        // string surgery, so untouched text stays byte-identical.
        var final = output
        var budget = Self.maxWordReplacements
        Self.log.info("enforcement: avoidPhrases=\(avoidPhrases.count), leak=\(Self.firstLeakOccurrence(in: final, avoidWords: avoidPhrases)?.matched ?? "none", privacy: .public)")
        while budget > 0,
              let leak = Self.firstLeakOccurrence(in: final, avoidWords: avoidPhrases) {
            budget -= 1
            onStatus(.replacingAvoidedWords)
            // Room for a full-sentence reply: the fine-tuned adapter can't
            // follow "reply with only the word" (observed via the log: it
            // rewrites the whole sentence — with the right word in the
            // right slot). Obedient models still answer short; either
            // shape is handled below.
            let replyBudget = min(160, max(48, leak.sentence.count / 3))
            let raw = try await timed(.replacement) {
                try await generator.generate(
                    prompt: Self.replacementPrompt(word: leak.matched, sentence: leak.sentence,
                                                   tagLine: tagLine),
                    maxTokens: replyBudget, temperature: 0, onToken: { _ in })
            }
            var replacement = Self.sanitizeReplacement(raw)
            if !Self.isValidReplacement(replacement, avoidWords: avoidPhrases) {
                // Sentence-shaped reply: extract the word that changed in
                // the banned word's slot by aligning reply vs original.
                replacement = Self.extractReplacement(
                    originalSentence: leak.sentence, reply: replacement,
                    matched: leak.matched) ?? ""
            }
            let valid = Self.isValidReplacement(replacement, avoidWords: avoidPhrases)
            Self.log.info("enforcement: matched=\(leak.matched, privacy: .public) raw=\(String(raw.prefix(80)), privacy: .public) replacement=\(replacement, privacy: .public) valid=\(valid)")
            // An unusable suggestion ends enforcement (temp 0 would just
            // repeat it): the original stands, the red voice-check signal
            // reports the leak honestly.
            guard valid else { break }
            if leak.matched.first?.isUppercase == true, let first = replacement.first {
                replacement = String(first).uppercased() + replacement.dropFirst()
            }
            final.replaceSubrange(leak.range, with: replacement)
        }
        Self.log.info("enforcement: done, residualLeak=\(Self.firstLeakOccurrence(in: final, avoidWords: avoidPhrases)?.matched ?? "none", privacy: .public)")

        // Restore the DRAFT's orthographic conventions (acronym casing,
        // sentence capitals, terminal periods) mechanically — the register
        // signal most users actually provide is the draft itself, and
        // orthography is rules, not voice.
        if request.mode == .rewrite {
            final = DraftConventions.detect(from: request.draft).apply(to: final)
        }

        await recordFingerprint(output: final, register: tagLine)

        return final
    }

    /// Replacement-word calls per compose — bounds the loop when a text is
    /// riddled with leaks (each call fixes one occurrence).
    static let maxWordReplacements = 6

    /// Rewrites longer than this (in words) take the chunked path.
    static let chunkActivationWords = 80
    /// Target chunk size — near the adapter's chat-trained comfort length,
    /// so the length prior has nothing to fight.
    static let chunkTargetWords = 50

    /// One piece of a chunked rewrite. `rewrite == false` passes through
    /// verbatim: markdown structure (headings, fenced code, HTML comments,
    /// tables, rules, blank lines) and fragments too short to carry voice.
    /// Structure is the HARNESS's job — sending "## Summary" to a voice
    /// model produced an echo-and-continue that passed the tiny-chunk
    /// sanity window and duplicated the document's opening (a markdown PR
    /// description came back with its first section doubled).
    struct DraftSegment: Equatable, Sendable {
        var text: String
        var rewrite: Bool
        /// True only for MARKDOWN structure (headings, fences, comments,
        /// tables, rules, blank lines) — NOT for prose that merely passes
        /// through for being short. The distinction matters: "Dana," and
        /// "Sam" are one-word prose paragraphs in a normal email, and
        /// counting them as structure made every email with a
        /// greeting/name line read as a "document" to the auto path and
        /// the register detector.
        var structural: Bool = false
    }

    /// True when the draft contains real (non-blank) markdown structure —
    /// the shared "is this a document?" question the auto path and the
    /// register detector both ask.
    static func hasMarkdownStructure(_ segments: [DraftSegment]) -> Bool {
        segments.contains {
            $0.structural
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// A prose chunk below this many whitespace-words passes through
    /// unrewritten: too short to carry voice, and the sanity window's
    /// 3-word floor would otherwise force the model to pad it. (CJK text
    /// under-counts here — but CJK drafts also never cross
    /// `chunkActivationWords`, so they take the one-pass path anyway.)
    static let minRewriteChunkWords = 4

    /// Splits a draft into segments for the chunked rewrite: markdown
    /// structure passes through, prose paragraphs split into ~targetWords
    /// pieces at sentence boundaries. Every byte of the draft lands in
    /// exactly one segment, in order — `segments.map(\.text).joined() ==
    /// draft` exactly (reassembly is mechanical). Pure, exposed for tests.
    static func chunkSegments(_ draft: String,
                              targetWords: Int = chunkTargetWords) -> [DraftSegment] {
        // Lines, keeping their "\n" terminators.
        var lines: [String] = []
        var currentLine = ""
        for character in draft {
            currentLine.append(character)
            if character == "\n" { lines.append(currentLine); currentLine = "" }
        }
        if !currentLine.isEmpty { lines.append(currentLine) }

        var segments: [DraftSegment] = []
        func appendStructure(_ text: String) {
            // Merge only into a STRUCTURAL neighbor — folding structure
            // into a short-prose passthrough segment would smear the
            // structural flag across prose.
            if let last = segments.last, last.structural {
                segments[segments.count - 1].text += text
            } else {
                segments.append(DraftSegment(text: text, rewrite: false, structural: true))
            }
        }
        func flushParagraph(_ paragraph: inout String) {
            guard !paragraph.isEmpty else { return }
            for chunk in proseChunks(paragraph, targetWords: targetWords) {
                let words = chunk.split(whereSeparator: \.isWhitespace).count
                // Short prose stays its OWN segment (not merged into a
                // neighboring structure segment) so sentence-level splits
                // remain visible to tests and reassembly stays local.
                segments.append(DraftSegment(text: chunk,
                                             rewrite: words >= minRewriteChunkWords))
            }
            paragraph = ""
        }

        var paragraph = ""
        var inFence = false
        var inComment = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if inFence {
                appendStructure(line)
                if trimmed.hasPrefix("```") { inFence = false }
                continue
            }
            if inComment {
                appendStructure(line)
                if trimmed.contains("-->") { inComment = false }
                continue
            }
            let isStructure = trimmed.isEmpty
                || trimmed.hasPrefix("```")
                || trimmed.hasPrefix("#")
                || trimmed.hasPrefix("<!--")
                || trimmed.hasPrefix("|")
                || (trimmed.count >= 3 && trimmed.allSatisfy { "-*_ ".contains($0) })
            if isStructure {
                flushParagraph(&paragraph)
                appendStructure(line)
                if trimmed.hasPrefix("```") { inFence = true }
                if trimmed.hasPrefix("<!--") && !trimmed.contains("-->") { inComment = true }
            } else {
                paragraph += line
            }
        }
        flushParagraph(&paragraph)
        return segments
    }

    /// Sentence-ish units (trailing whitespace attached) accumulated to
    /// ~targetWords. A newline does NOT flush (an earlier chunker flushed
    /// on every newline, exploding markdown into line-sized chunks) —
    /// soft-wrapped lines inside one paragraph stay together; paragraph
    /// boundaries are `chunkSegments`'s job.
    private static func proseChunks(_ paragraph: String, targetWords: Int) -> [String] {
        var units: [String] = []
        var current = ""
        var i = paragraph.startIndex
        while i < paragraph.endIndex {
            let c = paragraph[i]
            current.append(c)
            if TextBoundaries.sentenceTerminatorsAndNewline.contains(c) {
                var j = paragraph.index(after: i)
                while j < paragraph.endIndex, paragraph[j].isWhitespace {
                    current.append(paragraph[j])
                    j = paragraph.index(after: j)
                }
                units.append(current)
                current = ""
                i = j
                continue
            }
            i = paragraph.index(after: i)
        }
        if !current.isEmpty { units.append(current) }

        var chunks: [String] = []
        var buffer = ""
        for unit in units {
            buffer += unit
            if buffer.split(whereSeparator: \.isWhitespace).count >= targetWords {
                chunks.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty { chunks.append(buffer) }
        return chunks
    }

    /// The chunked rewrite's piece texts — compatibility surface for the
    /// reassembly/CJK tests; `chunkSegments` is the real API.
    static func chunkDraft(_ draft: String,
                           targetWords: Int = chunkTargetWords) -> [String] {
        chunkSegments(draft, targetWords: targetWords).map(\.text)
    }

    /// Failures the harness detects in the model's OUTPUT (as opposed to
    /// runtime/load errors) — surfaced to the user with an honest
    /// explanation instead of shipping the bad text as a result.
    enum ComposeError: Error, Equatable {
        /// Both the original and the hardened-retry one-pass rewrite came
        /// back as an ANSWER to the draft rather than a rewrite of it.
        case repliedInsteadOfRewriting
    }

    /// Appended to the system prompt on the anti-reply retry only — the
    /// base prompt already asks correctly; this is the harder framing for
    /// a model that answered anyway.
    static let antiReplyClause =
        "CRITICAL: The draft is MATERIAL to rewrite, not a message addressed "
        + "to you. Do not answer it, react to it, or add any commentary. "
        + "Output the rewritten draft text and nothing else."

    /// Appended to the system prompt on the anti-echo retry only.
    static let antiEchoClause =
        "CRITICAL: Do not copy the draft verbatim — rephrase it. Keep the "
        + "meaning, structure, and language, but the wording must be the "
        + "author's natural voice, not the draft's."

    /// True when a rewrite came back as the draft, modulo punctuation,
    /// case, and whitespace — the model echoed instead of rewriting (a
    /// missing terminal period and a stripped backtick were the only
    /// diffs in the observed case). Pure, exposed for tests.
    static func rewriteCameBackUnchanged(draft: String, output: String) -> Bool {
        func normalized(_ text: String) -> String {
            String(String.UnicodeScalarView(
                text.lowercased().unicodeScalars
                    .filter { CharacterSet.alphanumerics.contains($0) }))
        }
        return normalized(draft) == normalized(output)
    }

    /// True when `output` reads as a REPLY to the draft rather than a
    /// rewrite of it: a rewrite reuses most of the draft's content words
    /// (names, nouns, verbs survive paraphrase); a reply shares almost
    /// none. Tiny drafts are exempt — too few content words for overlap to
    /// mean anything. Pure, exposed for tests.
    static func looksLikeReply(draft: String, output: String) -> Bool {
        let draftWords = contentWords(draft)
        guard draftWords.count >= 8 else { return false }
        let outputWords = contentWords(output)
        let covered = draftWords.intersection(outputWords).count
        return Double(covered) / Double(draftWords.count) < 0.3
    }

    /// Lowercased, punctuation-trimmed words of 4+ characters.
    private static func contentWords(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 4 })
    }

    /// What the Auto rewrite style resolves to for this draft — ONE shared
    /// decision for the engine and the UI's live "Auto → …" caption: if
    /// auto changes behavior per paste, the UI must show which way it went,
    /// so a bad result can be traced to a mode and overridden.
    ///
    /// STRUCTURED documents (markdown headings/fences/comments) one-pass:
    /// chunking a doc means a dozen slow full-context generations and the
    /// model keeps echoing nearby structure into prose chunks. Chunking
    /// remains the default for long PLAIN prose — the length-collapse case
    /// it was built for. The style knob overrides either way.
    enum AutoPath: Equatable, Sendable {
        case onePassShort        // small draft — nothing to chunk
        case onePassStructured   // markdown / mixed content
        case chunkedLongProse    // long plain prose
    }

    static func autoPath(for draft: String) -> AutoPath {
        let segments = chunkSegments(draft)
        if hasMarkdownStructure(segments) { return .onePassStructured }
        let words = draft.split(whereSeparator: \.isWhitespace).count
        guard segments.filter(\.rewrite).count > 1,
              words > chunkActivationWords else { return .onePassShort }
        return .chunkedLongProse
    }

    /// One-pass output budget scales with the draft: a structured 700-word
    /// document needs well over the old flat 1024 tokens, and truncating a
    /// rewrite mid-document is worse than a slow one. Capped so a runaway
    /// generation still ends.
    static func onePassMaxTokens(for draft: String) -> Int {
        let words = draft.split(whereSeparator: \.isWhitespace).count
        return max(defaultMaxTokens, min(4096, words * 3))
    }

    /// Drops leading structure-shaped lines (headings, fences, HTML
    /// comments, blanks) from a prose chunk's output — structure never
    /// enters a rewrite chunk, so any at the FRONT of its output is context
    /// echo. Interior lines are left alone. Pure, exposed for tests.
    static func stripStructuralPrefix(from piece: String) -> String {
        var lines = piece.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || trimmed.hasPrefix("#")
                    || trimmed.hasPrefix("```") || trimmed.hasPrefix("<!--")
            else { break }
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips a leading byte-exact repetition of the previous chunk's
    /// accepted rewrite from `piece` (the model replaying its
    /// rewritten-so-far context before continuing — observed as a doubled
    /// sentence in real output). A piece that is NOTHING BUT the echo
    /// (byte-exact or whitespace-collapsed-equal) returns empty, which
    /// fails the sanity floor so the original chunk stands instead of a
    /// duplicate. Pure, exposed for tests.
    static func stripLeadingEcho(of previous: String, from piece: String) -> String {
        guard !previous.isEmpty else { return piece }
        if piece.hasPrefix(previous) {
            return String(piece.dropFirst(previous.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func collapsed(_ s: String) -> String {
            s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return collapsed(piece) == collapsed(previous) ? "" : piece
    }

    /// Prompt for one chunk of a long rewrite: the usual voice scaffolding
    /// plus the FULL draft and the rewritten-so-far text as explicitly
    /// read-only context, so each piece connects to what was actually
    /// written before it. Pure, exposed for tests.
    static func assembleChunkPrompt(
        chunk: String, fullDraft: String, rewrittenSoFar: String,
        tagLine: String, profile: StyleProfile, exemplars: [Exemplar],
        avoidPhrases: [String]
    ) -> ComposedPrompt {
        let header = "You rewrite drafts in the author's personal voice, one part at a time. "
            + "Preserve the part's meaning and facts; change only expression. Keep the rewrite "
            + "about the same length as the part. Never copy sentences or facts from the writing "
            + "examples — they show how the author sounds, not what to say. Write in the same "
            + "language as the part. Output ONLY the rewrite of the part given by the user — "
            + "no other text."
        var systemParts = [header, tagLine, profile.promptBlock()]
        if !avoidPhrases.isEmpty {
            let capped = avoidPhrases.prefix(80).joined(separator: ", ")
            systemParts.append("Words and phrases the author never uses — do not use them "
                               + "in any form: " + capped + ".")
        }
        if !exemplars.isEmpty {
            let samples = exemplars.map { "---\n\($0.text)" }.joined(separator: "\n")
            systemParts.append("Examples of the author's real writing, for voice reference only — never copy their sentences or facts:\n"
                               + samples + "\n---")
        }
        systemParts.append("The full draft, for context only — do not rewrite it:\n\(fullDraft)")
        if !rewrittenSoFar.isEmpty {
            systemParts.append("Already rewritten so far — your rewrite must continue seamlessly from it:\n\(rewrittenSoFar)")
        }
        return ComposedPrompt(system: systemParts.joined(separator: "\n\n"),
                              messages: [PromptMessage(role: "user", text: chunk)])
    }

    /// Diagnostic trail for the avoid-word enforcement (`log stream
    /// --predicate 'subsystem == "<AppIdentity.logSubsystem>"'`) — added
    /// after three rounds of guessing which stage failed; the words logged
    /// are the user's own ban list and the model's suggestions for it.
    static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "avoidwords")

    /// The first avoid-word occurrence in `text` (any inflected form, same
    /// stem logic as the detector), with the exact matched form and its
    /// surrounding sentence for the replacement prompt's context. Pure,
    /// exposed for tests.
    static func firstLeakOccurrence(in text: String, avoidWords: [String])
        -> (range: Range<String.Index>, matched: String, sentence: String)? {
        guard !avoidWords.isEmpty else { return nil }
        let stems = avoidWords.flatMap { word -> [String] in
            let base = word.lowercased()
            var forms = [NSRegularExpression.escapedPattern(for: base)]
            if base.hasSuffix("e"), base.count >= 4 {
                forms.append(NSRegularExpression.escapedPattern(for: String(base.dropLast())))
            }
            return forms
        }
        let pattern = "\\b(?:\(stems.joined(separator: "|")))[a-zA-Z]*"
        guard let range = text.range(of: pattern,
                                     options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let boundaries = TextBoundaries.sentenceTerminatorsAndNewline
        var start = text.startIndex
        if let priorBoundary = text[..<range.lowerBound].lastIndex(where: { boundaries.contains($0) }) {
            start = text.index(after: priorBoundary)
        }
        let end = text[range.upperBound...].firstIndex(where: { boundaries.contains($0) })
            ?? text.endIndex
        let sentence = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
        return (range, String(text[range]), sentence)
    }

    /// Asks for ONLY the replacement word/phrase — never a rewrite.
    /// Pure, exposed for tests.
    static func replacementPrompt(word: String, sentence: String,
                                  tagLine: String) -> ComposedPrompt {
        let system = """
        The author never uses the word "\(word)". In the author's sentence below, it must be \
        replaced. \(tagLine) Reply with ONLY the replacement word or short phrase the author \
        would use instead — in the sentence's own language, matching the original's tense and \
        grammar so it drops cleanly into the sentence. No quotes, no punctuation, no explanation.
        """
        return ComposedPrompt(system: system,
                              messages: [PromptMessage(role: "user", text: sentence)])
    }

    /// When the model answers "give me the replacement word" by rewriting
    /// the WHOLE sentence (the fine-tuned adapter's observed dialect —
    /// trained to write prose, not follow instructions), the answer is
    /// still in there: align reply vs original word-by-word; the tokens
    /// that changed in the banned word's slot are the replacement.
    /// Conservative on purpose — if the model changed more than the banned
    /// word's immediate neighborhood (≤3 original tokens → 1–5 reply
    /// tokens), returns nil and enforcement gives up honestly rather than
    /// splice a guess. Pure, exposed for tests.
    static func extractReplacement(originalSentence: String, reply: String,
                                   matched: String) -> String? {
        let original = originalSentence.split(separator: " ").map(String.init)
        let rewritten = reply.split(separator: " ").map(String.init)
        guard !original.isEmpty, !rewritten.isEmpty else { return nil }
        var prefix = 0
        while prefix < min(original.count, rewritten.count),
              original[prefix] == rewritten[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(original.count, rewritten.count) - prefix,
              original[original.count - 1 - suffix] == rewritten[rewritten.count - 1 - suffix] {
            suffix += 1
        }
        let changedOriginal = Array(original[prefix ..< original.count - suffix])
        let changedReply = Array(rewritten[prefix ..< rewritten.count - suffix])
        // The changed slot must actually contain the banned word — and the
        // change must be word-sized, not a rewrite (a truncated reply
        // fails the suffix match and lands here as a huge slot → nil).
        guard changedOriginal.count <= 3, (1...5).contains(changedReply.count),
              changedOriginal.contains(where: {
                  $0.lowercased().contains(matched.lowercased())
              })
        else { return nil }
        return sanitizeReplacement(changedReply.joined(separator: " "))
    }

    /// First line, trimmed of whitespace/quotes/stray punctuation — models
    /// love to wrap a one-word answer in ceremony.
    static func sanitizeReplacement(_ raw: String) -> String {
        let firstLine = raw.components(separatedBy: .newlines).first ?? ""
        return firstLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.,;:!?"))
    }

    /// Usable = non-empty, short (a word or brief phrase, not a rewrite),
    /// and not itself a banned word.
    static func isValidReplacement(_ replacement: String, avoidWords: [String]) -> Bool {
        !replacement.isEmpty
            && replacement.split(separator: " ").count <= 5
            && VoiceCheck.leakedAvoidWords(in: replacement, avoidWords: avoidWords).isEmpty
    }

    // MARK: - Prompt assembly

    private static func assemblePrompt(
        mode: ComposeMode, draft: String, tagLine: String, profile: StyleProfile,
        exemplars: [Exemplar], avoidPhrases: [String] = []
    ) -> ComposedPrompt {
        // BOTH modes keep exemplars in the system context, as explicitly
        // reference-only material, and put exactly ONE user turn in the
        // conversation. Exemplars as few-shot chat turns caused two observed
        // failures: in generate mode the user-says-words → assistant-writes-
        // text pattern out-pulled the instruction (the model casualized the
        // instruction instead of following it); in rewrite mode a draft
        // whose vocabulary matched a strong exemplar made the model COPY the
        // exemplar — it emitted the author's actual résumé, verbatim, from
        // the prompt context instead of rewriting the draft.
        let header = mode == .rewrite ? systemHeaderRewrite : systemHeaderGenerate
        var systemParts = [header, tagLine, profile.promptBlock()]
        if !avoidPhrases.isEmpty {
            // Cap so an enormous curated list can't crowd out the actual
            // prompt; the scan list is ~50 short phrases, well under this.
            let capped = avoidPhrases.prefix(80).joined(separator: ", ")
            systemParts.append("Words and phrases the author never uses — do not use them "
                               + "in any form (no -s, -ed, -ing, or other variants either), "
                               + "even when the draft or instruction contains them; replace "
                               + "each with how the author would naturally say it: "
                               + capped + ".")
        }
        if !exemplars.isEmpty {
            let samples = exemplars.map { "---\n\($0.text)" }.joined(separator: "\n")
            systemParts.append("Examples of the author's real writing, for voice reference only — never copy their sentences or facts:\n"
                               + samples + "\n---")
        }
        let userText = mode == .rewrite
            ? rewriteInstructionPrefix + draft
            : generateInstructionPrefix + draft + generateInstructionSuffix
        return ComposedPrompt(system: systemParts.joined(separator: "\n"),
                              messages: [PromptMessage(role: "user", text: userText)])
    }

    /// Builds the `[medium: x] [audience: y] [mode: z]` tag line per the §8
    /// grammar, in medium/audience/mode order, omitting any nil dimension.
    /// Returns an empty string when every dimension is nil.
    static func tagLine(for register: RegisterQuery) -> String {
        var parts: [String] = []
        if let medium = register.medium { parts.append("[medium: \(medium)]") }
        if let audience = register.audience { parts.append("[audience: \(audience)]") }
        if let mode = register.mode { parts.append("[mode: \(mode)]") }
        return parts.joined(separator: " ")
    }

    // MARK: - Fingerprinting

    /// Records a fingerprint of a completed generation. A failure here must
    /// never lose the already-generated output, so errors are logged and
    /// swallowed rather than propagated.
    private func recordFingerprint(output: String, register: String) async {
        do {
            try await db.writer.write { dbc in
                var record = GenerationRecord(
                    id: nil, createdAt: Date(), sha256: sha256Hex(canonicalize(output)),
                    simhash64: simhash64(of: output), register: register, modelRef: modelRef)
                try record.insert(dbc)
            }
        } catch {
            print("ComposeEngine: failed to record generation fingerprint: \(error)")
        }
    }
}
