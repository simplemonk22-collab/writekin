import Testing
import Foundation
import GRDB
@testable import Writekin

/// One composite fixture: Thunderbird + Apple Mail hold an overlapping sent
/// message (cross-source dedupe), iMessage contributes chat items, docs
/// contribute a file; passes clean, filter, and near-dupe the result.
@MainActor
struct PipelineIntegrationTests {
    @Test func fullPipelineOverCompositeFixture() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        // Thunderbird: 2 sent messages (one shared with Apple Mail).
        // Bodies are padded past the 30-word email min from FilterConfig so they survive the filter pass.
        let sharedBody = "Let me summarize the plan we discussed on our call earlier this week: we will ship detection first, then move on to ingestion, then build out the dashboard, and we will keep everything running locally on device without ever sending data to any external server or third party service."
        let tbSent = root.appendingPathComponent(
            "tb/Profiles/p.default/ImapMail/imap.g.com/[Gmail].sbd")
        try fm.createDirectory(at: tbSent, withIntermediateDirectories: true)
        try """
        From - Mon Jan 01 00:00:00 2020
        From: me@g.com
        To: f@y.org
        Message-ID: <shared@x>
        Date: Tue, 5 Mar 2019 10:00:00 -0800

        \(sharedBody)

        From - Mon Jan 02 00:00:00 2020
        From: me@g.com
        To: f@y.org
        Message-ID: <tb-only@x>
        Date: Wed, 6 Mar 2019 10:00:00 -0800

        Thunderbird-only message body with plenty of words to clear the filter threshold for email items in the corpus pipeline test we are running here today, and then a few more words tacked on at the end just to be safe about it.
        """.write(to: root.appendingPathComponent(
            "tb/Profiles/p.default/ImapMail/imap.g.com/[Gmail].sbd/Sent Mail"),
                  atomically: true, encoding: .utf8)
        try """
        [Profile0]
        Name=default
        IsRelative=1
        Path=Profiles/p.default
        """.write(to: root.appendingPathComponent("tb/profiles.ini"),
                  atomically: true, encoding: .utf8)

        // Apple Mail: same shared message in a populated Sent mailbox.
        let amSent = root.appendingPathComponent(
            "mail/V10/A/Sent Messages.mbox/1/Data/Messages")
        try fm.createDirectory(at: amSent, withIntermediateDirectories: true)
        let amBody = "From: me@g.com\nTo: f@y.org\nMessage-ID: <shared@x>\nDate: Tue, 5 Mar 2019 10:00:00 -0800\n\n\(sharedBody)\n"
        try ("\(amBody.utf8.count)\n" + amBody + "<plist></plist>")
            .write(to: amSent.appendingPathComponent("1.emlx"),
                   atomically: true, encoding: .utf8)

        // Docs: one markdown file.
        let docs = root.appendingPathComponent("docs")
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try String(repeating: "essay sentence with several words here. ", count: 10)
            .write(to: docs.appendingPathComponent("essay.md"),
                   atomically: true, encoding: .utf8)

        // iMessage via fake exporter.
        let transcript = """
        Jan 05, 2026  7:37:06 PM
        Me
        hey want to grab dinner at that new ramen place tomorrow night maybe

        Jan 05, 2026  7:38:00 PM
        +15551234567
        sure
        """
        let chatDB = root.appendingPathComponent("chat.db")
        try Data("stub".utf8).write(to: chatDB)

        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let coordinator = IngestCoordinator()
        await coordinator.runAll(ingestors: [
            ThunderbirdIngestor(thunderbirdRoot: root.appendingPathComponent("tb"),
                                writer: writer),
            AppleMailIngestor(mailRoot: root.appendingPathComponent("mail"),
                              writer: writer),
            IMessageIngestor(chatDB: chatDB,
                             exporter: FakeExporter(transcript: transcript,
                                                    fileName: "+15551234567.txt"),
                             writer: writer),
            DocumentIngestor(roots: [docs], writer: writer),
        ], db: db)

        let items = try await db.writer.read { try Item.fetchAll($0) }
        // shared@x landed once (cross-source dedupe), tb-only once, 1 sms, 1 doc.
        #expect(items.filter { $0.externalId == "<shared@x>" }.count == 1)
        let kept = items.filter { $0.state == "kept" }
        #expect(kept.count == 4)
        #expect(kept.allSatisfy { $0.cleanText != nil && $0.simhash64 != nil })
        let stats = try CorpusStatsQuery.fetch(db)
        #expect(stats.keptItems == 4)
        #expect(stats.perMedium.keys.sorted() == ["doc", "email", "sms"])
    }
}
