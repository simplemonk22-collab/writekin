import Testing
import Foundation
import GRDB
@testable import Writekin

/// Phase 3 end-to-end (spec §1): ingest-shaped corpus → PairGenerator →
/// DatasetBuilder → training run lifecycle → regurgitation metrics →
/// promotion → model_ref suffix. No real models, no disk DB, no network.
@MainActor
struct Phase3IntegrationTests {
    @Test func fullPipelineFromKeptItemsToPromotedAdapter() async throws {
        let db = try AppDatabase.inMemory()

        // 1. A small kept corpus across two register cells, with context.
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            for n in 0..<6 {
                var item = Item.stub(sourceId: s.id!, externalId: "sms\(n)",
                                     rawText: "casual message number \(n) with plenty of words in it")
                item.kind = "sms"
                item.state = "kept"
                item.cleanText = item.rawText
                item.wordCount = 10
                item.threadId = "chatA"
                item.medium = "sms"
                item.mode = "casual"
                item.contextText = n == 0 ? "what's happening tonight?" : nil
                try item.insert(dbc)
            }
            for n in 0..<3 {
                let body = Array(repeating: "professional email body word", count: 8)
                    .joined(separator: " ") + " number \(n)"
                var item = Item.stub(sourceId: s.id!, externalId: "em\(n)", rawText: body)
                item.kind = "email"
                item.state = "kept"
                item.cleanText = body
                item.wordCount = 34
                item.medium = "email"
                item.mode = "professional"
                try item.insert(dbc)
            }
        }

        // 2. Pairs + dataset via TrainModel (drives PairGenerator + DatasetBuilder).
        let train = TrainModel()
        train.startPairGeneration(db: db, generatorModelID: "fake-compose",
                                  generatorFactory: { FakeGenerator(script: ["degraded text"]) })
        await train.pairGenTask?.value
        guard case .finished(let summary, let maybeDatasetID) = train.pairGenState,
              let datasetID = maybeDatasetID else {
            Issue.record("pair generation did not finish: \(train.pairGenState)")
            return
        }
        #expect(summary.itemsProcessed == 9)
        let dataset = try #require(try await db.writer.read { try Dataset.fetchOne($0, key: datasetID) })
        let stats = try JSONDecoder().decode(DatasetStats.self, from: Data(dataset.statsJson!.utf8))
        #expect(stats.pairsBySplit.values.reduce(0, +) == 9)

        // 3. Training run with FakeTrainer + regurgitation via FakeGenerator.
        train.startRun(db: db, trainer: FakeTrainer(lossCurve: [3.0, 1.5, 0.8]),
                       datasetID: datasetID, baseModelID: "fake-compose",
                       config: TrainingConfig(), beforeTraining: {},
                       regurgitationGenerator: { _ in
                           FakeGenerator(script: ["completely novel adapted output"])
                       })
        await train.runTask?.value
        let run = try #require(train.runs.first)
        let runID = try #require(run.id)
        #expect(run.status == "succeeded")
        let metrics = try #require(try await TrainingRunStore(db: db).metrics(runID: runID))
        #expect(metrics.finalTrainLoss == 0.8)
        #expect(metrics.regurgitation?.flagged == false)
        #expect(train.lossPoints[runID]?.count == 3)

        // 4. Promotion + model_ref suffix.
        let promotion = AdapterPromotion(db: db)
        try await promotion.promote(runID: runID)
        let active = try #require(try await promotion.activeAdapter(forBaseModel: "fake-compose"))
        #expect(active.runID == runID)
        #expect(AdapterPromotion.modelRef(baseModelID: "fake-compose", runID: active.runID)
                == "fake-compose+run\(runID)")

        // 5. Demote reverts.
        try await promotion.demote()
        #expect(try await promotion.activeAdapter(forBaseModel: "fake-compose") == nil)
    }

    @Test func heldoutIsolationHoldsAcrossThePipeline() async throws {
        // Every pair whose split is heldout must be a completion pair, and no
        // heldout target may ever have appeared in a generation prompt.
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            for n in 0..<60 {
                var item = Item.stub(sourceId: s.id!, externalId: "m\(n)",
                                     rawText: "unique sentinel body \(n) padded with enough words here")
                item.kind = "sms"
                item.state = "kept"
                item.cleanText = item.rawText
                item.wordCount = 9
                item.threadId = "thread-\(n)"   // many groups → some land heldout
                item.medium = "sms"
                try item.insert(dbc)
            }
        }
        let fake = FakeGenerator(script: ["degraded"])
        _ = try await PairGenerator(db: db, generator: fake).run()
        let heldout = try await db.writer.read { dbc in
            try Pair.filter(Column("split") == "heldout").fetchAll(dbc)
        }
        #expect(!heldout.isEmpty)   // 60 groups at ~10% — statistically certain
        #expect(heldout.allSatisfy { $0.pairType == "completion" })
        let promptedText = fake.receivedPrompts
            .flatMap(\.messages).map(\.text).joined(separator: "\n")
        for pair in heldout {
            #expect(!promptedText.contains(pair.targetText))
        }
    }

    /// Task 10 review follow-up: a pre-existing `metrics_json` row written
    /// before the `regurgitation` field existed must still decode via
    /// `TrainingRunStore.metrics(runID:)`, with `regurgitation == nil`
    /// (Codable's default missing-key handling on an Optional).
    @Test func legacyMetricsJSONWithoutRegurgitationFieldStillDecodes() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID = try await db.writer.write { dbc in
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            return d.id!
        }
        let store = TrainingRunStore(db: db)
        let runID = try await store.begin(datasetID: datasetID, baseModel: "m", config: TrainingConfig())

        let legacyJSON = """
            {"finalTrainLoss":0.9,"finalValLoss":1.1,"maskedTokenCount":123,\
            "droppedPairCount":2,"durationSeconds":45.5}
            """
        try await db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE training_runs SET status = 'succeeded', metrics_json = ? WHERE id = ?",
                            arguments: [legacyJSON, runID])
        }

        let metrics = try #require(try await store.metrics(runID: runID))
        #expect(metrics.finalTrainLoss == 0.9)
        #expect(metrics.finalValLoss == 1.1)
        #expect(metrics.maskedTokenCount == 123)
        #expect(metrics.droppedPairCount == 2)
        #expect(metrics.durationSeconds == 45.5)
        #expect(metrics.regurgitation == nil)
        // Loss-curve persistence (added after `regurgitation`) must be just
        // as additive — legacy rows predate it too.
        #expect(metrics.lossCurve == nil)
    }
}
