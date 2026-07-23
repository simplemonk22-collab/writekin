import Testing
import Foundation
import GRDB
@testable import Writekin

struct AppleMailIngestorTests {
    func writeEmlx(root: URL, mailboxPath: String, name: String,
                   headers: [String], body: String?) throws {
        let dir = root.appendingPathComponent(mailboxPath)
            .appendingPathComponent("1B2C/Data/Messages")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var content = headers.joined(separator: "\n") + "\n"
        if let body { content += "\n" + body + "\n" }
        let emlx = "\(content.utf8.count)\n" + content + "<plist></plist>"
        try emlx.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func ingestsPopulatedSentMailbox() async throws {
        let root = tempRoot()
        try writeEmlx(root: root, mailboxPath: "V10/A/Sent Messages.mbox", name: "1.emlx",
                      headers: ["From: me@icloud.com", "To: f@y.org",
                                "Message-ID: <s1@x>",
                                "Date: Tue, 5 Mar 2019 10:00:00 -0800"],
                      body: "sent body one")
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        try await AppleMailIngestor(mailRoot: root, writer: writer)
            .ingest(into: writer, progress: { _ in })
        let item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.externalId == "<s1@x>")
        #expect(item?.rawText.contains("sent body one") == true)
    }

    /// Re-ingest of an unchanged mailbox skips the WHOLE mailbox on its
    /// file-listing fingerprint (zero file opens); once the listing changes,
    /// old messages skip via the header-only known-ID check and only the
    /// new file lands.
    @Test func reIngestSkipsKnownMessagesWithoutDuplicating() async throws {
        let root = tempRoot()
        for i in 0..<3 {
            try writeEmlx(root: root, mailboxPath: "V10/A/Sent Messages.mbox",
                          name: "\(i).emlx",
                          headers: ["From: me@icloud.com", "To: f@y.org",
                                    "Message-ID: <s\(i)@x>",
                                    "Date: Tue, 5 Mar 2019 10:00:00 -0800"],
                          body: "sent body \(i)")
        }
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let ingestor = AppleMailIngestor(mailRoot: root, writer: writer)
        try await ingestor.ingest(into: writer, progress: { _ in })

        // Unchanged mailbox: whole-mailbox fingerprint skip.
        nonisolated(unsafe) var lastTally = IngestProgress(phase: .starting)
        try await ingestor.ingest(into: writer, progress: { lastTally = $0 })
        #expect(try await db.writer.read { try Item.fetchCount($0) } == 3)
        #expect(lastTally.itemsLanded == 0)
        #expect(lastTally.skippedFiles == 1)
        #expect(lastTally.skipped == 0)   // never reached the per-file loop

        // New message arrives: fingerprint differs, known messages skip on
        // the header-only Message-ID, only the new one lands.
        try writeEmlx(root: root, mailboxPath: "V10/A/Sent Messages.mbox",
                      name: "3.emlx",
                      headers: ["From: me@icloud.com", "To: f@y.org",
                                "Message-ID: <s3@x>",
                                "Date: Tue, 5 Mar 2019 10:00:00 -0800"],
                      body: "sent body 3")
        try await ingestor.ingest(into: writer, progress: { lastTally = $0 })
        #expect(try await db.writer.read { try Item.fetchCount($0) } == 4)
        #expect(lastTally.itemsLanded == 1)
        #expect(lastTally.skipped == 3)
    }

    @Test func gmailAccountIngestsOnlyOwnFromAllMail() async throws {
        let root = tempRoot()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("V10/A/[Gmail].mbox/Sent Mail.mbox"),
            withIntermediateDirectories: true)
        let allMail = "V10/A/[Gmail].mbox/All Mail.mbox"
        for i in 0..<3 {
            try writeEmlx(root: root, mailboxPath: allMail, name: "s\(i).emlx",
                          headers: ["From: me@g.com", "To: f\(i)@y.org",
                                    "Message-ID: <sent\(i)@x>"],
                          body: "my sent \(i)")
        }
        for i in 0..<9 {
            try writeEmlx(root: root, mailboxPath: allMail, name: "r\(i).emlx",
                          headers: ["From: other\(i)@z.net", "To: me@g.com",
                                    "Delivered-To: me@g.com",
                                    "Message-ID: <rcv\(i)@x>"],
                          body: "inbound \(i)")
        }
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        try await AppleMailIngestor(mailRoot: root, writer: writer)
            .ingest(into: writer, progress: { _ in })
        let kept = try await db.writer.read { dbc in
            try Item.filter(Column("state") == "ingested").fetchCount(dbc)
        }
        #expect(kept == 3)
        let account = try await db.writer.read { try Account.fetchOne($0) }
        #expect(account?.addressesJson.contains("me@g.com") == true)
    }

    @Test func allMailSkipsForeignMessagesCheaply() async throws {
        // Behavioral equivalence with gmailAccountIngestsOnlyOwnFromAllMail: the
        // header-only pre-check must keep the same count as the full-parse path.
        let root = tempRoot()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("V10/A/[Gmail].mbox/Sent Mail.mbox"),
            withIntermediateDirectories: true)
        let allMail = "V10/A/[Gmail].mbox/All Mail.mbox"
        for i in 0..<3 {
            try writeEmlx(root: root, mailboxPath: allMail, name: "s\(i).emlx",
                          headers: ["From: me@g.com", "To: f\(i)@y.org",
                                    "Message-ID: <sent\(i)@x>"],
                          body: "my sent \(i)")
        }
        for i in 0..<9 {
            try writeEmlx(root: root, mailboxPath: allMail, name: "r\(i).emlx",
                          headers: ["From: other\(i)@z.net", "To: me@g.com",
                                    "Delivered-To: me@g.com",
                                    "Message-ID: <rcv\(i)@x>"],
                          body: "inbound \(i)")
        }
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        try await AppleMailIngestor(mailRoot: root, writer: writer)
            .ingest(into: writer, progress: { _ in })
        let kept = try await db.writer.read { dbc in
            try Item.filter(Column("state") == "ingested").fetchCount(dbc)
        }
        #expect(kept == 3)
    }

    @Test func bodilessPartialRecordsDropReason() async throws {
        let root = tempRoot()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("V10/A/[Gmail].mbox/Sent Mail.mbox"),
            withIntermediateDirectories: true)
        let allMail = "V10/A/[Gmail].mbox/All Mail.mbox"
        try writeEmlx(root: root, mailboxPath: allMail, name: "s0.emlx",
                      headers: ["From: me@g.com", "To: f@y.org", "Message-ID: <s0@x>"],
                      body: "real body")
        for i in 0..<4 {
            try writeEmlx(root: root, mailboxPath: allMail, name: "r\(i).emlx",
                          headers: ["From: o\(i)@z.net", "Delivered-To: me@g.com",
                                    "Message-ID: <r\(i)@x>"],
                          body: "inbound \(i)")
        }
        try writeEmlx(root: root, mailboxPath: allMail, name: "p0.partial.emlx",
                      headers: ["From: me@g.com", "To: f@y.org", "Message-ID: <p0@x>"],
                      body: nil)
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        try await AppleMailIngestor(mailRoot: root, writer: writer)
            .ingest(into: writer, progress: { _ in })
        let dropped = try await db.writer.read { dbc in
            try Item.filter(Column("drop_reason") == "body_not_downloaded").fetchCount(dbc)
        }
        #expect(dropped == 1)
    }

    @Test func appleMailIngestorThrowsOnUnreadableRoot() async throws {
        let root = tempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                    ofItemAtPath: root.path)
        }
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        await #expect(throws: DetectError.permissionDenied) {
            try await AppleMailIngestor(mailRoot: root, writer: writer)
                .ingest(into: writer, progress: { _ in })
        }
    }

    /// The parallel parse stage must return outcomes in FILE order no
    /// matter how its worker slices interleave, and the known-ID skip must
    /// run inside the workers. Nonexistent files exercise the decision
    /// order without fixtures: the known check (filename fallback) fires
    /// before the rfc822 read, so b.emlx is `.known` while its unknown
    /// neighbors fall through to `.unparseable`.
    @Test func parseChunkPreservesFileOrderAndSkipsKnown() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let urls = (0..<10).map { base.appendingPathComponent("f\($0).emlx") }
        let outcomes = try await AppleMailIngestor.parseChunk(
            urls, ownAddresses: nil, known: ["f3.emlx", "f7.emlx"])
        #expect(outcomes.count == urls.count)
        for (index, outcome) in outcomes.enumerated() {
            switch (index, outcome) {
            case (3, .known), (7, .known):
                break
            case (3, _), (7, _):
                Issue.record("f\(index) should be .known, got \(outcome)")
            case (_, .unparseable):
                break
            default:
                Issue.record("f\(index) should be .unparseable, got \(outcome)")
            }
        }
    }
}
