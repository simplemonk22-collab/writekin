import Foundation
import GRDB

/// Tally of one pair-generation run (spec §3).
struct PairGenSummary: Equatable, Sendable {
    var itemsProcessed: Int = 0
    var degradation: Int = 0
    var backtranslation: Int = 0
    var completion: Int = 0
    /// Items whose degradation OR backtranslation generation came back empty
    /// and fell back to a completion pair (spec §3 fallback rule).
    var degradationFallbacks: Int = 0
    var skippedResumed: Int = 0
    /// Items whose pair was copied from an earlier dataset instead of
    /// regenerated — pair type, prompt, and split are deterministic per
    /// item, so regeneration would only reproduce the same pair at model
    /// speed. Copies are near-instant.
    var reusedPriorPairs: Int = 0
}

/// Produces training pairs from the kept corpus (spec §3). Deterministic
/// everywhere a model isn't involved: splits, pair-type assignment, prompt
/// rotation, and sampling all hash or stride on stable ids, so re-runs are
/// reproducible. Pairs land with `dataset_id = NULL` ("pending") until
/// `DatasetBuilder.snapshot` claims them.
struct PairGenerator {
    let db: AppDatabase
    let generator: any TextGenerating

    static let targetClip = 4_000
    static let contextClipSMS = 500       // already applied at parse; re-clipped defensively
    static let generationMaxTokens = 512
    static let generationTemperature = 0.3
    /// Floor for the per-item token cap below — even a tiny SMS target
    /// gets enough room for a sensible degradation/instruction.
    static let generationMinTokens = 64

    /// Per-item generation cap: both pair prompts produce text that should
    /// be NO LONGER than the target itself (notes degrade it, the
    /// backtranslation is one sentence), so budget tokens off the target's
    /// size (~3 chars/token, generous) instead of letting a rambling model
    /// run to the flat 512 cap on a 40-word text message.
    static func generationTokenCap(targetCharacterCount: Int) -> Int {
        min(generationMaxTokens, max(generationMinTokens, targetCharacterCount / 3))
    }

    /// 4 rotating degradation prompt variants (spec §3); selected by itemID % 4.
    static let degradationPrompts = [
        "Rewrite the following text as terse, fragmentary notes, in the same language as the text. Drop the author's voice entirely. Output only the notes.",
        "Summarize the following text as a bland, generic draft someone else might have written, in the same language as the text. Output only the draft.",
        "Reduce the following text to a short list of its bare points, one per line, in the same language as the text. Output only the list.",
        "Rewrite the following text in flat, clumsy, impersonal prose with none of its personality, in the same language as the text. Output only the rewrite.",
    ]
    static let backtranslationPrompt =
        "Write the one-sentence instruction that would have produced the following text, in the same language as the text. Output only the instruction."

    /// Minimal projection used for sampling before full-item fetch.
    private struct Candidate: Sendable {
        var id: Int64
        var cell: String
    }

    /// `progress(done, total, skipped)` — `done` includes both generated and
    /// skipped (already-paired, resumed) items, matching `total`; `skipped`
    /// is broken out separately so a resumed run can say "skipped 4,000
    /// already-paired" instead of those instant no-op items reading as a
    /// mysterious extra stage in the bar.
    @discardableResult
    func run(itemCap: Int = 1_000,
             progress: @Sendable (Int, Int, Int) -> Void = { _, _, _ in },
             isCancelled: @Sendable () -> Bool = { false }) async throws -> PairGenSummary {
        var summary = PairGenSummary()

        // 1. Eligible candidates (spec §3 eligibility + self-ingestion guard).
        let candidates = try await db.writer.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT id, COALESCE(medium, '') || '|' || COALESCE(audience, '') || '|'
                       || COALESCE(mode, '') AS cell
                FROM items
                WHERE state = 'kept'
                  AND clean_text IS NOT NULL AND clean_text != ''
                  AND ((kind = 'sms' AND word_count >= 8)
                       OR (kind IN ('email', 'doc') AND word_count >= 30))
                  AND sha256 NOT IN (SELECT sha256 FROM generations)
                ORDER BY id
                """).map { Candidate(id: $0["id"], cell: $0["cell"]) }
        }

        // 2. Stride-stratified sample per register cell (spec §3 sampling cap).
        let sampledIDs = Self.stratifiedSample(candidates: candidates, cap: itemCap)
        let total = sampledIDs.count
        progress(0, total, 0)

        // 3. Per-item loop: resumable (pending-pair skip), cancellable, writes
        // pairs inside the loop so a cancel keeps everything done so far.
        var done = 0
        for itemID in sampledIDs {
            if isCancelled() { return summary }
            let alreadyPending = try await db.writer.read { dbc in
                try Pair.filter(Column("item_id") == itemID && Column("dataset_id") == nil)
                    .fetchCount(dbc) > 0
            }
            if alreadyPending {
                summary.skippedResumed += 1
                done += 1
                progress(done, total, summary.skippedResumed)
                continue
            }
            guard let item = try await db.writer.read({ try Item.fetchOne($0, key: itemID) }),
                  let cleanText = item.cleanText, !cleanText.isEmpty else { continue }

            let target = String(cleanText.prefix(Self.targetClip))

            // Cross-dataset reuse: an item already paired in an EARLIER
            // dataset gets its most recent pair copied as a fresh pending
            // row instead of regenerated — everything about the pair is
            // deterministic per item id, so regeneration would spend a
            // model call reproducing it. Guarded on the target still
            // matching, so an item whose clean_text changed since (re-clean,
            // re-ingest) is regenerated rather than copied stale.
            let priorPair = try await db.writer.read { dbc in
                try Pair.filter(Column("item_id") == itemID && Column("dataset_id") != nil)
                    .order(Column("id").desc)
                    .fetchOne(dbc)
            }
            if let priorPair, priorPair.targetText == target {
                var mutable = priorPair
                mutable.id = nil
                mutable.datasetId = nil
                let copy = mutable
                try await db.writer.write { dbc in
                    var p = copy
                    try p.insert(dbc)
                }
                summary.reusedPriorPairs += 1
                summary.itemsProcessed += 1
                done += 1
                progress(done, total, summary.skippedResumed)
                continue
            }
            let split = SplitAssigner.split(
                groupKey: SplitAssigner.groupKey(threadID: item.threadId, itemID: itemID))
            // `items.medium` is a future manual-label override that nothing
            // populates yet — `kind` IS the medium for every ingested item.
            // Falling back matters: Compose always sends a `[medium: …]` tag
            // at inference, so pairs trained without one teach the model a
            // tag vocabulary that never matches its prompts.
            let tags = RegisterTags.line(medium: item.medium ?? item.kind,
                                         audience: item.audience,
                                         mode: item.mode)
            let context = Self.context(for: item)

            var pairType: String
            if split == "heldout" {
                // Heldout text never enters any generation prompt (spec §3).
                pairType = "completion"
            } else {
                switch SplitAssigner.fnv1a64("pairtype-\(itemID)") % 4 {
                case 0, 1: pairType = "degradation"
                case 2: pairType = "backtranslation"
                default: pairType = "completion"
                }
            }

            var payload = ""
            if pairType == "degradation" {
                let variant = Self.degradationPrompts[Int(itemID % 4)]
                let reply = (try? await generate(system: variant, user: target)) ?? ""
                if reply.isEmpty {
                    pairType = "completion"   // fallback (spec §3): empty or thrown generation
                    summary.degradationFallbacks += 1
                } else {
                    payload = reply
                }
            } else if pairType == "backtranslation" {
                let reply = (try? await generate(system: Self.backtranslationPrompt, user: target)) ?? ""
                if reply.isEmpty {
                    pairType = "completion"   // fallback (spec §3): empty or thrown generation
                    summary.degradationFallbacks += 1
                } else {
                    payload = reply
                }
            }

            let contextBlock = context.map { "Context:\n\($0)\n\n" } ?? ""
            let inputText = contextBlock + payload

            let pair = Pair(id: nil, itemId: itemID, pairType: pairType,
                            systemTags: tags, inputText: inputText,
                            targetText: target, split: split, datasetId: nil)
            try await db.writer.write { dbc in
                var p = pair
                try p.insert(dbc)
            }

            switch pairType {
            case "degradation": summary.degradation += 1
            case "backtranslation": summary.backtranslation += 1
            default: summary.completion += 1
            }
            summary.itemsProcessed += 1
            done += 1
            progress(done, total, summary.skippedResumed)
        }
        return summary
    }

    /// Reply-conditioning context per medium (spec §2): sms uses the stored
    /// parse-time context; email derives it from raw_text's quoted tail; docs
    /// never have context.
    static func context(for item: Item) -> String? {
        switch item.kind {
        case "sms": return item.contextText.map { String($0.suffix(contextClipSMS)) }
        case "email": return QuoteTailExtractor.extract(item.rawText)
        default: return nil
        }
    }

    /// Fair-share stride sampling: cells sorted ascending by size each take
    /// `min(count, remainingCap / cellsLeft)` items, picked at an even stride
    /// through the cell — small cells keep everything, big cells thin out.
    private static func stratifiedSample(candidates: [Candidate], cap: Int) -> [Int64] {
        guard candidates.count > cap else { return candidates.map(\.id) }
        var cells: [String: [Int64]] = [:]
        for c in candidates { cells[c.cell, default: []].append(c.id) }
        let ordered = cells.values.sorted { $0.count < $1.count }
        var picked: [Int64] = []
        var remaining = cap
        for (index, ids) in ordered.enumerated() {
            let cellsLeft = ordered.count - index
            let quota = max(1, remaining / cellsLeft)
            let take = min(ids.count, quota)
            if take == ids.count {
                picked.append(contentsOf: ids)
            } else {
                let step = Double(ids.count) / Double(take)
                for k in 0..<take {
                    picked.append(ids[Int(Double(k) * step)])
                }
            }
            remaining -= take
            if remaining <= 0 { break }
        }
        return picked.sorted()
    }

    private func generate(system: String, user: String) async throws -> String {
        let prompt = ComposedPrompt(system: system,
                                    messages: [PromptMessage(role: "user", text: user)])
        let reply = try await generator.generate(
            prompt: prompt,
            maxTokens: Self.generationTokenCap(targetCharacterCount: user.count),
            temperature: Self.generationTemperature, onToken: { _ in })
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
