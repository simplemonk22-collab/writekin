import Foundation
import GRDB

/// Outcome of one regurgitation check (spec §6); stored inside
/// `TrainingMetrics.regurgitation` and surfaced as a run-card warning banner.
/// Never blocks promotion — informs only.
///
/// `samplesChecked` records how many generations were actually inspected,
/// so a check that was cancelled mid-way (or before the first sample) is
/// distinguishable from one that ran clean: `samplesChecked == 0` means the
/// check was skipped — no leak signal either way — and the run card shows a
/// neutral "check skipped" note rather than implying a clean result. A
/// missing result (`TrainingMetrics.regurgitation == nil`) means the check
/// never ran at all (sampler failed to load, or the check threw) and is
/// treated the same way in the UI.
struct RegurgitationResult: Codable, Equatable, Sendable {
    var samplesChecked: Int
    var flaggedSamples: Int
    var flagged: Bool

    /// True when the check inspected no or not all of its samples — the
    /// result carries no (or only partial) leak signal.
    var isPartial: Bool { samplesChecked < RegurgitationCheck.maxSamples }
    var isSkipped: Bool { samplesChecked == 0 }
}

/// Rabin-Karp rolling-hash set over n-token windows. Tokens are hashed with
/// FNV-1a; a window's hash is the base-B polynomial of its token hashes with
/// wrapping UInt64 arithmetic, rolled in O(1) per step. Membership is
/// hash-only: a false positive needs a 64-bit collision, which is acceptable
/// for an informative (never blocking) check.
struct NGramIndex {
    let n: Int
    private var windowHashes: Set<UInt64> = []
    private static let base: UInt64 = 1_099_511_628_211
    private let basePowNMinus1: UInt64

    init(n: Int) {
        self.n = n
        var p: UInt64 = 1
        for _ in 0..<(n - 1) { p = p &* Self.base }
        basePowNMinus1 = p
    }

    mutating func insert(tokens: [String]) {
        forEachWindowHash(in: tokens) { windowHashes.insert($0); return true }
    }

    func containsWindow(in tokens: [String]) -> Bool {
        var found = false
        forEachWindowHash(in: tokens) { hash in
            if windowHashes.contains(hash) { found = true; return false }
            return true
        }
        return found
    }

    /// Calls `body` with each n-window hash; stop early by returning false.
    private func forEachWindowHash(in tokens: [String], _ body: (UInt64) -> Bool) {
        guard tokens.count >= n else { return }
        let hashes = tokens.map { SplitAssigner.fnv1a64($0) }
        var hash: UInt64 = 0
        for i in 0..<n { hash = hash &* Self.base &+ hashes[i] }
        if !body(hash) { return }
        for i in n..<hashes.count {
            hash = (hash &- hashes[i - n] &* basePowNMinus1) &* Self.base &+ hashes[i]
            if !body(hash) { return }
        }
    }
}

/// Post-training leak detector (spec §6): samples up to 20 generations from
/// the adapted model (register tags drawn from the dataset's densest cells,
/// empty user input) and flags any generation sharing a >= 20-token
/// contiguous n-gram with any kept item's clean_text. The corpus index is
/// built once per check.
struct RegurgitationCheck: Sendable {
    let db: AppDatabase
    static let nGram = 20
    static let maxSamples = 20
    static let sampleMaxTokens = 256
    static let sampleTemperature = 0.7

    func run(datasetID: Int64, generator: any TextGenerating,
             isCancelled: @Sendable () -> Bool = { false }) async throws -> RegurgitationResult {
        // Cancelled before any work: report a skipped check (samplesChecked
        // 0) rather than a clean one.
        if isCancelled() {
            return RegurgitationResult(samplesChecked: 0, flaggedSamples: 0, flagged: false)
        }
        // 1. Corpus-side 20-gram index over kept clean_text.
        var index = NGramIndex(n: Self.nGram)
        let texts = try await db.writer.read { dbc in
            try String.fetchAll(dbc, sql: """
                SELECT clean_text FROM items
                WHERE state = 'kept' AND clean_text IS NOT NULL AND clean_text != ''
                """)
        }
        for text in texts {
            index.insert(tokens: Self.tokens(text))
        }

        // 2. Register tags from the dataset's densest cells.
        let cells = try await db.writer.read { dbc in
            try String.fetchAll(dbc, sql: """
                SELECT system_tags FROM pairs WHERE dataset_id = ?
                GROUP BY system_tags ORDER BY COUNT(*) DESC LIMIT 5
                """, arguments: [datasetID])
        }
        let tagCycle = cells.isEmpty ? [""] : cells

        // 3. Sample and check. The cancel flag is consulted between samples
        // so Cancel takes effect within one generation rather than after all
        // 20 — a check cut short reports exactly what it measured
        // (`samplesChecked` = samples actually inspected).
        var flagged = 0
        var checked = 0
        for sampleIndex in 0..<Self.maxSamples {
            if isCancelled() { break }
            let tags = tagCycle[sampleIndex % tagCycle.count]
            let prompt = ComposedPrompt(
                system: TrainingSupport.systemLine(tags: tags),
                messages: [PromptMessage(role: "user", text: "")])
            let output = try await generator.generate(
                prompt: prompt, maxTokens: Self.sampleMaxTokens,
                temperature: Self.sampleTemperature, onToken: { _ in })
            checked += 1
            if index.containsWindow(in: Self.tokens(output)) {
                flagged += 1
            }
        }
        return RegurgitationResult(samplesChecked: checked,
                                   flaggedSamples: flagged, flagged: flagged > 0)
    }

    /// Token = whitespace-split word (spec §6).
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
