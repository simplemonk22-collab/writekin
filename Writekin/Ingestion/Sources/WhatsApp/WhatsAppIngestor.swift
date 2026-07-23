import Foundation
import GRDB

/// WhatsApp Desktop stores its mirrored message history in a plain Core
/// Data SQLite (`ChatStorage.sqlite` in the app's group container) —
/// `ZWAMESSAGE.ZISFROMME = 1` rows with text are the user's own sent
/// messages. Same voice register as iMessage, so items land as kind "sms".
///
/// Caveat the detect card states: the DESKTOP app only mirrors recent
/// history from the phone, so this is a window, not an archive — it grows
/// as WhatsApp is used with the Mac app open.
enum WhatsAppStore {
    static var defaultChatStorage: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite")
    }

    struct SentMessage: Sendable, Equatable {
        var stanzaID: String
        var text: String
        var date: Date?
        var chatPartner: String?
        var sessionPK: Int64?
    }

    /// Copies the store (+WAL/SHM) to a temp dir and reads the user's sent
    /// text messages. Copy-first mirrors the iMessage ingestor: never open
    /// another app's live database, even read-only.
    static func sentMessages(chatStorage: URL) throws -> [SentMessage] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: chatStorage.path) else { return [] }
        let work = fm.temporaryDirectory
            .appendingPathComponent("\(AppIdentity.lowercaseName)-whatsapp-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let copied = work.appendingPathComponent("ChatStorage.sqlite")
        try fm.copyItem(at: chatStorage, to: copied)
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: chatStorage.path + suffix) {
            try? fm.copyItem(atPath: chatStorage.path + suffix, toPath: copied.path + suffix)
        }

        var config = Configuration()
        config.readonly = false   // WAL checkpoint on open needs write access to the COPY
        let queue = try DatabaseQueue(path: copied.path, configuration: config)
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.Z_PK AS pk, m.ZSTANZAID AS stanza, m.ZTEXT AS text,
                       m.ZMESSAGEDATE AS date, m.ZCHATSESSION AS session,
                       s.ZPARTNERNAME AS partner, s.ZCONTACTJID AS jid
                FROM ZWAMESSAGE m
                LEFT JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
                WHERE m.ZISFROMME = 1 AND m.ZTEXT IS NOT NULL AND LENGTH(m.ZTEXT) > 0
                ORDER BY m.Z_PK
                """).map { row in
                let partner = (row["partner"] as String?) ?? (row["jid"] as String?)
                return SentMessage(
                    stanzaID: (row["stanza"] as String?) ?? "pk-\(row["pk"] as Int64? ?? 0)",
                    text: row["text"] as String? ?? "",
                    // Core Data timestamps: seconds since 2001-01-01 UTC.
                    date: (row["date"] as Double?)
                        .map { Date(timeIntervalSinceReferenceDate: $0) },
                    chatPartner: partner,
                    sessionPK: row["session"] as Int64?)
            }
        }
    }
}

struct WhatsAppAdapter: SourceAdapter {
    static let kind = SourceKind.whatsApp
    var chatStorage: URL = WhatsAppStore.defaultChatStorage

    func detect() async throws -> SourceReport {
        guard FileManager.default.fileExists(atPath: chatStorage.path) else {
            return SourceReport(kind: Self.kind, found: false)
        }
        // Whether another app's group container is TCC-gated varies by
        // macOS version — surface a permission failure as the standard
        // needs-access card instead of a false "nothing found".
        let sent: [WhatsAppStore.SentMessage]
        do {
            sent = try WhatsAppStore.sentMessages(chatStorage: chatStorage)
        } catch {
            if isPermissionDenied(error) { throw DetectError.permissionDenied }
            throw error
        }
        return SourceReport(kind: Self.kind, found: !sent.isEmpty,
                            estimatedItemCount: sent.isEmpty ? nil : sent.count,
                            notes: [.whatsAppMirrorsPhone])
    }
}

struct WhatsAppIngestor: SourceIngestor {
    static let kind = SourceKind.whatsApp

    var chatStorage: URL = WhatsAppStore.defaultChatStorage
    var writer: CorpusWriter

    init(chatStorage: URL = WhatsAppStore.defaultChatStorage, writer: CorpusWriter) {
        self.chatStorage = chatStorage
        self.writer = writer
    }

    func ingest(into writer: CorpusWriter,
                progress: @Sendable (IngestProgress) -> Void) async throws {
        guard FileManager.default.fileExists(atPath: chatStorage.path) else { return }
        let sourceID = try await writer.sourceID(for: Self.kind)
        var tally = IngestProgress(phase: .readingWhatsAppMessages)
        progress(tally)

        // All messages are already in memory from the sqlite copy, so one
        // batched write (chunked transactions inside) replaces the
        // commit-per-message loop.
        let raws = try WhatsAppStore.sentMessages(chatStorage: chatStorage).map { message in
            RawItem(
                externalID: "whatsapp:\(message.stanzaID)",
                kind: .sms,
                authoredAt: message.date,
                authoredAtConfidence: message.date != nil ? .embedded : nil,
                accountHint: nil,
                recipients: message.chatPartner.map { [$0] } ?? [],
                threadID: message.sessionPK.map { "whatsapp-\($0)" },
                rawText: message.text)
        }
        for result in try await writer.writeBatch(raws, sourceID: sourceID, accountID: nil) {
            if case .inserted = result { tally.itemsLanded += 1 }
            else { tally.skipped += 1 }
        }
        progress(tally)
        try await writer.markSynced(sourceID: sourceID)
    }
}
