import Testing
import Foundation
import GRDB
@testable import Writekin

struct CleanPassTests {
    @Test func stripsSignatureAndQuotedTail() {
        let raw = """
        Sounds good, see you at 7.

        On Mar 5, 2019, John wrote:
        > are we still on for dinner
        > tonight?

        --\u{20}
        Jane Doe
        sent from my phone
        """
        let cleaned = MailTextCleaner.clean(raw)
        #expect(cleaned == "Sounds good, see you at 7.")
    }

    @Test func stripsForwardedBoilerplate() {
        let raw = "my comment\n\nBegin forwarded message:\nFrom: x@y.z\nbody"
        #expect(MailTextCleaner.clean(raw) == "my comment")
    }

    @Test func keepsInlineQuotesInMiddle() {
        let raw = "> you said this\n\nand I reply inline here with enough text"
        let cleaned = MailTextCleaner.clean(raw)
        #expect(cleaned.contains("I reply inline"))
    }

    @Test func passPopulatesCleanWordCountAndLang() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var item = Item.stub(sourceId: s.id!, externalId: "x", rawText: "  hello   there  friend  ")
            item.kind = "sms"
            try item.insert(dbc)
        }
        try CleanPass(db: db).run()
        let item = try db.writer.read { try Item.fetchOne($0) }
        #expect(item?.cleanText == "hello there friend")
        #expect(item?.wordCount == 3)
        #expect(item?.lang == "en")
    }

    @Test func passIsIdempotentAndSkipsDropped() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var dropped = Item.stub(sourceId: s.id!, externalId: "d", rawText: "dropped")
            dropped.state = "filtered_out"; dropped.dropReason = "self_generated"
            try dropped.insert(dbc)
        }
        try CleanPass(db: db).run()
        try CleanPass(db: db).run()
        let item = try db.writer.read { try Item.fetchOne($0) }
        #expect(item?.cleanText == nil)
    }

    @Test func stripsAttachmentPathLinesFromSMS() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let raw = "check this out\n/Users/janedoe/Library/Messages/Attachments/92/02/AB-CD/IMG_9087.heic\nfunny right?"
            var item = Item.stub(sourceId: s.id!, externalId: "x", rawText: raw)
            item.kind = "sms"
            try item.insert(dbc)
        }
        try CleanPass(db: db).run()
        let item = try db.writer.read { try Item.fetchOne($0) }
        #expect(item?.cleanText == "check this out funny right?")
    }

    @Test func stripsStickerAndTapbackLinesFromSMS() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let raw = """
            Also am I an actor in a back pain commercial
                😂 by Alex
                😂 by Elise
                Disliked by Sam Jones
                Normal Sticker from Me: /Users/janedoe/Library/Messages/StickerCache/82e4-sticker/82e4-sticker.png from Me
            """
            var item = Item.stub(sourceId: s.id!, externalId: "t", rawText: raw)
            item.kind = "sms"
            try item.insert(dbc)
        }
        try CleanPass(db: db).run()
        let item = try db.writer.read { try Item.fetchOne($0) }
        #expect(item?.cleanText == "Also am I an actor in a back pain commercial")
    }

    @Test func stripsStickerLinesWithNonLibraryPaths() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let raw = """
            haha that one is perfect
                Sticker from Sam Jones: /var/photos/derived/1cca2ed4-sticker.heic from Sam Jones
            """
            var item = Item.stub(sourceId: s.id!, externalId: "v", rawText: raw)
            item.kind = "sms"
            try item.insert(dbc)
        }
        try CleanPass(db: db).run()
        let item = try db.writer.read { try Item.fetchOne($0) }
        #expect(item?.cleanText == "haha that one is perfect")
    }

    @Test func keepsColonSlashProseInSMS() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let raw = "the config lives at: /etc/hosts if you need it"
            var item = Item.stub(sourceId: s.id!, externalId: "p", rawText: raw)
            item.kind = "sms"
            try item.insert(dbc)
        }
        try CleanPass(db: db).run()
        let item = try db.writer.read { try Item.fetchOne($0) }
        #expect(item?.cleanText == "the config lives at: /etc/hosts if you need it")
    }

    @Test func keepsTypedByPhrasesInSMS() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let raw = "the print should be\n4 by 6\nstop by later if you want it"
            var item = Item.stub(sourceId: s.id!, externalId: "k", rawText: raw)
            item.kind = "sms"
            try item.insert(dbc)
        }
        try CleanPass(db: db).run()
        let item = try db.writer.read { try Item.fetchOne($0) }
        #expect(item?.cleanText == "the print should be 4 by 6 stop by later if you want it")
    }

    @Test func doesNotStripPathsFromEmail() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imap", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let raw = "see attached\n/Users/janedoe/Documents/report.pdf\nthanks"
            var item = Item.stub(sourceId: s.id!, externalId: "e", rawText: raw)
            item.kind = "email"
            try item.insert(dbc)
        }
        try CleanPass(db: db).run()
        let item = try db.writer.read { try Item.fetchOne($0) }
        #expect(item?.cleanText?.contains("/Users/janedoe/Documents/report.pdf") == true)
    }

    @Test func stripsMarkdownFromMarkdownDocs() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "document", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let raw = "# Title\n\nThis is **bold** and this is *italic* text."
            var item = Item.stub(sourceId: s.id!, externalId: "notes.md", rawText: raw)
            item.kind = "doc"
            try item.insert(dbc)
        }
        try CleanPass(db: db).run()
        let item = try db.writer.read { try Item.fetchOne($0) }
        #expect(item?.cleanText == "Title This is bold and this is italic text.")
        // raw_text is untouched so re-clean can always redo the strip.
        #expect(item?.rawText.contains("# Title") == true)
    }

    @Test func doesNotStripMarkdownFromPlainTextDocs() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "document", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let raw = "# Not a heading\n\nThis is **not markdown** here."
            var item = Item.stub(sourceId: s.id!, externalId: "notes.txt", rawText: raw)
            item.kind = "doc"
            try item.insert(dbc)
        }
        try CleanPass(db: db).run()
        let item = try db.writer.read { try Item.fetchOne($0) }
        #expect(item?.cleanText == "# Not a heading This is **not markdown** here.")
    }

    /// A version-heal re-clean nulls clean_text but preserves lang; CleanPass
    /// must not re-detect language for a row whose lang is already set —
    /// cleaning doesn't change what language an item is written in.
    @Test func recleanPreservesExistingLang() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var item = Item.stub(sourceId: s.id!, externalId: "x",
                                 rawText: "hello there friend how are you doing today")
            item.kind = "sms"
            item.lang = "fr"  // previously detected; clean_text nulled by a heal
            try item.insert(dbc)
        }
        try CleanPass(db: db).run()
        let item = try db.writer.read { try Item.fetchOne($0) }
        #expect(item?.cleanText == "hello there friend how are you doing today")
        #expect(item?.wordCount == 8)
        #expect(item?.lang == "fr")
    }

    @Test func passesRespectCancellation() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var item = Item.stub(sourceId: s.id!, externalId: "x", rawText: "hello there friend")
            try item.insert(dbc)
        }
        try CleanPass(db: db).run(isCancelled: { true })
        let item = try db.writer.read { try Item.fetchOne($0) }
        #expect(item?.cleanText == nil)
    }

    /// The coordinator hands passes a closure that, for cross-Task.detached
    /// cancellation to work, must actually be re-polled on every batch
    /// iteration rather than only once up front. Seed enough rows for
    /// several 500-row batches, flip the closure to "cancelled" after the
    /// first call, and confirm the pass stops instead of draining the queue.
    @Test func midPassCancellationStopsBatchLoop() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            for i in 0..<1200 {
                var item = Item.stub(sourceId: s.id!, externalId: "x\(i)", rawText: "hello there friend")
                try item.insert(dbc)
            }
        }
        final class CallCounter: @unchecked Sendable {
            private var count = 0
            func next() -> Bool {
                defer { count += 1 }
                return count > 0
            }
        }
        let counter = CallCounter()
        try CleanPass(db: db).run(isCancelled: { counter.next() })
        let remainingUncleaned = try db.writer.read { dbc in
            try Item.filter(Column("clean_text") == nil).fetchCount(dbc)
        }
        // First isCancelled() check (false) happens before the first batch is
        // pulled, so exactly one batch (<=500 rows) is processed before the
        // second check (true) stops the loop.
        #expect(remainingUncleaned >= 700)
        #expect(remainingUncleaned < 1200)
    }
}
