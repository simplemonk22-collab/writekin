import Foundation

/// Strips hybrid-reasoning `<think>…</think>` blocks from model output.
/// Qwen3-generation models emit them by default; `ModelRuntime` disables
/// thinking via the chat template (`enable_thinking: false`), and this is
/// the belt-and-suspenders layer for the occasional block that slips
/// through anyway — reasoning is never part of a draft, a pair target, or
/// a label.
enum ThinkTags {
    static func strip(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
        // An unterminated block (generation hit the token cap mid-thought)
        // is all reasoning, no draft — drop it rather than show it.
        if let start = result.range(of: "<think>") {
            result = String(result[..<start.lowerBound])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
