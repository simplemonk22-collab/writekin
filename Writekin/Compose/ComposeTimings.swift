import Foundation

/// Learned per-model, per-phase durations backing the realize ETA.
///
/// A realize is a PIPELINE — main generation (one-pass or per-chunk),
/// possible guard retries, word-surgery replacement calls, and the base
/// A/B pass — and each phase has a very different cost shape (a chunk
/// re-prefills the full draft for ~50 output words; a replacement call is
/// a tiny prompt with a ~1-word answer). So rates are learned separately
/// per phase AND per model ref (base vs. base+adapter differ, and refs are
/// machine-local, so this is effectively per-machine too), as EMAs
/// persisted in settings. Word-denominated phases store seconds-per-output-
/// word — which silently absorbs each phase's typical prefill overhead
/// without modeling prefill explicitly, because a phase's prompt shape is
/// consistent per user.
enum ComposeTimings {
    enum PhaseKind: String, Sendable {
        /// Whole-draft generation (also used for guard retries — same
        /// workload). Denominated in output words.
        case onePass
        /// One chunk of a sectioned rewrite. Denominated in output words.
        case chunk
        /// One avoid-word replacement call. Denominated per call.
        case replacement
    }

    /// One measured phase execution, reported by `ComposeEngine` via
    /// `onTiming` as it happens.
    struct PhaseTiming: Sendable, Equatable {
        var kind: PhaseKind
        /// Output words for word-denominated phases; 1 for `.replacement`.
        var units: Int
        var seconds: Double
    }

    /// EMA weight for new observations — heavy enough to adapt when a
    /// machine's load changes, light enough that one thermally-throttled
    /// run doesn't wreck the estimate.
    static let alpha = 0.3

    private static func key(_ kind: PhaseKind, modelRef: String) -> String {
        "compose.rate.\(kind.rawValue).\(modelRef)"
    }

    /// Learned seconds per unit (word or call) for this phase+model, or
    /// nil before the first observation — the UI shows no countdown until
    /// a rate exists rather than guessing.
    static func secondsPerUnit(_ kind: PhaseKind, modelRef: String,
                               settings: SettingsStore) async -> Double? {
        guard let stored = try? await settings.get(key(kind, modelRef: modelRef)),
              let value = Double(stored ?? ""), value > 0 else { return nil }
        return value
    }

    static func record(_ timing: PhaseTiming, modelRef: String,
                       settings: SettingsStore) async {
        guard timing.units > 0, timing.seconds > 0 else { return }
        let observed = timing.seconds / Double(timing.units)
        let previous = await secondsPerUnit(timing.kind, modelRef: modelRef,
                                            settings: settings)
        let updated = previous.map { $0 * (1 - alpha) + observed * alpha } ?? observed
        try? await settings.set(key(timing.kind, modelRef: modelRef), String(updated))
    }
}
