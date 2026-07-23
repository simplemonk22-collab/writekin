import Foundation
import GRDB

struct AppDatabase: Sendable {
    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    static func onDisk() throws -> AppDatabase {
        let dir = AppIdentity.storageRoot
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent(AppIdentity.databaseFileName).path)
        return try AppDatabase(pool)
    }

    static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "sources") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull().unique()
                t.column("config_json", .text).notNull().defaults(to: "{}")
                t.column("last_synced_at", .datetime)
            }
            try db.create(table: "accounts") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("address_or_handle", .text).notNull()
                t.column("aliases_json", .text).notNull().defaults(to: "[]")
                t.column("persona", .text)
                t.column("era_note", .text)
            }
            try db.create(table: "audiences") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
            }
            try db.create(table: "contacts") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("handle", .text).notNull()
                t.column("display_name", .text)
                t.column("audience_id", .integer).references("audiences")
            }
            try db.create(table: "items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source_id", .integer).notNull().references("sources")
                t.column("account_id", .integer).references("accounts")
                t.column("external_id", .text)
                t.column("kind", .text).notNull()          // sms|email|doc|chat
                t.column("authored_at", .datetime)
                t.column("recipients_json", .text).notNull().defaults(to: "[]")
                t.column("thread_id", .text)
                t.column("raw_text", .text).notNull()
                t.column("clean_text", .text)
                t.column("word_count", .integer)
                t.column("lang", .text)
                t.column("sha256", .text).notNull()
                t.column("simhash64", .integer)
                t.column("provenance", .text).notNull()    // native|cache_besteffort|archive_import
                t.column("state", .text).notNull()         // ingested|filtered_out|kept|dropped
                t.column("drop_reason", .text)
                t.column("medium", .text)
                t.column("audience", .text)
                t.column("mode", .text)
                t.column("label_source", .text)
                t.column("quality_score", .double)
            }
            try db.create(indexOn: "items", columns: ["sha256"])
            try db.create(indexOn: "items", columns: ["simhash64"])
            try db.create(indexOn: "items", columns: ["source_id"])
            try db.create(table: "pairs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("item_id", .integer).notNull().references("items")
                t.column("pair_type", .text).notNull()     // degradation|backtranslation|completion
                t.column("system_tags", .text).notNull()
                t.column("input_text", .text).notNull()
                t.column("target_text", .text).notNull()
                t.column("split", .text).notNull()         // train|heldout
            }
            try db.create(table: "datasets") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("filter_json", .text).notNull()
                t.column("stats_json", .text)
                t.column("exported_at", .datetime)
            }
            try db.create(table: "training_runs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("dataset_id", .integer).notNull().references("datasets")
                t.column("base_model", .text).notNull()
                t.column("config_json", .text).notNull()
                t.column("status", .text).notNull()
                t.column("adapter_path", .text)
                t.column("fused_path", .text)
                t.column("metrics_json", .text)
                t.column("compute", .text).notNull().defaults(to: "local")  // local|cloud
            }
            try db.create(table: "evals") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("training_run_id", .integer).notNull().references("training_runs")
                t.column("register", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("results_json", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
            try db.create(table: "turing_trials") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("eval_id", .integer).notNull().references("evals")
                t.column("item_text", .text).notNull()
                t.column("is_generated", .boolean).notNull()
                t.column("user_guess", .boolean)
                t.column("guessed_at", .datetime)
            }
            try db.create(table: "generations") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("created_at", .datetime).notNull()
                t.column("sha256", .text).notNull()
                t.column("simhash64", .integer)
                t.column("register", .text)
                t.column("model_ref", .text)
            }
            try db.create(indexOn: "generations", columns: ["sha256"])
        }
        m.registerMigration("v2") { db in
            try db.alter(table: "items") { t in
                t.add(column: "date_confidence", .text)
            }
            try db.alter(table: "accounts") { t in
                t.add(column: "addresses_json", .text).notNull().defaults(to: "[]")
            }
            try db.create(indexOn: "items", columns: ["source_id", "external_id"],
                          options: .unique)
            try db.create(virtualTable: "items_fts", using: FTS5()) { t in
                t.synchronize(withTable: "items")
                t.column("clean_text")
            }
        }
        m.registerMigration("v3") { db in
            try db.create(table: "settings") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.create(table: "models") { t in
                t.primaryKey("id", .text)
                t.column("repo", .text).notNull()
                t.column("path", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("installed_at", .datetime).notNull()
                t.column("source", .text).notNull()
            }
            try db.create(indexOn: "items", columns: ["mode"])
            try db.create(indexOn: "items", columns: ["account_id"])
            for name in ["family", "friend", "self", "work", "investor", "cold"] {
                try db.execute(sql: "INSERT OR IGNORE INTO audiences (name) VALUES (?)",
                               arguments: [name])
            }
        }
        m.registerMigration("v4") { db in
            try db.alter(table: "contacts") { t in
                t.add(column: "canonical_handle", .text)
            }
            // One-time cleanup for existing DBs: collapse whitespace/case
            // dupes in stale contact rows (" me" vs "me"). Gmail-specific
            // normalization (dots, googlemail.com) is handled read-side by
            // HandleNormalizer, not here, since that's Swift logic.
            //
            // Normalizing can itself create collisions (two rows that
            // differ only by case/whitespace), so this also dedupes down to
            // one row per normalized handle before locking that invariant in
            // with a UNIQUE index.
            try ContactsDedupe.run(db)
        }
        m.registerMigration("v5") { db in
            // Phase 3: reply-conditioning context (spec §2) + dataset linkage (spec §4).
            try db.alter(table: "items") { t in
                t.add(column: "context_text", .text)
            }
            try db.alter(table: "pairs") { t in
                t.add(column: "dataset_id", .integer).references("datasets")
            }
            try db.create(indexOn: "pairs", columns: ["dataset_id"])
        }
        m.registerMigration("v6") { db in
            // Free-text notes on a training run (Train screen), e.g. "config
            // X, seemed to overfit" — purely descriptive, never read by any
            // training/promotion logic.
            try db.alter(table: "training_runs") { t in
                t.add(column: "notes", .text)
            }
        }
        m.registerMigration("v7") { db in
            // Provenance of `items.audience` (AudienceAdmin.backfill):
            // "people" = majority vote of hand-assigned recipients;
            // "account" = inferred from the sending account's persona;
            // "one_off" = inferred because every recipient is a one-off
            // correspondent. NULL whenever `audience` is NULL. Lets the UI
            // mark inferred labels so they aren't mistaken for hand labels.
            try db.alter(table: "items") { t in
                t.add(column: "audience_source", .text)
            }
        }
        m.registerMigration("v8") { db in
            // Corrections loop: pairs may now originate from a Compose
            // session ("Save as my version") instead of a corpus item, so
            // `item_id` becomes nullable. SQLite can't relax NOT NULL in
            // place — standard rebuild-and-rename, preserving all rows.
            try db.execute(sql: """
                CREATE TABLE "pairs_new" (
                    "id" INTEGER PRIMARY KEY AUTOINCREMENT,
                    "item_id" INTEGER REFERENCES "items"("id"),
                    "pair_type" TEXT NOT NULL,
                    "system_tags" TEXT NOT NULL,
                    "input_text" TEXT NOT NULL,
                    "target_text" TEXT NOT NULL,
                    "split" TEXT NOT NULL,
                    "dataset_id" INTEGER REFERENCES "datasets"("id")
                )
                """)
            try db.execute(sql: """
                INSERT INTO pairs_new (id, item_id, pair_type, system_tags,
                                       input_text, target_text, split, dataset_id)
                SELECT id, item_id, pair_type, system_tags,
                       input_text, target_text, split, dataset_id FROM pairs
                """)
            try db.execute(sql: "DROP TABLE pairs")
            try db.execute(sql: "ALTER TABLE pairs_new RENAME TO pairs")
            try db.create(indexOn: "pairs", columns: ["dataset_id"])
        }
        m.registerMigration("v9") { db in
            // The v1 FTS update trigger fired on ANY items UPDATE — every
            // filter-pass state flip, audience backfill, and mode label
            // rewrote that row's FTS entry even though only `clean_text`
            // feeds the index. Rebuild it to fire only when `clean_text`
            // actually changes; body is identical.
            try db.execute(sql: "DROP TRIGGER \"__items_fts_au\"")
            try db.execute(sql: """
                CREATE TRIGGER "__items_fts_au" AFTER UPDATE OF "clean_text" ON "items" BEGIN
                    INSERT INTO "items_fts"("items_fts", "rowid", "clean_text") VALUES('delete', old."id", old."clean_text");
                    INSERT INTO "items_fts"("rowid", "clean_text") VALUES (new."id", new."clean_text");
                END
                """)
        }
        m.registerMigration("v10") { db in
            try DuplicateFilteredCleanup.run(db)
        }
        m.registerMigration("v11") { db in
            // Dataset names were "Dataset (count+1)" at creation, which
            // drifts off the row ids once any dataset is deleted — a real
            // DB held two "Dataset 4"s while run cards (which print the
            // dataset ID) referenced a "Dataset 6" the list never showed.
            // Re-key default-pattern names to the id; custom names survive.
            try db.execute(sql: """
                UPDATE datasets SET name = 'Dataset ' || id
                WHERE name GLOB 'Dataset [0-9]*'
                """)
        }
        return m
    }
}

/// One-time cleanup for duplicate filtered-out rows, extracted from the v10
/// migration so tests can seed pre-migration duplicates directly (see
/// `ContactsDedupe` for the pattern). Before the write-side dedupe counted
/// dropped rows, every ingest whose external ids didn't line up re-inserted
/// each pass-filtered message as a brand-new row and filtered it again —
/// tens of copies per message in a real corpus. Keeps the oldest row per
/// (source, content); never touches kept/ingested rows, rows referenced by
/// pairs, or empty-raw partials (whose shared hash isn't an identity).
enum DuplicateFilteredCleanup {
    static func run(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM items
            WHERE state = 'filtered_out'
              AND raw_text != ''
              AND id NOT IN (SELECT MIN(id) FROM items WHERE raw_text != ''
                             GROUP BY source_id, sha256)
              AND id NOT IN (SELECT item_id FROM pairs WHERE item_id IS NOT NULL)
            """)
    }
}

/// One-time SQL cleanup for the `contacts` table, extracted out of the v4
/// migration so it can be exercised directly by tests: `AppDatabase.inMemory()`
/// runs every migration immediately on a fresh DB, so there's no way to seed
/// pre-migration duplicate rows through the (private) migrator itself. Tests
/// instead build a bare scratch `contacts` table, seed duplicates, and run
/// this function directly.
enum ContactsDedupe {
    /// Normalizes every `handle` to `TRIM(LOWER(...))`, then collapses any
    /// resulting collisions down to a single row per normalized handle:
    /// preferring a row with a non-null `audience_id`, else the row with the
    /// lowest `id`. The surviving row picks up a non-null `canonical_handle`
    /// from a discarded row if it didn't already have one of its own.
    /// Finally creates a UNIQUE index on `contacts(handle)` so future
    /// duplicates are impossible at the database layer.
    ///
    /// Assumes a `contacts` table with `id`, `handle`, `audience_id`, and
    /// `canonical_handle` columns.
    static func run(_ db: Database) throws {
        // 1. Normalize whitespace/case.
        try db.execute(sql: "UPDATE contacts SET handle = TRIM(LOWER(handle))")

        // 2. Pick one winner per normalized handle: non-null audience_id
        // preferred, else lowest id.
        try db.execute(sql: """
            CREATE TEMP TABLE _contacts_dedupe_winners AS
            SELECT handle, id AS winner_id FROM (
                SELECT handle, id,
                       ROW_NUMBER() OVER (
                           PARTITION BY handle
                           ORDER BY (audience_id IS NOT NULL) DESC, id ASC
                       ) AS rn
                FROM contacts
            )
            WHERE rn = 1
            """)

        // 3. Carry over a non-null canonical_handle from a discarded row if
        // the winner doesn't already have one of its own.
        try db.execute(sql: """
            UPDATE contacts
            SET canonical_handle = (
                SELECT c2.canonical_handle
                FROM contacts c2
                WHERE c2.handle = contacts.handle
                  AND c2.canonical_handle IS NOT NULL
                ORDER BY c2.id ASC
                LIMIT 1
            )
            WHERE canonical_handle IS NULL
              AND id IN (SELECT winner_id FROM _contacts_dedupe_winners)
              AND EXISTS (
                  SELECT 1 FROM contacts c2
                  WHERE c2.handle = contacts.handle AND c2.canonical_handle IS NOT NULL
              )
            """)

        // 4. Delete every row that isn't the winner for its normalized handle.
        try db.execute(sql: """
            DELETE FROM contacts
            WHERE id NOT IN (SELECT winner_id FROM _contacts_dedupe_winners)
            """)

        try db.execute(sql: "DROP TABLE _contacts_dedupe_winners")

        // 5. Enforce uniqueness going forward.
        try db.create(indexOn: "contacts", columns: ["handle"], options: .unique)
    }
}
