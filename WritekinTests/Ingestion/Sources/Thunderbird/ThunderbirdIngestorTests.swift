import Testing
import Foundation
import GRDB
@testable import Writekin

/// A progress closure is `@Sendable`, so tests that want to inspect the last
/// reported `IngestProgress` need a Sendable box rather than a captured var.
private final class ProgressBox: @unchecked Sendable {
    var value: IngestProgress?
}

struct ThunderbirdIngestorTests {
    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        [Profile0]
        Name=default
        IsRelative=1
        Path=Profiles/abcd.default
        """.write(to: root.appendingPathComponent("profiles.ini"),
                  atomically: true, encoding: .utf8)
        return root
    }

    func addMbox(root: URL, path: String, messages: [(id: String, body: String)]) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var content = ""
        for (id, body) in messages {
            content += """
            From - Mon Jan 01 00:00:00 2020
            From: me@x.com
            To: f@y.org
            Message-ID: <\(id)>
            Date: Tue, 5 Mar 2019 10:00:00 -0800

            \(body)


            """
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func ingestsSbdNestedSentMbox() async throws {
        let root = try makeRoot()
        try addMbox(root: root,
                    path: "Profiles/abcd.default/ImapMail/imap.gmail.com/[Gmail].sbd/Sent Mail",
                    messages: [("m1@x", "body one"), ("m2@x", "body two")])
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let ingestor = ThunderbirdIngestor(thunderbirdRoot: root, writer: writer)
        try await ingestor.ingest(into: writer, progress: { _ in })
        let count = try await db.writer.read { try Item.fetchCount($0) }
        #expect(count == 2)
        let first = try await db.writer.read { try Item.fetchOne($0) }
        #expect(first?.externalId == "<m1@x>")
        #expect(first?.kind == "email")
    }

    @Test func skipsMsfAndNonSentMboxes() async throws {
        let root = try makeRoot()
        try addMbox(root: root,
                    path: "Profiles/abcd.default/ImapMail/imap.gmail.com/INBOX",
                    messages: [("in1@x", "inbound")])
        try "index".write(
            to: root.appendingPathComponent("Profiles/abcd.default/ImapMail/imap.gmail.com/Sent.msf"),
            atomically: true, encoding: .utf8)
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        try await ThunderbirdIngestor(thunderbirdRoot: root, writer: writer)
            .ingest(into: writer, progress: { _ in })
        #expect(try await db.writer.read { try Item.fetchCount($0) } == 0)
    }

    @Test func reingestIsIdempotent() async throws {
        let root = try makeRoot()
        try addMbox(root: root,
                    path: "Profiles/abcd.default/Mail/Local Folders/Sent",
                    messages: [("m1@x", "hello")])
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let ingestor = ThunderbirdIngestor(thunderbirdRoot: root, writer: writer)
        try await ingestor.ingest(into: writer, progress: { _ in })
        try await ingestor.ingest(into: writer, progress: { _ in })
        #expect(try await db.writer.read { try Item.fetchCount($0) } == 1)
    }

    @Test func unparseableFromFallsBackToNilAccountNotServerDirName() async throws {
        // A message whose From header didn't parse used to fall back to the
        // server directory name (e.g. "imap.googlemail.com"), creating a
        // bogus account. It should instead land with no account rather than
        // inventing one from the directory name.
        let root = try makeRoot()
        let url = root.appendingPathComponent(
            "Profiles/abcd.default/ImapMail/imap.googlemail.com/[Gmail].sbd/Sent Mail")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // No "From:" header at all, so MailMessageParser.parse(...).from is empty.
        let content = """
        From - Mon Jan 01 00:00:00 2020
        To: f@y.org
        Message-ID: <noFrom@x>
        Date: Tue, 5 Mar 2019 10:00:00 -0800

        body


        """
        try content.write(to: url, atomically: true, encoding: .utf8)

        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let ingestor = ThunderbirdIngestor(thunderbirdRoot: root, writer: writer)
        try await ingestor.ingest(into: writer, progress: { _ in })

        let item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.accountId == nil)

        let accountHandles = try await db.writer.read { dbc in
            try String.fetchAll(dbc, sql: "SELECT address_or_handle FROM accounts")
        }
        #expect(!accountHandles.contains("imap.googlemail.com"))
    }

    @Test func unchangedMboxIsSkippedOnSecondRun() async throws {
        let root = try makeRoot()
        let path = "Profiles/abcd.default/Mail/Local Folders/Sent"
        try addMbox(root: root, path: path, messages: [("m1@x", "hello")])
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let ingestor = ThunderbirdIngestor(thunderbirdRoot: root, writer: writer)

        try await ingestor.ingest(into: writer, progress: { _ in })
        #expect(try await db.writer.read { try Item.fetchCount($0) } == 1)

        let finalProgress = ProgressBox()
        try await ingestor.ingest(into: writer, progress: { finalProgress.value = $0 })
        #expect(finalProgress.value?.skippedFiles == 1)
        #expect(finalProgress.value?.itemsLanded == 0)
        // No double-counting: the skip must not also register as a per-item skip.
        #expect(finalProgress.value?.skipped == 0)
        #expect(try await db.writer.read { try Item.fetchCount($0) } == 1)

        // A changed file (new content, new mtime) must be reparsed, not skipped.
        try addMbox(root: root, path: path,
                    messages: [("m1@x", "hello"), ("m2@x", "world")])
        let url = root.appendingPathComponent(path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        let thirdProgress = ProgressBox()
        try await ingestor.ingest(into: writer, progress: { thirdProgress.value = $0 })
        #expect(thirdProgress.value?.skippedFiles == 0)
        #expect(try await db.writer.read { try Item.fetchCount($0) } == 2)
    }

    @Test func cancelledIngestDoesNotStoreFingerprint() async throws {
        let root = try makeRoot()
        let path = "Profiles/abcd.default/Mail/Local Folders/Sent"
        var messages: [(id: String, body: String)] = []
        for i in 0..<20_000 { messages.append(("m\(i)@x", "body \(i)")) }
        try addMbox(root: root, path: path, messages: messages)
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let url = root.appendingPathComponent(path)

        // Cancel the run shortly after it starts — well before the mbox
        // finishes — and confirm no fingerprint lands.
        let task = Task<Void, Error> {
            try await ThunderbirdIngestor(thunderbirdRoot: root, writer: writer)
                .ingest(into: writer) { _ in }
        }
        try await Task.sleep(for: .milliseconds(5))
        task.cancel()
        _ = try? await task.value

        let stored = try await writer.fileFingerprint(path: url.path)
        #expect(stored == nil)
        // A subsequent, uncancelled run must still fully re-read the file.
        try await ThunderbirdIngestor(thunderbirdRoot: root, writer: writer)
            .ingest(into: writer, progress: { _ in })
        let count = try await db.writer.read { try Item.fetchCount($0) }
        #expect(count == 20_000)
    }

    @Test func unparseableMessageIsWrittenDropped() async throws {
        let root = try makeRoot()
        let path = "Profiles/abcd.default/Mail/Local Folders/Sent"
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // A message with headers but no body at all parses to a nil textBody.
        let content = """
        From - Mon Jan 01 00:00:00 2020
        From: me@x.com
        To: f@y.org
        Message-ID: <empty@x>
        Date: Tue, 5 Mar 2019 10:00:00 -0800

        """
        try content.write(to: url, atomically: true, encoding: .utf8)
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let finalProgress = ProgressBox()
        try await ThunderbirdIngestor(thunderbirdRoot: root, writer: writer)
            .ingest(into: writer, progress: { finalProgress.value = $0 })
        #expect(finalProgress.value?.unparseable == 1)
        let dropped = try await db.writer.read { dbc in
            try Item.filter(Column("drop_reason") == "unparseable").fetchAll(dbc)
        }
        #expect(dropped.count == 1)
        #expect(dropped.first?.externalId == "Sent#1")
    }

    @Test func asyncBatchingWritesEveryMessage() async throws {
        let root = try makeRoot()
        var messages: [(id: String, body: String)] = []
        for i in 0..<1_203 {
            messages.append(("m\(i)@x", "body \(i)"))
        }
        try addMbox(root: root,
                    path: "Profiles/abcd.default/Mail/Local Folders/Sent",
                    messages: messages)
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let ingestor = ThunderbirdIngestor(thunderbirdRoot: root, writer: writer)
        try await ingestor.ingest(into: writer, progress: { _ in })
        let count = try await db.writer.read { try Item.fetchCount($0) }
        #expect(count == 1_203)
    }
}
