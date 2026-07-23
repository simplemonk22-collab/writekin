import Testing
import Foundation
import GRDB
@testable import Writekin

struct ScanSettingsStoreTests {
    private func makeSettings() throws -> SettingsStore {
        SettingsStore(db: try AppDatabase.inMemory())
    }

    @Test func defaultsWhenUnset() async throws {
        let settings = try makeSettings()
        let loaded = await ScanSettingsStore.load(settings: settings)
        #expect(loaded == ScanSettings())
        #expect(loaded.emDashEnabled)
        #expect(loaded.phrasesEnabled)
        #expect(loaded.listFormattingEnabled)
        #expect(loaded.sensitivity == .normal)
    }

    @Test func saveRoundTrips() async throws {
        let settings = try makeSettings()
        var value = ScanSettings()
        value.emDashEnabled = false
        value.sensitivity = .high
        try await ScanSettingsStore.save(value, settings: settings)
        let loaded = await ScanSettingsStore.load(settings: settings)
        #expect(loaded == value)
        #expect(!loaded.emDashEnabled)
        #expect(loaded.sensitivity == .high)
    }

    @Test func corruptValueFallsBackToDefaults() async throws {
        let settings = try makeSettings()
        try await settings.set(ScanSettingsStore.key, "not json")
        let loaded = await ScanSettingsStore.load(settings: settings)
        #expect(loaded == ScanSettings())
    }

    @Test func normalSensitivityMatchesContaminationScanConstants() {
        #expect(ScanSettings.Sensitivity.normal.zThreshold == ContaminationScan.zThreshold)
        #expect(ScanSettings.Sensitivity.normal.sustainedMonths == ContaminationScan.sustainedMonths)
    }

    @Test func hasActiveSignalFalseWhenAllDisabled() {
        var value = ScanSettings()
        value.emDashEnabled = false
        value.phrasesEnabled = false
        value.listFormattingEnabled = false
        #expect(!value.hasActiveSignal)
    }

    @Test func hasActiveSignalTrueWithAnyOneEnabled() {
        var value = ScanSettings()
        value.emDashEnabled = false
        value.phrasesEnabled = false
        #expect(value.hasActiveSignal) // listFormattingEnabled still true
    }

    // MARK: - Advanced fields

    @Test func defaultAdvancedFieldsMatchContaminationScanConstants() {
        let value = ScanSettings()
        #expect(value.baselineEraMonth == ContaminationScan.baselineEraCutoff)
        #expect(value.minItemsPerMonth == ContaminationScan.minItemsPerMonth)
        #expect(value.customZThreshold == nil)
        #expect(value.customStreakMonths == nil)
        #expect(value.customPhrases.isEmpty)
        #expect(!value.isCustomSensitivity)
        #expect(value.effectiveZThreshold == value.sensitivity.zThreshold)
        #expect(value.effectiveStreakMonths == value.sensitivity.sustainedMonths)
    }

    @Test func advancedFieldsRoundTrip() async throws {
        let settings = try makeSettings()
        var value = ScanSettings()
        value.baselineEraMonth = "2023-06"
        value.minItemsPerMonth = 5
        value.customZThreshold = 1.7
        value.customStreakMonths = 4
        value.customPhrases = ["synergize", "circle back"]
        try await ScanSettingsStore.save(value, settings: settings)
        let loaded = await ScanSettingsStore.load(settings: settings)
        #expect(loaded == value)
        #expect(loaded.baselineEraMonth == "2023-06")
        #expect(loaded.minItemsPerMonth == 5)
        #expect(loaded.customZThreshold == 1.7)
        #expect(loaded.customStreakMonths == 4)
        #expect(loaded.customPhrases == ["synergize", "circle back"])
    }

    /// A JSON blob shaped like what `ScanSettingsStore` persisted before the
    /// advanced fields existed -- only the four original keys. Must still
    /// decode, falling back to today's constants for everything new, rather
    /// than failing decode entirely (which would silently reset the user's
    /// signal toggles/sensitivity back to defaults too).
    @Test func legacyJSONWithoutAdvancedFieldsStillDecodes() async throws {
        let settings = try makeSettings()
        let legacyJSON = """
        {"emDashEnabled":false,"phrasesEnabled":true,"listFormattingEnabled":true,"sensitivity":"high"}
        """
        try await settings.set(ScanSettingsStore.key, legacyJSON)
        let loaded = await ScanSettingsStore.load(settings: settings)
        #expect(!loaded.emDashEnabled)
        #expect(loaded.sensitivity == .high)
        #expect(loaded.baselineEraMonth == ContaminationScan.baselineEraCutoff)
        #expect(loaded.minItemsPerMonth == ContaminationScan.minItemsPerMonth)
        #expect(loaded.customZThreshold == nil)
        #expect(loaded.customStreakMonths == nil)
        #expect(loaded.customPhrases.isEmpty)
    }

    @Test func customThresholdOverridesSensitivity() {
        var value = ScanSettings()
        value.sensitivity = .normal
        value.customZThreshold = 0.7
        #expect(value.isCustomSensitivity)
        #expect(value.effectiveZThreshold == 0.7)
        #expect(value.effectiveStreakMonths == value.sensitivity.sustainedMonths)

        value.customStreakMonths = 5
        #expect(value.effectiveStreakMonths == 5)
    }

    // MARK: - disabledBuiltinPhrases

    @Test func defaultDisabledBuiltinPhrasesIsEmpty() {
        #expect(ScanSettings().disabledBuiltinPhrases.isEmpty)
    }

    @Test func disabledBuiltinPhrasesRoundTrips() async throws {
        let settings = try makeSettings()
        var value = ScanSettings()
        value.disabledBuiltinPhrases = ["delve", "tapestry"]
        try await ScanSettingsStore.save(value, settings: settings)
        let loaded = await ScanSettingsStore.load(settings: settings)
        #expect(loaded == value)
        #expect(loaded.disabledBuiltinPhrases == ["delve", "tapestry"])
    }

    /// JSON persisted before per-phrase toggles existed -- no
    /// `disabledBuiltinPhrases` key at all. Must still decode, falling back
    /// to an empty set (nothing disabled), matching today's exact behavior.
    @Test func legacyJSONWithoutDisabledBuiltinPhrasesStillDecodes() async throws {
        let settings = try makeSettings()
        let legacyJSON = """
        {"emDashEnabled":true,"phrasesEnabled":true,"listFormattingEnabled":true,"sensitivity":"normal",\
        "baselineEraMonth":"2022-01","minItemsPerMonth":3,"customPhrases":["circle back"]}
        """
        try await settings.set(ScanSettingsStore.key, legacyJSON)
        let loaded = await ScanSettingsStore.load(settings: settings)
        #expect(loaded.disabledBuiltinPhrases.isEmpty)
        #expect(loaded.customPhrases == ["circle back"])
    }

    // MARK: - isValidEraMonth()

    @Test func isValidEraMonthAcceptsWellFormedMonths() {
        #expect(ScanSettings.isValidEraMonth("2022-01"))
        #expect(ScanSettings.isValidEraMonth("1999-12"))
        #expect(ScanSettings.isValidEraMonth("2026-07"))
    }

    @Test func isValidEraMonthRejectsMalformedInput() {
        #expect(!ScanSettings.isValidEraMonth("2022-13"))     // month out of range
        #expect(!ScanSettings.isValidEraMonth("2022-00"))     // month out of range
        #expect(!ScanSettings.isValidEraMonth("22-01"))       // year too short
        #expect(!ScanSettings.isValidEraMonth("2022-1"))      // month not zero-padded
        #expect(!ScanSettings.isValidEraMonth("2022/01"))     // wrong separator
        #expect(!ScanSettings.isValidEraMonth("2022-01-01"))  // extra component
        #expect(!ScanSettings.isValidEraMonth(""))
        #expect(!ScanSettings.isValidEraMonth("not-a-month"))
    }
}
