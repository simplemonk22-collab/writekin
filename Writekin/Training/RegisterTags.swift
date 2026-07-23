import Foundation

/// The §8 register-tag grammar string: `[medium: x] [audience: y] [mode: z]`
/// in that order, omitting any nil dimension. This mirrors (but does not
/// replace) `ComposeEngine.tagLine` — that one is private and operates on
/// `RegisterQuery`; unifying them is a welcome follow-up, not in scope here.
enum RegisterTags {
    static func line(medium: String?, audience: String?, mode: String?) -> String {
        var parts: [String] = []
        if let medium { parts.append("[medium: \(medium)]") }
        if let audience { parts.append("[audience: \(audience)]") }
        if let mode { parts.append("[mode: \(mode)]") }
        return parts.joined(separator: " ")
    }
}
