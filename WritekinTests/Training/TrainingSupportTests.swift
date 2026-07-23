import Testing
import Foundation
import MLXLMCommon
@testable import Writekin

/// Deterministic template stand-in: each message renders as [1] followed by
/// one token per whitespace-separated word (token id = word length);
/// addGenerationPrompt appends [2].
private struct FakeChatTokenizer: ChatTokenizing {
    func encodeChat(_ messages: [TrainChatMessage], addGenerationPrompt: Bool) throws -> [Int] {
        var tokens: [Int] = []
        for message in messages {
            tokens.append(1)
            tokens.append(contentsOf: message.content
                .split(whereSeparator: \.isWhitespace).map(\.count))
        }
        if addGenerationPrompt { tokens.append(2) }
        return tokens
    }
}

struct TrainingSupportTests {
    /// Defaults raised after runs 1–7: rank 8 / 600 iters / lr 1e-5 was
    /// ~13% of one epoch at batch 1 on a ~4.6k-pair dataset — adapters so
    /// faint the prompt-steered base model often matched them.
    @Test func trainingConfigDefaultsMatchSpec() {
        let c = TrainingConfig()
        #expect(c.rank == 16)
        #expect(c.scale == 20)
        #expect(c.numLayers == 16)
        #expect(c.batchSize == 1)
        #expect(c.iterations == 2_000)
        #expect(c.learningRate == 1e-5)
        #expect(c.maxSeqLen == 1_024)
    }

    @Test func systemLineWithAndWithoutTags() {
        #expect(TrainingSupport.systemLine(tags: "") == "Write in the author's voice.")
        #expect(TrainingSupport.systemLine(tags: "[medium: sms]")
                == "Write in the author's voice. [medium: sms]")
    }

    @Test func renderComputesPromptLenFromGenerationPromptBoundary() throws {
        let rendered = try #require(try TrainingSupport.render(
            systemTags: "[medium: sms]", inputText: "aa bb", targetText: "ccc dddd",
            tokenizer: FakeChatTokenizer(), maxSeqLen: 1_024))
        // system "Write in the author's voice. [medium: sms]" = 7 words
        // prompt: [1]+7 + [1]+2 + [2] = 12 tokens
        #expect(rendered.promptLen == 12)
        // full:   [1]+7 + [1]+2 + [1]+2 = 14 tokens
        #expect(rendered.tokens.count == 14)
    }

    @Test func renderDropsPairWhosePromptFillsMaxSeqLen() throws {
        let longInput = Array(repeating: "word", count: 50).joined(separator: " ")
        let dropped = try TrainingSupport.render(
            systemTags: "", inputText: longInput, targetText: "tail",
            tokenizer: FakeChatTokenizer(), maxSeqLen: 40)
        #expect(dropped == nil)
    }

    @Test func renderTruncatesToMaxSeqLen() throws {
        let longTarget = Array(repeating: "word", count: 100).joined(separator: " ")
        let rendered = try #require(try TrainingSupport.render(
            systemTags: "", inputText: "hi", targetText: longTarget,
            tokenizer: FakeChatTokenizer(), maxSeqLen: 32))
        #expect(rendered.tokens.count == 32)
        #expect(rendered.promptLen < 32)
    }

    @Test func makeBatchShiftsPadsAndMasks() {
        let a = RenderedPair(tokens: [10, 11, 12, 13, 14], promptLen: 3)
        let b = RenderedPair(tokens: [20, 21, 22], promptLen: 1)
        let batch = TrainingSupport.makeBatch([a, b], padToken: 0)
        // cols = max(count) - 1 = 4
        #expect(batch.inputs == [[10, 11, 12, 13], [20, 21, 0, 0]])
        #expect(batch.targets == [[11, 12, 13, 14], [21, 22, 0, 0]])
        // a: target position t predicts seq position t+1; on where t+1 >= 3 and t+1 < 5
        // b: promptLen 1 → positions 1 and 2 are both learned; padding masked off
        #expect(batch.mask == [[0, 0, 1, 1], [1, 1, 0, 0]])
    }

    @Test func adapterConfigRoundTripsThroughLoRAConfiguration() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vp-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var config = TrainingConfig()
        config.rank = 4
        config.numLayers = 8
        try TrainingSupport.writeAdapterConfig(config, to: dir)
        let data = try Data(contentsOf: dir.appendingPathComponent("adapter_config.json"))
        let decoded = try JSONDecoder().decode(LoRAConfiguration.self, from: data)
        #expect(decoded.numLayers == 8)
        #expect(decoded.fineTuneType == .lora)
        #expect(decoded.loraParameters.rank == 4)
        #expect(decoded.loraParameters.scale == 20)
    }

    @Test func seededRNGIsDeterministic() {
        var a = SeededRNG(seed: 42)
        var b = SeededRNG(seed: 42)
        #expect((0..<5).map { _ in a.next() } == (0..<5).map { _ in b.next() })
    }
}
