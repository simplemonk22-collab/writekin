import Foundation
import MLXLMCommon

/// Hyperparameters for one training run (spec §5); stored verbatim in
/// `training_runs.config_json`.
struct TrainingConfig: Codable, Equatable, Sendable {
    // Defaults sized so a run actually moves the adapter: runs 1-7 shipped
    // with rank 8 / 600 iterations / lr 1e-5 -- at batch 1 that is ~13% of
    // one epoch over a ~4.6k-pair dataset, and the resulting adapters were
    // faint enough that the prompt-steered base model often matched them.
    // Learning rate stays 1e-5: run 8 (2e-5, rank 16, 2000 it) val-plateaued
    // at 2.92 and never approached run 7's 2.707 on the SAME dataset — the
    // hotter rate trained worse from the start, not just longer.
    var rank: Int = 16
    var scale: Float = 20
    var numLayers: Int = 16
    var batchSize: Int = 1
    var iterations: Int = 2_000
    var learningRate: Float = 1e-5
    var maxSeqLen: Int = 1_024
    var seed: UInt64 = 0

    /// Learning rate exactly as the start-run sheet's field shows it —
    /// "0.00001", never "1e-05". Every user-facing surface (run cards,
    /// evidence lines) uses this so advice values can be typed straight
    /// into the field.
    static func displayLearningRate(_ value: Float) -> String {
        var text = String(format: "%.8f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text += "0" }
        return text
    }
}

struct TrainChatMessage: Equatable, Sendable {
    var role: String
    var content: String
}

/// The one tokenizer capability the pure training core needs. Deliberately
/// NOT Sendable: the real adapter wraps swift-transformers' `Tokenizer` and
/// is only ever used inside the model container's isolation (Task 9); tests
/// use a value-type fake.
protocol ChatTokenizing {
    /// Token ids for the chat-template-rendered conversation.
    /// `addGenerationPrompt` appends the assistant-header tokens without an
    /// assistant message — the boundary that defines `promptLen`.
    func encodeChat(_ messages: [TrainChatMessage], addGenerationPrompt: Bool) throws -> [Int]
}

/// One chat-rendered pair: full token sequence + the number of leading
/// tokens (system + user + assistant header) that the loss must never cover.
struct RenderedPair: Equatable, Sendable {
    var tokens: [Int]
    var promptLen: Int
}

/// A next-token-shifted, padded batch as plain Swift arrays — MLXArray
/// conversion happens at the trainer boundary so all of this stays pure and
/// unit-testable without Metal.
struct TokenBatch: Equatable, Sendable {
    var inputs: [[Int]]
    var targets: [[Int]]
    var mask: [[Float]]
}

/// Pure functions of the training loop (spec §5): chat rendering, prompt-
/// length computation, batching/padding/truncation, loss-mask construction,
/// and adapter_config.json writing. No model, no Metal, no I/O beyond the
/// config writer.
enum TrainingSupport {
    /// The training system message: a fixed sentence plus the pair's
    /// register tags. `RegurgitationCheck` samples with the same line so
    /// checked generations match the trained distribution.
    static func systemLine(tags: String) -> String {
        tags.isEmpty ? "Write in the author's voice."
                     : "Write in the author's voice. \(tags)"
    }

    /// Renders one pair through the model's chat template. Returns nil for a
    /// dropped pair: the prompt alone reaches `maxSeqLen`, or truncation
    /// leaves no target tokens to learn from.
    static func render(systemTags: String, inputText: String, targetText: String,
                       tokenizer: any ChatTokenizing, maxSeqLen: Int) throws -> RenderedPair? {
        let system = TrainChatMessage(role: "system", content: systemLine(tags: systemTags))
        let user = TrainChatMessage(role: "user", content: inputText)
        let assistant = TrainChatMessage(role: "assistant", content: targetText)
        let promptTokens = try tokenizer.encodeChat([system, user], addGenerationPrompt: true)
        guard promptTokens.count < maxSeqLen else { return nil }
        let fullTokens = try tokenizer.encodeChat([system, user, assistant],
                                                  addGenerationPrompt: false)
        let tokens = Array(fullTokens.prefix(maxSeqLen))
        guard promptTokens.count < tokens.count else { return nil }
        return RenderedPair(tokens: tokens, promptLen: promptTokens.count)
    }

    /// Next-token shift + right-pad + loss mask. `mask[row][t] == 1` iff the
    /// target at position t is a real token (t+1 < tokens.count) inside the
    /// assistant span (t+1 >= promptLen). Padding and prompt tokens are 0.
    static func makeBatch(_ rendered: [RenderedPair], padToken: Int) -> TokenBatch {
        let cols = rendered.map { $0.tokens.count - 1 }.max() ?? 0
        var inputs: [[Int]] = []
        var targets: [[Int]] = []
        var mask: [[Float]] = []
        for pair in rendered {
            let n = pair.tokens.count
            var input = Array(pair.tokens.dropLast())
            var target = Array(pair.tokens.dropFirst())
            var m = (0..<(n - 1)).map { t -> Float in
                (t + 1 >= pair.promptLen && t + 1 < n) ? 1 : 0
            }
            input.append(contentsOf: Array(repeating: padToken, count: cols - input.count))
            target.append(contentsOf: Array(repeating: padToken, count: cols - target.count))
            m.append(contentsOf: Array(repeating: 0, count: cols - m.count))
            inputs.append(input)
            targets.append(target)
            mask.append(m)
        }
        return TokenBatch(inputs: inputs, targets: targets, mask: mask)
    }

    /// Writes `adapter_config.json` in the exact shape
    /// `MLXLMCommon.LoRAContainer.from(directory:)` decodes — a JSON-encoded
    /// `LoRAConfiguration` (Codable per the pinned 3.31.4 checkout).
    static func writeAdapterConfig(_ config: TrainingConfig, to directory: URL) throws {
        let lora = LoRAConfiguration(
            numLayers: config.numLayers,
            fineTuneType: .lora,
            loraParameters: .init(rank: config.rank, scale: config.scale))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(lora)
            .write(to: directory.appendingPathComponent("adapter_config.json"))
    }
}

/// SplitMix64: tiny, deterministic RNG for epoch shuffling so a seed in
/// `TrainingConfig` reproduces the exact batch order.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Which installed model generates training pairs (Models tab › Pair
/// generation). The generation tasks — bland degradations, one-line
/// backtranslation instructions — don't need the big compose model; the
/// labeler-size model is ~4–5× faster per pair. Persisted in settings;
/// resolution always falls back to the compose model so the choice can
/// never strand pair generation without a generator.
enum PairGenModelChoice: String, CaseIterable, Sendable {
    case compose, labeler

    static let settingsKey = "pairgen.model.role"

    /// The installed model this choice resolves to: the chosen role when
    /// installed, else the compose model. Pure, exposed for tests.
    static func resolve(_ choice: PairGenModelChoice,
                        installed: [InstalledModel]) -> InstalledModel? {
        installed.first { $0.kind == choice.rawValue }
            ?? installed.first { $0.kind == PairGenModelChoice.compose.rawValue }
    }
}
