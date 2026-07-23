import Foundation
import GRDB

struct IMessageAdapter: SourceAdapter {
    static let kind = SourceKind.iMessage

    var chatDB: URL

    init(chatDB: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Messages/chat.db")) {
        self.chatDB = chatDB
    }

    func detect() async throws -> SourceReport {
        let fm = FileManager.default
        let messagesDir = chatDB.deletingLastPathComponent()

        // Probe the parent directory so FDA denial is distinguishable from "no Messages data":
        // without Full Disk Access, stat on chat.db fails and fileExists lies "false".
        do {
            _ = try fm.contentsOfDirectory(atPath: messagesDir.path)
        } catch {
            if isPermissionDenied(error) { throw DetectError.permissionDenied }
            return SourceReport(kind: Self.kind, found: false)
        }
        guard fm.fileExists(atPath: chatDB.path) else {
            return SourceReport(kind: Self.kind, found: false)
        }

        // Copy-first: never open the live database.
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("\(AppIdentity.lowercaseName)-detect-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let copied = tmp.appendingPathComponent("chat.db")
        try fm.copyItem(at: chatDB, to: copied)
        for suffix in ["-wal", "-shm"] {
            let side = chatDB.path + suffix
            if fm.fileExists(atPath: side) {
                try? fm.copyItem(atPath: side, toPath: copied.path + suffix)
            }
        }

        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: copied.path, configuration: config)
        let (count, minRaw, maxRaw) = try await queue.read { db -> (Int, Int64?, Int64?) in
            let row = try Row.fetchOne(db, sql:
                "SELECT COUNT(*) AS c, MIN(date) AS mn, MAX(date) AS mx FROM message WHERE is_from_me = 1")!
            return (row["c"], row["mn"], row["mx"])
        }
        guard count > 0 else {
            return SourceReport(kind: Self.kind, found: false)
        }
        var dateRange: ClosedRange<Date>?
        if let minRaw, let maxRaw {
            dateRange = Self.appleMessageDate(minRaw)...Self.appleMessageDate(maxRaw)
        }
        return SourceReport(kind: Self.kind, found: true,
                            estimatedItemCount: count, dateRange: dateRange)
    }

    /// chat.db stores dates as seconds since 2001-01-01 on old macOS, nanoseconds on modern.
    static func appleMessageDate(_ raw: Int64) -> Date {
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}
