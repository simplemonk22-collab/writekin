import Testing
import Foundation
import GRDB
@testable import Writekin

struct DatasetBuilderTests {
    private func seedPendingPairs(_ db: AppDatabase, sourceKind: String = "imessage") async throws {
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: sourceKind, configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var item = Item.stub(sourceId: s.id!, externalId: "a", rawText: "four words right here")
            try item.insert(dbc)
            for (type, split, tags, target) in [
                ("completion", "train", "[medium: sms]", "one two three"),
                ("degradation", "train", "[medium: sms]", "four five"),
                ("completion", "heldout", "", "six"),
            ] {
                var p = Pair(id: nil, itemId: item.id!, pairType: type, systemTags: tags,
                             inputText: "", targetText: target, split: split, datasetId: nil)
                try p.insert(dbc)
            }
        }
    }

    @Test func snapshotClaimsPendingPairsAndWritesStats() async throws {
        let db = try AppDatabase.inMemory()
        try await seedPendingPairs(db)
        let filter = DatasetFilter(itemCap: 1_000, generatorModelID: "qwen2.5-7b")
        let id = try await DatasetBuilder(db: db).snapshot(name: "first", filter: filter)

        let dataset = try #require(try await db.writer.read { try Dataset.fetchOne($0, key: id) })
        #expect(dataset.name == "first")
        #expect(dataset.exportedAt != nil)
        let decodedFilter = try JSONDecoder().decode(
            DatasetFilter.self, from: Data(dataset.filterJson.utf8))
        #expect(decodedFilter == filter)
        let stats = try JSONDecoder().decode(
            DatasetStats.self, from: Data(dataset.statsJson!.utf8))
        #expect(stats.pairsByType == ["completion": 2, "degradation": 1])
        #expect(stats.pairsBySplit == ["train": 2, "heldout": 1])
        #expect(stats.pairsByCell == ["[medium: sms]": 2, "": 1])
        #expect(stats.totalTargetWords == 6)

        let unclaimed = try await db.writer.read {
            try Pair.filter(Column("dataset_id") == nil).fetchCount($0)
        }
        #expect(unclaimed == 0)
        let claimed = try await db.writer.read {
            try Pair.filter(Column("dataset_id") == id).fetchCount($0)
        }
        #expect(claimed == 3)
    }

    @Test func snapshotIsImmutableAcrossRegenerations() async throws {
        let db = try AppDatabase.inMemory()
        try await seedPendingPairs(db, sourceKind: "imessage")
        let filter = DatasetFilter(itemCap: 1_000, generatorModelID: "m")
        let first = try await DatasetBuilder(db: db).snapshot(name: "one", filter: filter)
        try await seedPendingPairs(db, sourceKind: "email")   // "regenerate" pairs
        let second = try await DatasetBuilder(db: db).snapshot(name: "two", filter: filter)
        #expect(first != second)
        let firstCount = try await db.writer.read {
            try Pair.filter(Column("dataset_id") == first).fetchCount($0)
        }
        #expect(firstCount == 3)   // old rows untouched
    }

    @Test func snapshotWithNothingPendingThrows() async throws {
        let db = try AppDatabase.inMemory()
        await #expect(throws: DatasetError.noPendingPairs) {
            _ = try await DatasetBuilder(db: db)
                .snapshot(name: "empty", filter: DatasetFilter(itemCap: 1, generatorModelID: "m"))
        }
    }

    // MARK: - DatasetSummary

    /// Pins the shared language to English (restored after) for tests that
    /// assert English strings — same pattern as `CorpusStatsTests`.
    @MainActor
    private func withEnglish(_ body: () throws -> Void) rethrows {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        try body()
    }

    @MainActor @Test func summaryLineIncludesPairCountsSplitAndDate() throws {
        try withEnglish {
            let stats = DatasetStats(pairsByType: ["completion": 2, "degradation": 1],
                                     pairsBySplit: ["train": 2, "heldout": 1],
                                     pairsByCell: [:], totalTargetWords: 6)
            let statsJson = String(data: try JSONEncoder().encode(stats), encoding: .utf8)
            var components = DateComponents()
            components.year = 2026; components.month = 7; components.day = 20
            let date = Calendar(identifier: .gregorian).date(from: components)!

            let line = DatasetSummary.line(name: "Dataset 3", statsJson: statsJson, exportedAt: date)

            #expect(line.hasPrefix("Dataset 3 — 3 pairs (2 train / 1 heldout)"))
            #expect(line.hasSuffix("Jul 20"))
        }
    }

    @MainActor @Test func summaryLineFallsBackGracefullyWithoutStats() throws {
        let line = DatasetSummary.line(name: "Dataset 1", statsJson: nil, exportedAt: nil)
        #expect(line == "Dataset 1")
    }

    @MainActor @Test func summaryLineToleratesUndecodableStatsJSON() throws {
        let line = DatasetSummary.line(name: "Dataset 2", statsJson: "not json",
                                       exportedAt: nil)
        #expect(line == "Dataset 2")
    }

    @Test func decodeStatsRoundTripsAndToleratesGarbage() throws {
        let stats = DatasetStats(pairsByType: ["completion": 1], pairsBySplit: ["train": 1],
                                 pairsByCell: [:], totalTargetWords: 1)
        let json = String(data: try JSONEncoder().encode(stats), encoding: .utf8)
        #expect(DatasetSummary.decodeStats(json) == stats)
        #expect(DatasetSummary.decodeStats("garbage") == nil)
        #expect(DatasetSummary.decodeStats(nil) == nil)
    }
}
