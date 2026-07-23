import Foundation
import GRDB

/// Wipes ingested content so the user can start a clean corpus without
/// re-detecting sources or losing their include/exclude preferences.
enum CorpusReset {
    static func run(_ db: AppDatabase) throws {
        try db.writer.write { dbc in
            // `items_fts` is kept in sync with `items` via the triggers set up
            // in the v2 migration (`t.synchronize(withTable: "items")`), so
            // deleting from `items` empties the FTS index too — no separate
            // DELETE needed here.
            try dbc.execute(sql: "DELETE FROM items")
            try dbc.execute(sql: "DELETE FROM accounts")
            try dbc.execute(sql: "UPDATE sources SET last_synced_at = NULL")
            // Mbox fingerprints (see CorpusWriter's "Mbox fingerprints" section)
            // must be cleared here too — otherwise a reset corpus would skip
            // every already-fingerprinted mbox on re-ingest and land nothing.
            try dbc.execute(sql: "DELETE FROM settings WHERE key LIKE 'mbox.fingerprint.%' ESCAPE '\\'")
            // Same reasoning for the iMessage incremental-export mark: a
            // reset corpus must re-export the full history, not just the
            // window since the last (now-deleted) ingest.
            try dbc.execute(sql: "DELETE FROM settings WHERE key = 'imessage.lastIngestedAt'")
            // `config_json` (the per-source enable/disable flags) is
            // deliberately left untouched — a reset clears content, not
            // the user's source preferences.
            //
            // `generations` is NEVER touched by a reset. It backs the
            // self-ingestion guard (§7 in CorpusWriter): every text this app
            // has ever generated is hashed into that table so a later ingest
            // never mistakes the model's own output for the user's voice.
            // Wiping it here would let a reset + re-ingest silently pull
            // generated text back into the corpus.
        }
    }
}
