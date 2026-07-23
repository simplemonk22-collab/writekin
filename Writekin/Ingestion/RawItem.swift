import Foundation

enum ItemKind: String, CaseIterable, Sendable {
    case email, sms, doc, chat
}

enum DateConfidence: String, Sendable {
    case embedded, filename, mtime
}

struct RawItem: Sendable {
    var externalID: String
    var kind: ItemKind
    var authoredAt: Date?
    var authoredAtConfidence: DateConfidence?
    var accountHint: String?
    var recipients: [String] = []
    var threadID: String?
    var rawText: String
    /// The most recent inbound (non-"Me") message body preceding this item in
    /// its conversation, if it arrived within 12 hours — the reply-conditioning
    /// context for pair generation (spec §2). sms only; email context is
    /// derived from raw_text at pair-generation time; docs never have context.
    var contextText: String? = nil
}

/// What an ingestor is doing right now, typed rather than a pre-rendered
/// string because ingestors run off the MainActor (no `Localization` access)
/// and a baked string would go stale when the user switches language — the
/// view translates at render time instead (see `SourceIngestRow.phaseText`,
/// same pattern as `DetectNote`). File/account/chat names ride along as
/// associated data; only the constant English fragments became cases.
enum IngestPhase: Sendable, Equatable {
    case starting
    case readingAppleMail
    case readingThunderbirdMailboxes
    case readingDocuments
    case readingWhatsAppMessages
    case readingClaudeCodeSessions
    case readingClaudeDesktopSessions
    case exportingMessages
    case scanningAllMail
    /// "Reading <name>" — an account dir, mbox file, chat, or folder name.
    case reading(String)
    /// "Up to date — <name>" — a fingerprint-skipped account dir or mbox.
    case upToDate(String)
}

struct IngestProgress: Sendable, Equatable {
    var phase: IngestPhase
    var itemsLanded: Int = 0
    var skipped: Int = 0
    var unparseable: Int = 0
    /// Whole files skipped entirely via an unchanged-mbox fingerprint match
    /// (see CorpusWriter's mbox fingerprint methods). Deliberately separate
    /// from `skipped` (per-item dedupe skips) so the finished-summary line
    /// never double-counts a skipped file's messages as both "file skipped"
    /// and "item skipped".
    var skippedFiles: Int = 0
}
