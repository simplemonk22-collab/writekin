import Foundation

protocol SourceAdapter: Sendable {
    static var kind: SourceKind { get }
    func detect() async throws -> SourceReport
}

struct SourceReport: Sendable, Equatable {
    var kind: SourceKind
    var found: Bool
    var estimatedItemCount: Int? = nil
    var dateRange: ClosedRange<Date>? = nil
    var accountHints: [String] = []
    var notes: [DetectNote] = []
}

/// A caveat a detector wants shown on its card. Typed rather than a string
/// because adapters run off the MainActor (no `Localization` access) and a
/// pre-rendered string would go stale when the user switches language —
/// the view translates at render time instead.
enum DetectNote: Sendable, Equatable, Hashable {
    case sentCountSampled                        // Apple Mail: All Mail sampling
    case partialDownloads(Int)                   // Apple Mail: .partial.emlx files
    case sentMailboxesEmpty                      // Apple Mail: mailboxes found, nothing on disk
    case noSentMailboxes                         // Apple Mail: data but no Sent recognized
    case maildirUnsupported                      // Thunderbird
    case countEstimatedFromSize                  // Thunderbird
    case itemsInFolder(count: Int, name: String) // Documents: per-root breakdown
    case claudeCodeSessions(Int)                 // Claude Code: transcript count
    case claudeDesktopSessions(Int)              // Claude Desktop: agent-mode count
    case claudeDesktopServerSide                 // Claude Desktop: nothing local
    case whatsAppMirrorsPhone                    // WhatsApp: partial local history
}
