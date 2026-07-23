import Foundation
import GRDB

/// Tally of how a ``ModeLabelPass`` run resolved each item it looked at.
/// `labeled` is an exact-match reply (`label_source = "model"`); `lowConfidence`
/// is a reply that merely contained a label word (`label_source = "model_low"`);
/// `unparseable` is a reply (even after one retry) that contained none of the
/// five labels, so the item's `mode` is left `NULL` for a future run to retry.
struct LabelRunSummary: Equatable, Sendable {
    var labeled: Int = 0
    var lowConfidence: Int = 0
    var unparseable: Int = 0
}

/// Pipeline Step 4: asks a small on-device model to label each kept item's
/// register (casual/logistics/professional/pitch/essay). Never touches rows
/// that already have a `mode` — that naturally excludes both already-labeled
/// rows and `label_source = "manual"` rows, so manual labels are never
/// overwritten by this pass.
struct ModeLabelPass {
    let db: AppDatabase
    let generator: any TextGenerating

    static let labels = ["casual", "logistics", "professional", "pitch", "essay"]

    private static let systemPrompt = """
    You label a text's register. Reply with exactly one word from: casual, logistics, professional, pitch, essay.
    casual: informal, personal conversation between friends or family.
    logistics: scheduling, coordinating, or other short factual exchanges.
    professional: formal work or business communication.
    pitch: persuasive, promotional, or sales-oriented writing.
    essay: long-form reflective, explanatory, or narrative writing.
    The text may be in any language — judge its register the same way, and still reply with one of the five English words above.
    """

    /// First 1,000 characters of `clean_text` (falling back to `raw_text`)
    /// sent as the user turn — long enough to establish register, short
    /// enough to keep generation fast.
    private static let userTextLimit = 1000

    /// Items classified per model call: the instruction prompt's cost is
    /// paid once per batch instead of once per item. Any item whose line is
    /// missing or invalid in the batch reply falls back to the single-item
    /// path, so batching can only lose speed, never labels.
    static let modelBatchSize = 8

    private static let batchSystemPrompt = """
    You label each numbered text's register. For every numbered text, output one line "N: word" where word is exactly one of: casual, logistics, professional, pitch, essay.
    casual: informal, personal conversation between friends or family.
    logistics: scheduling, coordinating, or other short factual exchanges.
    professional: formal work or business communication.
    pitch: persuasive, promotional, or sales-oriented writing.
    essay: long-form reflective, explanatory, or narrative writing.
    The texts may be in any language — judge their register the same way, and still use the five English words.
    Output exactly one line per numbered text, in order, and nothing else.
    """

    /// Parses a batch reply into 1-based index → label. Strict: only lines
    /// shaped "N: label" with a known label count; anything else is simply
    /// absent from the result and its item falls back to a single call.
    /// Pure, exposed for tests.
    static func parseBatchReply(_ reply: String, count: Int) -> [Int: String] {
        var result: [Int: String] = [:]
        for line in reply.components(separatedBy: "\n") {
            // "N: label", "N. label", "N) label" — models drift between
            // separators even when told exactly one; the index and a known
            // label are the strict parts.
            guard let match = line.firstMatch(of: /^\s*(\d+)\s*[:.)\-]\s*([A-Za-z]+)\s*$/),
                  let index = Int(match.1), (1...count).contains(index) else { continue }
            let label = String(match.2).lowercased()
            guard labels.contains(label), result[index] == nil else { continue }
            result[index] = label
        }
        return result
    }

    init(db: AppDatabase, generator: any TextGenerating) {
        self.db = db
        self.generator = generator
    }

    @discardableResult
    func run(progress: @Sendable (Int) -> Void = { _ in },
             isCancelled: @Sendable () -> Bool = { false }) async throws -> LabelRunSummary {
        var summary = LabelRunSummary()
        var processed = 0
        // An unparseable item's `mode` stays NULL even after we've tried it, so
        // (unlike Clean/Filter/NearDupe) the `mode IS NULL` predicate alone
        // can't shrink the query as the loop progresses — it would refetch the
        // same stuck row forever. An id watermark guarantees each row is
        // attempted at most once per run regardless of outcome.
        var afterID: Int64 = 0
        while true {
            if isCancelled() { return summary }
            let watermark = afterID
            // label_source IS NULL excludes items a previous run already
            // attempted and failed ("model_failed") — without it, the same
            // unlabelable handful re-loads the model and re-fails on every
            // single ingest, forever.
            let batch = try await db.writer.read { dbc in
                try Item.filter(Column("state") == "kept" && Column("mode") == nil
                                && Column("label_source") == nil
                                && Column("id") > watermark)
                    .order(Column("id"))
                    .limit(50)
                    .fetchAll(dbc)
            }
            if batch.isEmpty { break }
            afterID = batch.compactMap(\.id).max() ?? afterID

            var toUpdate: [LabelUpdate] = []
            var chunkStart = 0
            while chunkStart < batch.count {
                if isCancelled() {
                    try await writeBack(toUpdate)
                    return summary
                }
                let chunk = Array(batch[chunkStart..<min(chunkStart + Self.modelBatchSize,
                                                         batch.count)])
                chunkStart += Self.modelBatchSize

                // One call for the whole chunk; strict-parsed. Items whose
                // line came back missing or malformed fall back below.
                let numbered: String = chunk.enumerated().map { index, item -> String in
                    let text = item.cleanText ?? item.rawText
                    return "\(index + 1).\n\(String(text.prefix(Self.userTextLimit)))"
                }.joined(separator: "\n\n")
                let batchPrompt = ComposedPrompt(
                    system: Self.batchSystemPrompt,
                    messages: [PromptMessage(role: "user", text: numbered)])
                let reply = try await generator.generate(
                    prompt: batchPrompt, maxTokens: 12 * chunk.count,
                    temperature: 0.0, onToken: { _ in })
                let parsed = Self.parseBatchReply(reply, count: chunk.count)

                for (index, item) in chunk.enumerated() {
                    if isCancelled() {
                        try await writeBack(toUpdate)
                        return summary
                    }
                    if let label = parsed[index + 1], let id = item.id {
                        toUpdate.append(LabelUpdate(id: id, mode: label, labelSource: "model"))
                        summary.labeled += 1
                        continue
                    }
                    // Single-item fallback: the original prompt, one retry,
                    // then the substring scan — identical to pre-batching.
                    let text = item.cleanText ?? item.rawText
                    let userText = String(text.prefix(Self.userTextLimit))
                    let prompt = ComposedPrompt(
                        system: Self.systemPrompt,
                        messages: [PromptMessage(role: "user", text: userText)])
                    var resolved = try await classify(prompt: prompt)
                    if resolved == nil {
                        // One retry for an unparseable reply before giving up.
                        resolved = try await classify(prompt: prompt)
                    }
                    if let (label, source) = resolved, let id = item.id {
                        toUpdate.append(LabelUpdate(id: id, mode: label, labelSource: source))
                        if source == "model" {
                            summary.labeled += 1
                        } else {
                            summary.lowConfidence += 1
                        }
                    } else if let id = item.id {
                        // Record the failure (mode stays NULL) so the next
                        // run's query skips this item instead of re-failing
                        // it forever. Re-labeling after a model change goes
                        // through Re-apply Filters, not silent retries.
                        toUpdate.append(LabelUpdate(id: id, mode: nil,
                                                    labelSource: "model_failed"))
                        summary.unparseable += 1
                    } else {
                        summary.unparseable += 1
                    }
                }
            }
            try await writeBack(toUpdate)

            processed += batch.count
            progress(processed)
        }
        return summary
    }

    /// The only two columns this pass ever changes; written column-restricted
    /// so labeling never rewrites clean_text or any other item column.
    /// `mode` nil = a recorded failure ("model_failed" source, mode NULL).
    private struct LabelUpdate: Sendable {
        var id: Int64
        var mode: String?
        var labelSource: String
    }

    private func writeBack(_ updates: [LabelUpdate]) async throws {
        guard !updates.isEmpty else { return }
        try await db.writer.write { dbc in
            let statement = try dbc.cachedStatement(
                sql: "UPDATE items SET mode = ?, label_source = ? WHERE id = ?")
            for update in updates {
                try statement.execute(arguments: [update.mode, update.labelSource, update.id])
            }
        }
    }

    /// Runs one generation and parses the reply: an exact (trimmed, lowercased)
    /// match to a label is high confidence; otherwise the reply is scanned for
    /// the earliest-occurring label substring. Returns nil when neither finds one.
    private func classify(prompt: ComposedPrompt) async throws -> (label: String, source: String)? {
        let reply = try await generator.generate(
            prompt: prompt, maxTokens: 16, temperature: 0.0, onToken: { _ in })
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if Self.labels.contains(trimmed) {
            return (trimmed, "model")
        }
        if let scanned = Self.scanForLabel(reply) {
            return (scanned, "model_low")
        }
        return nil
    }

    /// Finds the earliest-occurring label substring in `text` (case-insensitive),
    /// scanning by position in the text rather than by label list order.
    private static func scanForLabel(_ text: String) -> String? {
        let lower = text.lowercased()
        var bestIndex: String.Index?
        var bestLabel: String?
        for label in labels {
            guard let range = lower.range(of: label) else { continue }
            if bestIndex == nil || range.lowerBound < bestIndex! {
                bestIndex = range.lowerBound
                bestLabel = label
            }
        }
        return bestLabel
    }
}
