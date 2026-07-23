import Testing
import Foundation
import GRDB
@testable import Writekin

struct AdapterPromotionTests {
    private func makeRun(_ db: AppDatabase, baseModel: String, status: String,
                         adapterPath: String?) async throws -> Int64 {
        try await db.writer.write { dbc in
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            var run = TrainingRun(id: nil, datasetId: d.id!, baseModel: baseModel,
                                  configJson: "{}", status: status, adapterPath: adapterPath,
                                  fusedPath: nil, metricsJson: nil, compute: "local")
            try run.insert(dbc)
            return run.id!
        }
    }

    @Test func promoteDemoteRoundTrip() async throws {
        let db = try AppDatabase.inMemory()
        let runID = try await makeRun(db, baseModel: "m", status: "succeeded",
                                      adapterPath: "/tmp/run-1")
        let promotion = AdapterPromotion(db: db)
        #expect(try await promotion.promotedRunID() == nil)
        try await promotion.promote(runID: runID)
        #expect(try await promotion.promotedRunID() == runID)
        try await promotion.demote()
        #expect(try await promotion.promotedRunID() == nil)
    }

    @Test func activeAdapterRequiresMatchingBaseModelAndSuccess() async throws {
        let db = try AppDatabase.inMemory()
        let matching = try await makeRun(db, baseModel: "qwen", status: "succeeded",
                                         adapterPath: "/tmp/run-1")
        let promotion = AdapterPromotion(db: db)
        try await promotion.promote(runID: matching)
        let active = try #require(try await promotion.activeAdapter(forBaseModel: "qwen"))
        #expect(active.runID == matching)
        #expect(active.directory.path == "/tmp/run-1")
        // Different base model: promoted run doesn't apply.
        #expect(try await promotion.activeAdapter(forBaseModel: "other") == nil)
        // Failed run never applies even if promoted.
        let failed = try await makeRun(db, baseModel: "qwen", status: "failed",
                                       adapterPath: nil)
        try await promotion.promote(runID: failed)
        #expect(try await promotion.activeAdapter(forBaseModel: "qwen") == nil)
    }

    @Test func modelRefSuffix() {
        #expect(AdapterPromotion.modelRef(baseModelID: "qwen", runID: 7) == "qwen+run7")
        #expect(AdapterPromotion.modelRef(baseModelID: "qwen", runID: nil) == "qwen")
    }
}
