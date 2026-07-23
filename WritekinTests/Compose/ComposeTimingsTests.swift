import Testing
import Foundation
@testable import Writekin

/// The learned per-model, per-phase rates behind the realize ETA.
struct ComposeTimingsTests {
    @Test func recordsEMAPerPhaseAndModel() async throws {
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)

        // First observation IS the rate.
        await ComposeTimings.record(
            .init(kind: .onePass, units: 100, seconds: 50), modelRef: "m1",
            settings: settings)
        let first = await ComposeTimings.secondsPerUnit(.onePass, modelRef: "m1",
                                                        settings: settings)
        #expect(first == 0.5)

        // Second observation blends by alpha (0.3): 0.5*0.7 + 1.0*0.3 = 0.65.
        await ComposeTimings.record(
            .init(kind: .onePass, units: 10, seconds: 10), modelRef: "m1",
            settings: settings)
        let blended = await ComposeTimings.secondsPerUnit(.onePass, modelRef: "m1",
                                                          settings: settings)
        #expect(abs((blended ?? 0) - 0.65) < 0.0001)

        // Phases and model refs are independent keys.
        let otherPhase = await ComposeTimings.secondsPerUnit(.chunk, modelRef: "m1",
                                                             settings: settings)
        let otherModel = await ComposeTimings.secondsPerUnit(.onePass, modelRef: "m2",
                                                             settings: settings)
        #expect(otherPhase == nil)
        #expect(otherModel == nil)

        // Garbage observations are ignored.
        await ComposeTimings.record(
            .init(kind: .replacement, units: 0, seconds: 5), modelRef: "m1",
            settings: settings)
        let unrecorded = await ComposeTimings.secondsPerUnit(.replacement, modelRef: "m1",
                                                             settings: settings)
        #expect(unrecorded == nil)
    }
}
