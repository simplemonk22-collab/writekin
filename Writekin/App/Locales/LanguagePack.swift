import Foundation

/// Everything one language contributes, in one value: its display-string
/// table plus its match vocabularies over draft text (greetings, signoffs,
/// casual lexicon, assistant imperatives — used by the voice check's
/// boundary signals and the register detector).
///
/// Registration is COMPILER-ENFORCED and lives in exactly one place:
/// `AppLanguage.pack` (Localization.swift) is an exhaustive switch, so
/// adding an `AppLanguage` case refuses to build until its pack is wired.
/// Nothing else registers anything — `L10nTables.table(for:)` and the
/// `BoundaryMarkers` unions below all derive from the packs.
struct LanguagePack: Sendable {
    /// The `[L10nKey: String]` display strings (the big per-language file).
    let table: [L10nKey: String]
    /// Match lists over DRAFT text — lowercased, prefix/token-matched.
    /// These aren't table entries because a draft's language is whatever
    /// the user pasted, regardless of the app language: detection matches
    /// the union across all packs.
    let greetings: [String]
    let signoffs: [String]
    let casualWords: [String]
    let assistantImperatives: [String]
}

/// Union facade over every registered pack — the one vocabulary the voice
/// check and the register detector share. Derived, so adding a language
/// never touches this file.
enum BoundaryMarkers {
    static let greetings = AppLanguage.allCases.flatMap { $0.pack.greetings }
    static let signoffs = AppLanguage.allCases.flatMap { $0.pack.signoffs }
    static let casualWords = AppLanguage.allCases.flatMap { $0.pack.casualWords }
    static let assistantImperatives =
        AppLanguage.allCases.flatMap { $0.pack.assistantImperatives }
}
