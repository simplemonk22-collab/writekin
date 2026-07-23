import Foundation

/// A single message in a composed prompt (excluding the system message, which
/// has its own dedicated field on ``ComposedPrompt``).
struct PromptMessage: Sendable, Equatable {
    var role: String
    var text: String
}

/// A fully-assembled prompt ready to hand to a ``TextGenerating`` backend.
struct ComposedPrompt: Sendable, Equatable {
    var system: String
    var messages: [PromptMessage]
}

/// Abstraction over "something that turns a composed prompt into generated
/// text, streaming tokens as they arrive." Implemented by ``FakeGenerator``
/// (tests/previews) and ``ModelRuntime`` (the real on-device MLX backend).
protocol TextGenerating: Sendable {
    func generate(
        prompt: ComposedPrompt, maxTokens: Int, temperature: Double,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String
}

/// A scripted ``TextGenerating`` implementation for tests and SwiftUI
/// previews. Returns each string in `script` in order, cycling back to the
/// start once exhausted, streaming it in ~3 chunks via `onToken`.
///
/// Lives in the app target (not the test target) so both unit tests and
/// previews can share a single implementation.
final class FakeGenerator: TextGenerating, @unchecked Sendable {
    private let script: [String]
    private let lock = NSLock()
    private var nextScriptIndex = 0
    private var _receivedPrompts: [ComposedPrompt] = []

    var receivedPrompts: [ComposedPrompt] {
        lock.lock()
        defer { lock.unlock() }
        return _receivedPrompts
    }

    init(script: [String]) {
        self.script = script
    }

    func generate(
        prompt: ComposedPrompt, maxTokens: Int, temperature: Double,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let output = nextScriptedOutput(recording: prompt)

        for chunk in Self.chunked(output, into: 3) {
            onToken(chunk)
        }

        return output
    }

    private func nextScriptedOutput(recording prompt: ComposedPrompt) -> String {
        lock.lock()
        defer { lock.unlock() }

        _receivedPrompts.append(prompt)

        guard !script.isEmpty else { return "" }
        let output = script[nextScriptIndex % script.count]
        nextScriptIndex += 1
        return output
    }

    /// Splits `text` into up to `count` roughly-even chunks (by character),
    /// preserving order and never splitting inside a character. Returns fewer
    /// chunks than `count` for very short strings, and none for an empty string.
    private static func chunked(_ text: String, into count: Int) -> [String] {
        guard !text.isEmpty, count > 0 else { return [] }

        let characters = Array(text)
        let chunkSize = max(1, Int(ceil(Double(characters.count) / Double(count))))

        var chunks: [String] = []
        var index = 0
        while index < characters.count {
            let end = min(index + chunkSize, characters.count)
            chunks.append(String(characters[index..<end]))
            index = end
        }
        return chunks
    }
}
