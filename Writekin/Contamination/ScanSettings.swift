import Foundation

/// User-configurable knobs for `ContaminationScan`: which signals count
/// toward the composite score, and how sensitive `propose()` is to drift.
/// Persisted via `ScanSettingsStore` under the `scan.settings` key -- see
/// `SettingsView`'s "Timeline" tab, the only UI that mutates this.
struct ScanSettings: Codable, Sendable, Equatable {
    var emDashEnabled = true
    var phrasesEnabled = true
    var listFormattingEnabled = true
    var sensitivity: Sensitivity = .normal

    // MARK: - Advanced

    /// First month considered "AI era" for baseline purposes -- editable
    /// mirror of `ContaminationScan.baselineEraCutoff`, threaded through
    /// `ContaminationScan.run`'s `baselineEndIndex`/`baselineIsWeak` calls.
    /// Must be `"YYYY-MM"` -- see `ScanSettings.isValidEraMonth`. The default
    /// reproduces `ContaminationScan.baselineEraCutoff` exactly, so a default
    /// `ScanSettings()` leaves every pre-existing call site unchanged.
    var baselineEraMonth: String = ContaminationScan.baselineEraCutoff

    /// Editable mirror of `ContaminationScan.minItemsPerMonth`: months with
    /// fewer than this many kept items are dropped from the timeline
    /// entirely. Default reproduces the constant exactly.
    var minItemsPerMonth: Int = ContaminationScan.minItemsPerMonth

    /// When set, overrides `sensitivity.zThreshold` -- picking a sensitivity
    /// preset clears this back to `nil`. See `effectiveZThreshold`.
    var customZThreshold: Double?

    /// When set, overrides `sensitivity.sustainedMonths` -- picking a
    /// sensitivity preset clears this back to `nil`. See
    /// `effectiveStreakMonths`.
    var customStreakMonths: Int?

    /// User-added phrases (lowercased, deduped by the UI before appending)
    /// matched alongside `TicLexicon.words` by `ContaminationScan.metrics`.
    /// The built-in lexicon itself stays fixed -- these are additive only.
    var customPhrases: [String] = []

    /// Built-in `TicLexicon.words` entries the user has individually
    /// switched off -- the Timeline settings tab renders one checkbox per
    /// stock phrase, and unchecking one adds it here rather than mutating
    /// the fixed lexicon. `ContaminationScan.metrics` subtracts this set from
    /// `TicLexicon.words` before adding `customPhrases` to build the actual
    /// needle list it searches for. Additive/default-empty like the other
    /// advanced fields, so existing persisted JSON without this key decodes
    /// to "nothing disabled" -- i.e. today's exact behavior.
    var disabledBuiltinPhrases: Set<String> = []

    /// How aggressively `ContaminationScan.propose` flags drift: the
    /// z-score a month's composite must exceed, sustained for
    /// `sustainedMonths` consecutive months, before a cutoff is proposed.
    /// `.normal` reproduces `ContaminationScan.zThreshold`/`sustainedMonths`
    /// exactly, so the default `ScanSettings()` leaves every pre-existing
    /// call site's behavior unchanged.
    enum Sensitivity: String, Codable, Sendable, CaseIterable {
        case low, normal, high

        var zThreshold: Double {
            switch self {
            case .low: return 2.0
            case .normal: return ContaminationScan.zThreshold
            case .high: return 1.0
            }
        }

        var sustainedMonths: Int {
            switch self {
            case .low: return 4
            case .normal: return ContaminationScan.sustainedMonths
            case .high: return 2
            }
        }

        /// Segmented-picker label in the Timeline settings tab. Returns a
        /// localization key (not text) so this model type stays free of the
        /// MainActor-bound `Localization` — the view translates it.
        var labelKey: L10nKey {
            switch self {
            case .low: return .scanSensLow
            case .normal: return .scanSensNormal
            case .high: return .scanSensHigh
            }
        }

        /// One-line caption shown under the picker for whichever level is
        /// currently selected.
        var captionKey: L10nKey {
            switch self {
            case .low: return .scanSensLowCaption
            case .normal: return .scanSensNormalCaption
            case .high: return .scanSensHighCaption
            }
        }
    }

    /// True when at least one signal is enabled -- a composite with none
    /// enabled would be an all-zero score, meaningless input to `propose`.
    /// The Timeline settings tab disables whichever toggle is the last one
    /// active so this can never go false via the UI, but it's exposed so
    /// any other caller can check too.
    var hasActiveSignal: Bool {
        emDashEnabled || phrasesEnabled || listFormattingEnabled
    }

    /// True when either custom override is set -- the settings UI shows a
    /// "Custom" sensitivity state instead of the low/normal/high picker
    /// selection whenever this is true.
    var isCustomSensitivity: Bool {
        customZThreshold != nil || customStreakMonths != nil
    }

    /// The z-score threshold `propose()` actually uses: `customZThreshold`
    /// if set, otherwise `sensitivity.zThreshold`.
    var effectiveZThreshold: Double {
        customZThreshold ?? sensitivity.zThreshold
    }

    /// The sustained-months requirement `propose()` actually uses:
    /// `customStreakMonths` if set, otherwise `sensitivity.sustainedMonths`.
    var effectiveStreakMonths: Int {
        customStreakMonths ?? sensitivity.sustainedMonths
    }

    init() {}

    // MARK: - Codable

    /// Manual `Decodable` so JSON persisted before the advanced fields
    /// existed (`baselineEraMonth`, `minItemsPerMonth`, `customZThreshold`,
    /// `customStreakMonths`, `customPhrases`) still decodes -- a synthesized
    /// `init(from:)` would require every key present regardless of the
    /// properties' default values. `encode(to:)` is left to synthesis, which
    /// works fine here since only the decode side needs the fallback.
    enum CodingKeys: String, CodingKey {
        case emDashEnabled, phrasesEnabled, listFormattingEnabled, sensitivity
        case baselineEraMonth, minItemsPerMonth, customZThreshold, customStreakMonths, customPhrases
        case disabledBuiltinPhrases
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emDashEnabled = try c.decodeIfPresent(Bool.self, forKey: .emDashEnabled) ?? true
        phrasesEnabled = try c.decodeIfPresent(Bool.self, forKey: .phrasesEnabled) ?? true
        listFormattingEnabled = try c.decodeIfPresent(Bool.self, forKey: .listFormattingEnabled) ?? true
        sensitivity = try c.decodeIfPresent(Sensitivity.self, forKey: .sensitivity) ?? .normal
        baselineEraMonth = try c.decodeIfPresent(String.self, forKey: .baselineEraMonth) ?? ContaminationScan.baselineEraCutoff
        minItemsPerMonth = try c.decodeIfPresent(Int.self, forKey: .minItemsPerMonth) ?? ContaminationScan.minItemsPerMonth
        customZThreshold = try c.decodeIfPresent(Double.self, forKey: .customZThreshold)
        customStreakMonths = try c.decodeIfPresent(Int.self, forKey: .customStreakMonths)
        customPhrases = try c.decodeIfPresent([String].self, forKey: .customPhrases) ?? []
        disabledBuiltinPhrases = try c.decodeIfPresent(Set<String>.self, forKey: .disabledBuiltinPhrases) ?? []
    }

    /// Pure `"YYYY-MM"` format check for `baselineEraMonth`'s text field --
    /// 4 digits, "-", then "01"..."12". No `Calendar`/`Date` involved (same
    /// reasoning as `ContaminationScan.isNextMonth`), so it's trivially
    /// testable and can't be thrown off by locale/timezone.
    static func isValidEraMonth(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[0].allSatisfy(\.isNumber),
              let month = Int(parts[1]), parts[1].count == 2, month >= 1, month <= 12
        else { return false }
        return true
    }
}

/// Settings-backed `ScanSettings`, stored as JSON under `scan.settings` --
/// same load/save shape as `DocumentRootsStore`.
enum ScanSettingsStore {
    static let key = "scan.settings"

    /// The configured settings, or `ScanSettings()` defaults when nothing
    /// has been stored (or the stored value can't be decoded).
    static func load(settings: SettingsStore) async -> ScanSettings {
        guard let json = try? await settings.get(key),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ScanSettings.self, from: data)
        else { return ScanSettings() }
        return decoded
    }

    static func save(_ value: ScanSettings, settings: SettingsStore) async throws {
        let data = try JSONEncoder().encode(value)
        try await settings.set(key, String(data: data, encoding: .utf8))
    }
}
