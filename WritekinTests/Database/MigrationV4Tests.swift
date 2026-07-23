import Testing
import Foundation
import GRDB
@testable import Writekin

struct MigrationV4Tests {
    @Test func v4AddsCanonicalHandleColumnToContacts() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.read { dbc in
            let columns = try dbc.columns(in: "contacts").map(\.name)
            #expect(columns.contains("canonical_handle"))
        }
    }

    @Test func v4NormalizesExistingContactHandlesWhitespaceAndCase() async throws {
        // AppDatabase's migrator is private, so a fresh AppDatabase.inMemory()
        // has no pre-v4 legacy rows to normalize (v4 runs immediately, before
        // any rows exist). This instead pins down the exact SQL fragment
        // migration v4 uses for its one-time cleanup pass
        // (`UPDATE contacts SET handle = TRIM(LOWER(handle))`), which is
        // asserted verbatim in AppDatabaseTests / by reading the migration
        // source; see AppDatabase.swift migration "v4".
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            try dbc.execute(sql: "INSERT INTO contacts (handle) VALUES (?)", arguments: [" Rachel Maxwell "])
            try dbc.execute(sql: "UPDATE contacts SET handle = TRIM(LOWER(handle))")
        }
        let handle = try await db.writer.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT handle FROM contacts")
        }
        #expect(handle == "rachel maxwell")
    }
}

/// Exercises `ContactsDedupe.run` (the extracted normalize+dedupe SQL that
/// migration v4 runs) directly against a scratch `contacts` table, since a
/// fresh `AppDatabase.inMemory()` has no pre-migration duplicate rows to
/// seed (the private migrator runs v4 immediately, before any rows exist).
struct ContactsDedupeTests {
    private func makeScratchQueue() async throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try await queue.write { db in
            try db.create(table: "contacts") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("handle", .text).notNull()
                t.column("display_name", .text)
                t.column("audience_id", .integer)
                t.column("canonical_handle", .text)
            }
        }
        return queue
    }

    @Test func dedupePrefersRowWithNonNullAudienceIDAndDropsTheOther() async throws {
        let queue = try await makeScratchQueue()
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO contacts (handle, audience_id) VALUES (?, ?)",
                            arguments: ["Alice@X.com", 7])
            try db.execute(sql: "INSERT INTO contacts (handle, audience_id) VALUES (?, ?)",
                            arguments: ["alice@x.com ", nil])
        }

        try await queue.write { db in try ContactsDedupe.run(db) }

        let rows = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT handle, audience_id FROM contacts")
        }
        #expect(rows.count == 1)
        #expect(rows[0]["handle"] as String == "alice@x.com")
        #expect(rows[0]["audience_id"] as Int64? == 7)
    }

    @Test func dedupeBreaksTiesByLowestIDWhenNeitherHasAnAudience() async throws {
        let queue = try await makeScratchQueue()
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO contacts (handle) VALUES (?)", arguments: ["Bob@Y.com"])
            try db.execute(sql: "INSERT INTO contacts (handle) VALUES (?)", arguments: ["bob@y.com"])
        }

        try await queue.write { db in try ContactsDedupe.run(db) }

        let rows = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, handle FROM contacts")
        }
        #expect(rows.count == 1)
        #expect(rows[0]["id"] as Int64 == 1) // lowest id survives
        #expect(rows[0]["handle"] as String == "bob@y.com")
    }

    @Test func dedupeCarriesOverNonNullCanonicalHandleFromDiscardedRow() async throws {
        let queue = try await makeScratchQueue()
        try await queue.write { db in
            // Winner (has audience_id) has no canonical_handle of its own.
            try db.execute(sql: "INSERT INTO contacts (handle, audience_id, canonical_handle) VALUES (?, ?, ?)",
                            arguments: ["Carol@Z.com", 3, nil])
            // Loser carries a canonical_handle that should be preserved.
            try db.execute(sql: "INSERT INTO contacts (handle, audience_id, canonical_handle) VALUES (?, ?, ?)",
                            arguments: ["carol@z.com ", nil, "someone@else.com"])
        }

        try await queue.write { db in try ContactsDedupe.run(db) }

        let row = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT audience_id, canonical_handle FROM contacts")
        }
        #expect(row?["audience_id"] as Int64? == 3)
        #expect(row?["canonical_handle"] as String? == "someone@else.com")
    }

    @Test func dedupeLeavesUnrelatedHandlesUntouched() async throws {
        let queue = try await makeScratchQueue()
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO contacts (handle) VALUES (?)", arguments: ["dana@example.com"])
            try db.execute(sql: "INSERT INTO contacts (handle) VALUES (?)", arguments: ["erin@example.com"])
        }

        try await queue.write { db in try ContactsDedupe.run(db) }

        let handles = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT handle FROM contacts ORDER BY handle")
        }
        #expect(handles == ["dana@example.com", "erin@example.com"])
    }

    @Test func dedupeCreatesUniqueIndexRejectingFutureDuplicateInserts() async throws {
        let queue = try await makeScratchQueue()
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO contacts (handle) VALUES (?)", arguments: ["frank@example.com"])
        }

        try await queue.write { db in try ContactsDedupe.run(db) }

        var threw = false
        do {
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO contacts (handle) VALUES (?)", arguments: ["frank@example.com"])
            }
        } catch {
            threw = true
        }
        #expect(threw)
    }
}
