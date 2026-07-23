import Foundation

/// Sentence-terminator characters shared by EVERY splitter — chunking,
/// draft conventions, voice-check stats, style profiling, contamination
/// scan. One definition so they can't drift, and it includes the CJK
/// full-width forms and ellipsis so non-English text splits correctly
/// (i18n Tier A: language-tolerant pipeline under an English UI).
enum TextBoundaries {
    static let sentenceTerminators: Set<Character> =
        [".", "!", "?", "。", "！", "？", "…"]
    static let sentenceTerminatorsAndNewline: Set<Character> =
        sentenceTerminators.union(["\n"])
    static let terminatorCharacterSet = CharacterSet(charactersIn: ".!?。！？…")
    static let terminatorAndNewlineCharacterSet = CharacterSet(charactersIn: ".!?。！？…\n")
}
