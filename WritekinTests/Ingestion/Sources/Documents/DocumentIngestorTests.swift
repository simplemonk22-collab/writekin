import Testing
import Foundation
import GRDB
@testable import Writekin

struct DocumentIngestorTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func ingestsPlainTextAndMarkdown() async throws {
        let root = try tempDir()
        try "essay body text".write(to: root.appendingPathComponent("essay.md"),
                                    atomically: true, encoding: .utf8)
        try "note body".write(to: root.appendingPathComponent("2019-03-05-note.txt"),
                              atomically: true, encoding: .utf8)
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        try await DocumentIngestor(roots: [root], writer: writer)
            .ingest(into: writer, progress: { _ in })
        let items = try await db.writer.read { try Item.fetchAll($0) }
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.kind == "doc" })
        let dated = items.first { $0.externalId?.contains("2019-03-05") == true }
        #expect(dated?.dateConfidence == "filename")
        let calendar = Calendar(identifier: .gregorian)
        #expect(dated.flatMap(\.authoredAt).map {
            calendar.component(.year, from: $0) } == 2019)
    }

    /// Unchanged files skip before extraction on their size:mtime
    /// fingerprint; an edited file re-ingests and UPDATES its row in place,
    /// with derived fields reset so the passes re-process the new text.
    @Test func unchangedFileSkipsAndEditedFileUpdatesInPlace() async throws {
        let root = try tempDir()
        let file = root.appendingPathComponent("essay.txt")
        try "original essay body".write(to: file, atomically: true, encoding: .utf8)
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let ingestor = DocumentIngestor(roots: [root], writer: writer)
        try await ingestor.ingest(into: writer, progress: { _ in })

        // Unchanged: fingerprint skip, nothing new lands.
        nonisolated(unsafe) var lastTally = IngestProgress(phase: .starting)
        try await ingestor.ingest(into: writer, progress: { lastTally = $0 })
        #expect(lastTally.itemsLanded == 0)
        #expect(lastTally.skipped == 1)
        #expect(try await db.writer.read { try Item.fetchCount($0) } == 1)

        // Edited: content and mtime change → same row, new text, derived
        // fields reset for the pass pipeline.
        try "a completely rewritten and longer essay body"
            .write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: file.path)
        try await ingestor.ingest(into: writer, progress: { lastTally = $0 })
        #expect(lastTally.itemsLanded == 1)
        let items = try await db.writer.read { try Item.fetchAll($0) }
        #expect(items.count == 1)   // updated, not duplicated
        #expect(items[0].rawText.contains("rewritten"))
        #expect(items[0].state == "ingested")
        #expect(items[0].cleanText == nil)
        #expect(items[0].mode == nil)
    }

    @Test func mtimeFallbackConfidence() async throws {
        let root = try tempDir()
        try "plain".write(to: root.appendingPathComponent("undated.txt"),
                          atomically: true, encoding: .utf8)
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        try await DocumentIngestor(roots: [root], writer: writer)
            .ingest(into: writer, progress: { _ in })
        let item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.dateConfidence == "mtime")
        #expect(item?.authoredAt != nil)
    }

    @Test func pagesBundleRecordsUnsupported() async throws {
        let root = try tempDir()
        let bundle = root.appendingPathComponent("letter.pages")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "internals".write(to: bundle.appendingPathComponent("x.txt"),
                              atomically: true, encoding: .utf8)
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        try await DocumentIngestor(roots: [root], writer: writer)
            .ingest(into: writer, progress: { _ in })
        let dropped = try await db.writer.read { dbc in
            try Item.filter(Column("drop_reason") == "format_unsupported").fetchCount(dbc)
        }
        #expect(dropped == 1)
    }

    @Test func extractsDocxText() throws {
        let dir = try tempDir()
        let docDir = dir.appendingPathComponent("word")
        try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?><w:document xmlns:w="x"><w:body>\
        <w:p><w:r><w:t>Hello docx</w:t></w:r></w:p>\
        <w:p><w:r><w:t>Second para</w:t></w:r></w:p></w:body></w:document>
        """.write(to: docDir.appendingPathComponent("document.xml"),
                  atomically: true, encoding: .utf8)
        let docx = dir.appendingPathComponent("test.docx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-q", "-r", docx.path, "word"]
        try zip.run(); zip.waitUntilExit()
        let text = DocumentTextExtractor.text(of: docx)
        #expect(text?.contains("Hello docx") == true)
        #expect(text?.contains("Second para") == true)
    }

    @Test func decodesXMLEntities() {
        let decoded = DocumentTextExtractor.decodeXMLEntities("Tom &amp; Jerry &lt;3 &quot;quotes&quot; &apos;n&apos; stuff &gt; done")
        #expect(decoded == "Tom & Jerry <3 \"quotes\" 'n' stuff > done")
    }

    /// `&amp;` must decode last: text that was already double-encoded
    /// (e.g. a literal "&lt;" typed by the user, stored in the XML as
    /// "&amp;lt;") should decode to "&lt;" once, not cascade into "<".
    @Test func doesNotDoubleDecodeAmpersandFirst() {
        let decoded = DocumentTextExtractor.decodeXMLEntities("&amp;lt;")
        #expect(decoded == "&lt;")
    }

    @Test func extractsDocxTextWithEntitiesDecoded() throws {
        let dir = try tempDir()
        let docDir = dir.appendingPathComponent("word")
        try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?><w:document xmlns:w="x"><w:body>\
        <w:p><w:r><w:t>Tom &amp; Jerry &lt;3 &quot;friends&quot; &apos;forever&apos;</w:t></w:r></w:p>\
        </w:body></w:document>
        """.write(to: docDir.appendingPathComponent("document.xml"),
                  atomically: true, encoding: .utf8)
        let docx = dir.appendingPathComponent("entities.docx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-q", "-r", docx.path, "word"]
        try zip.run(); zip.waitUntilExit()
        let text = DocumentTextExtractor.text(of: docx)
        #expect(text == "Tom & Jerry <3 \"friends\" 'forever'")
    }

    @Test func unparseableDocIsWrittenDroppedOnceAcrossTwoRuns() async throws {
        let root = try tempDir()
        let path = root.appendingPathComponent("empty.txt")
        try "".write(to: path, atomically: true, encoding: .utf8)
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        final class ProgressBox: @unchecked Sendable {
            var value: IngestProgress?
        }
        let box1 = ProgressBox()
        try await DocumentIngestor(roots: [root], writer: writer)
            .ingest(into: writer, progress: { box1.value = $0 })
        #expect(box1.value?.unparseable == 1)
        let firstDropped = try await db.writer.read { dbc in
            try Item.filter(Column("drop_reason") == "unparseable").fetchAll(dbc)
        }
        #expect(firstDropped.count == 1)
        #expect(firstDropped.first?.externalId?.hasSuffix("empty.txt") == true)
        #expect(firstDropped.first?.rawText == "")

        // Re-ingest the unchanged file: its fingerprint was recorded with
        // the drop, so it now skips before extraction — no second row, no
        // re-attempt (only a CHANGED file earns another parse).
        let box2 = ProgressBox()
        try await DocumentIngestor(roots: [root], writer: writer)
            .ingest(into: writer, progress: { box2.value = $0 })
        #expect(box2.value?.unparseable == 0)
        #expect(box2.value?.skipped == 1)
        let secondDropped = try await db.writer.read { dbc in
            try Item.filter(Column("drop_reason") == "unparseable").fetchCount(dbc)
        }
        #expect(secondDropped == 1)
    }

    @Test func extractsRtfFromBackgroundThread() async throws {
        let dir = try tempDir()
        let rtf = dir.appendingPathComponent("test.rtf")
        try "{\\\\rtf1\\\\ansi Hello RTF body}".write(to: rtf, atomically: true, encoding: .utf8)
        let text = try await Task.detached {
            DocumentTextExtractor.text(of: rtf)
        }.value
        #expect(text?.contains("Hello RTF body") == true)
    }
}
