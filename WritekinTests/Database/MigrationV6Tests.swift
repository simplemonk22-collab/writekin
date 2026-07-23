import Testing
import Foundation
import GRDB
@testable import Writekin

struct MigrationV6Tests {
    private func makeDataset(_ dbc: Database) throws -> Int64 {
        var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
        try d.insert(dbc)
        return d.id!
    }

    @Test func trainingRunsHaveNullableNotes() async throws {
        let db = try AppDatabase.inMemory()
        let runID: Int64 = try await db.writer.write { dbc in
            let datasetID = try makeDataset(dbc)
            var run = TrainingRun(id: nil, datasetId: datasetID, baseModel: "m",
                                  configJson: "{}", status: "running", adapterPath: nil,
                                  fusedPath: nil, metricsJson: nil, compute: "local",
                                  notes: "trained on the big dataset")
            try run.insert(dbc)
            return run.id!
        }
        let run = try await db.writer.read { try TrainingRun.fetchOne($0, key: runID) }
        #expect(run?.notes == "trained on the big dataset")
    }

    @Test func notesDefaultsToNil() async throws {
        let db = try AppDatabase.inMemory()
        let runID: Int64 = try await db.writer.write { dbc in
            let datasetID = try makeDataset(dbc)
            var run = TrainingRun(id: nil, datasetId: datasetID, baseModel: "m",
                                  configJson: "{}", status: "running", adapterPath: nil,
                                  fusedPath: nil, metricsJson: nil, compute: "local")
            try run.insert(dbc)
            return run.id!
        }
        let run = try await db.writer.read { try TrainingRun.fetchOne($0, key: runID) }
        #expect(run?.notes == nil)
    }
}
