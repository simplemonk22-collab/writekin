import Foundation
import GRDB

/// The corrections loop's write side: "Save as my version" on Compose
/// records (what was asked → what the user actually says) as a pending
/// training pair. The next `DatasetBuilder.snapshot` claims it like any
/// generated pair, so corrections flow into training with zero extra
/// steps — they're the most surgical voice signal there is, aimed exactly
/// at what the model last got wrong.
struct CorrectionStore: Sendable {
    let db: AppDatabase

    /// Number of saved corrections still pending (not yet claimed by a
    /// dataset) — surfaced in Compose so saving feels cumulative.
    func pendingCount() async throws -> Int {
        try await db.writer.read { dbc in
            try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM pairs
                WHERE pair_type = 'correction' AND dataset_id IS NULL
                """) ?? 0
        }
    }

    /// Saves one correction: `input` is what Compose was given (the draft
    /// in rewrite mode, the instruction in generate mode), `corrected` is
    /// the user's own version of the output. Always split "train" — a
    /// correction is a teaching example, never held out — and rejected
    /// when the user saved the model's text unchanged (nothing to learn).
    @discardableResult
    func save(input: String, corrected: String, modelOutput: String,
              registerTags: String) async throws -> Bool {
        let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != modelOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        try await db.writer.write { dbc in
            var pair = Pair(id: nil, itemId: nil, pairType: "correction",
                            systemTags: registerTags, inputText: input,
                            targetText: trimmed, split: "train", datasetId: nil)
            try pair.insert(dbc)
        }
        return true
    }
}
