enum SourceKind: String, CaseIterable, Codable, Sendable {
    case appleMail = "apple_mail"
    case iMessage = "imessage"
    case thunderbird
    case fileSystem = "filesystem"
    case claudeCode = "claude_code"
    case claudeDesktop = "claude_desktop"
    case whatsApp = "whatsapp"

    var displayName: String {
        switch self {
        case .appleMail: "Apple Mail"
        case .iMessage: "Messages"
        case .thunderbird: "Thunderbird"
        case .fileSystem: "Documents"
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .whatsApp: "WhatsApp"
        }
    }

    /// A standing caveat about how much of this source's data is reachable
    /// at all — shown under the row so a small count reads as a platform
    /// limit, not a bug. Nil for sources whose data is fully local.
    /// Returns a localization key: this type is nonisolated model code.
    var coverageCaveatKey: L10nKey? {
        switch self {
        case .claudeDesktop: .caveatClaudeDesktop
        default: nil
        }
    }

    /// What a whole-file fingerprint skip skipped, in this source's own
    /// vocabulary — "1 mailbox unchanged" is right for mail and nonsense
    /// for a chat-transcript source. Singular/plural key pair so each
    /// language pluralizes its own way.
    var skippedNounKeys: (one: L10nKey, many: L10nKey) {
        switch self {
        case .appleMail, .thunderbird: (.nounMailbox, .nounMailboxes)
        case .claudeCode, .claudeDesktop: (.nounTranscript, .nounTranscripts)
        case .iMessage, .whatsApp: (.nounChat, .nounChats)
        case .fileSystem: (.nounFile, .nounFiles)
        }
    }

    var symbolName: String {
        switch self {
        case .appleMail: "envelope"
        case .iMessage: "message"
        case .thunderbird: "tray.full"
        case .fileSystem: "doc.text"
        case .claudeCode: "terminal"
        case .claudeDesktop: "bubble.left.and.bubble.right"
        case .whatsApp: "phone.bubble.left"
        }
    }

    /// Sources grouped by what KIND of writing they yield — drives the
    /// sectioned Sources screen. New sources slot into an existing
    /// category (WhatsApp/Slack -> messaging, ChatGPT/Codex -> ai) rather
    /// than growing one flat list.
    enum Category: String, CaseIterable, Sendable {
        case email, messaging, documents, ai

        /// Localization keys, not text — the Sources screen translates.
        var titleKey: L10nKey {
            switch self {
            case .email: .catEmail
            case .messaging: .catMessaging
            case .documents: .catDocuments
            case .ai: .catAI
            }
        }

        var captionKey: L10nKey {
            switch self {
            case .email: .catEmailCaption
            case .messaging: .catMessagingCaption
            case .documents: .catDocumentsCaption
            case .ai: .catAICaption
            }
        }
    }

    /// True for sources whose data lives in a TCC-protected location that
    /// requires Full Disk Access (~/Library/Mail, ~/Library/Messages).
    /// Plain home-directory sources (Thunderbird profiles, document
    /// folders, ~/.claude transcripts, Claude Desktop's Application
    /// Support) need no special permission. WhatsApp's group container is
    /// deliberately NOT listed: whether it's gated varies by macOS
    /// version, so its adapter reports a permission failure at detect time
    /// instead of assuming.
    var requiresFullDiskAccess: Bool {
        switch self {
        case .appleMail, .iMessage: true
        default: false
        }
    }

    var category: Category {
        switch self {
        case .appleMail, .thunderbird: .email
        case .iMessage, .whatsApp: .messaging
        case .fileSystem: .documents
        case .claudeCode, .claudeDesktop: .ai
        }
    }
}
