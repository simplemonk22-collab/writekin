import Foundation
import GRDB

/// Snapshot of onboarding-pipeline progress, loaded asynchronously by
/// `OverviewView` (via `PipelineState.load`) and fed into
/// `NextStep.compute`. Each field documents the cheapest honest signal used
/// for it.
struct PipelineState: Equatable, Sendable {
    /// Any installed model with `kind == "compose"` — the one Compose (and
    /// so the whole pipeline) actually needs to produce anything.
    var modelInstalled = false
    var keptItems = 0
    /// Items with `state == "ingested"` — landed in the DB but never reached
    /// `FilterPass`, so they're neither kept nor dropped yet. Non-zero means
    /// a previous ingest was interrupted before it finished processing.
    var unprocessedItems = 0
    /// Distinct `contacts` rows with a non-null `audience_id`.
    var audiencesAssignedCount = 0
    /// True once the timeline has genuinely been reviewed: either at least
    /// one `cutoff.applied.<medium>` settings key exists (written only by
    /// `CutoffStore.markApplied`/`applyAllPending`, which `IngestCoordinator`
    /// calls after a real reapply/ingest pass actually ran — never just by
    /// opening Timeline), OR at least one `cutoff.reviewed.<medium>` key
    /// exists (written by `CutoffStore.set`/`markNoCutoffNeeded`/
    /// `dismissProposal` — any explicit per-medium decision, including
    /// deliberately deciding no cutoff is needed). The `reviewed` markers
    /// close the false-negative gap the old `cutoff.applied`-only signal
    /// had: a user who opens Timeline and decides no cutoff is needed
    /// anywhere used to keep seeing this step forever, since they'd never
    /// run a reapply pass. This is still the cheapest honest signal
    /// available — Timeline keeps no "last viewed" record.
    var timelineReviewed = false
    /// `COUNT(*) FROM pairs` — pending (`dataset_id IS NULL`) or already
    /// claimed into a dataset. Loaded for the pipeline snapshot per spec;
    /// `compute` itself keys the pairs/train step off `succeededRuns`
    /// instead, since a pile of generated-but-untrained pairs and zero
    /// pairs both mean the same next action ("finish training").
    var pendingOrClaimedPairs = 0
    var succeededRuns = 0
    /// Succeeded runs whose base model IS the installed compose model —
    /// the only runs whose adapters can actually apply. Diverges from
    /// `succeededRuns` after a base-model swap.
    var succeededRunsOnInstalledModel = 0
    /// Whether the promoted adapter currently APPLIES to the installed
    /// compose model (`AdapterPromotion.activeAdapter` non-nil). A stale
    /// promotion — run trained on a since-removed base — is false: the
    /// whole point of the app is the trained voice, so "promoted but
    /// inert" must not read as "done."
    var promotedRunUsable = false

    // NOTE on staleness (`newItemsSinceLastRun`): the spec asked for kept
    // items ingested after the last succeeded run, approximated via the
    // run's dataset stats total when decodable. `DatasetStats`
    // (Training/DatasetBuilder.swift) only records pair counts by
    // type/split/cell and a target-word total — no kept-item total to
    // compare `keptItems` against. There is nothing decodable to diff, so
    // staleness detection is omitted this round; `NextStep` has no case for
    // it. Revisit by adding a kept-item-count field to `DatasetStats` (or a
    // dedicated watermark) if this becomes worth surfacing.
}

extension PipelineState {
    /// Assembles the snapshot `NextStep.compute` consumes: a handful of
    /// direct counts (nothing here has an existing store worth wrapping)
    /// plus the existing `SettingsStore`/`AdapterPromotion` stores for the
    /// two fields they already own. Lived inline in `OverviewView` until
    /// the structure cleanup — the one view that wrote raw SQL.
    static func load(db: AppDatabase, settings: SettingsStore) async -> PipelineState {
        let counts = try? await db.writer.read { dbc -> (kept: Int, unprocessed: Int, audiences: Int,
                                                          pairs: Int, succeeded: Int,
                                                          succeededOnInstalled: Int,
                                                          installedComposeID: String?) in
            let installedComposeID = try InstalledModel
                .filter(Column("kind") == "compose").fetchOne(dbc)?.id
            let kept = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM items WHERE state = 'kept'") ?? 0
            let unprocessed = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM items WHERE state = 'ingested'") ?? 0
            let audiences = try Int.fetchOne(dbc,
                sql: "SELECT COUNT(*) FROM contacts WHERE audience_id IS NOT NULL") ?? 0
            let pairs = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pairs") ?? 0
            let succeeded = try Int.fetchOne(dbc,
                sql: "SELECT COUNT(*) FROM training_runs WHERE status = 'succeeded'") ?? 0
            let succeededOnInstalled = try Int.fetchOne(dbc,
                sql: "SELECT COUNT(*) FROM training_runs WHERE status = 'succeeded' AND base_model = ?",
                arguments: [installedComposeID ?? ""]) ?? 0
            return (kept, unprocessed, audiences, pairs, succeeded, succeededOnInstalled, installedComposeID)
        }
        // Reviewed = a real cutoff was ever applied to the corpus, OR any
        // medium got an explicit per-medium decision recorded (set/cleared
        // a cutoff, "no cutoff needed", or dismissed a proposal — see
        // `CutoffStore.set`/`markNoCutoffNeeded`/`dismissProposal`).
        let cutoffApplied = (try? await settings.keys(withPrefix: "cutoff.applied.").isEmpty == false) ?? false
        let cutoffReviewed = (try? await settings.keys(withPrefix: "cutoff.reviewed.").isEmpty == false) ?? false
        // Usable = the promoted adapter actually applies to the installed
        // compose model (activeAdapter enforces base-model match). A stale
        // promotion after a base swap counts as NOT done.
        let promotedUsable: Bool
        if let installedID = counts?.installedComposeID {
            promotedUsable = ((try? await AdapterPromotion(db: db)
                .activeAdapter(forBaseModel: installedID)) ?? nil) != nil
        } else {
            promotedUsable = false
        }

        var state = PipelineState()
        state.modelInstalled = counts?.installedComposeID != nil
        state.keptItems = counts?.kept ?? 0
        state.unprocessedItems = counts?.unprocessed ?? 0
        state.audiencesAssignedCount = counts?.audiences ?? 0
        state.timelineReviewed = cutoffApplied || cutoffReviewed
        state.pendingOrClaimedPairs = counts?.pairs ?? 0
        state.succeededRuns = counts?.succeeded ?? 0
        state.succeededRunsOnInstalledModel = counts?.succeededOnInstalled ?? 0
        state.promotedRunUsable = promotedUsable
        return state
    }
}

/// First unmet step in the onboarding pipeline, surfaced as a card at the
/// top of Overview. `compute` is a pure, synchronous function of
/// `PipelineState` so it's fully unit-testable without touching the
/// database — see `NextStepTests`.
enum NextStep: Equatable {
    /// No `kind == "compose"` model installed yet.
    case installModel
    /// Nothing kept yet, or a previous pass left items unprocessed.
    /// `hasStarted` distinguishes "run your first ingest" from "finish
    /// processing what's already in" for the card's copy.
    case ingest(hasStarted: Bool)
    /// No recipient has been assigned to an audience bucket yet.
    case assignAudiences
    /// The AI-contamination cutoff has never been reviewed/applied.
    case reviewTimeline
    /// No training pairs exist yet (and no run has ever succeeded) — the
    /// step BEFORE training, split out so the guide teaches the real order:
    /// generate pairs, then run, then promote.
    case generatePairs
    /// Pairs exist but training hasn't produced a succeeded run yet.
    case trainModel
    /// Runs succeeded, but none on the currently installed compose model —
    /// the trained voice can't apply until a run exists on the new base.
    case retrainForNewModel
    /// A run on the installed model succeeded, but none is promoted (or the
    /// promotion points at a run whose base is gone) — Compose isn't using
    /// the trained voice.
    case promote

    /// Card copy is `@MainActor`: it renders localized text (the step
    /// itself, and `compute`, stay nonisolated pure logic).
    @MainActor var title: String {
        let loc = Localization.shared
        return switch self {
        case .installModel: loc.t(.nsInstallModelTitle)
        case .ingest(let hasStarted):
            hasStarted ? loc.t(.nsIngestFinishTitle) : loc.t(.nsIngestStartTitle)
        case .assignAudiences: loc.t(.nsAssignAudiencesTitle)
        case .reviewTimeline: loc.t(.nsReviewTimelineTitle)
        case .generatePairs: loc.t(.nsGeneratePairsTitle)
        case .trainModel: loc.t(.nsTrainTitle)
        case .retrainForNewModel: loc.t(.nsRetrainTitle)
        case .promote: loc.t(.nsPromoteTitle)
        }
    }

    @MainActor var message: String {
        let loc = Localization.shared
        return switch self {
        case .installModel: loc.t(.nsInstallModelMsg, AppIdentity.appName)
        case .ingest(let hasStarted):
            hasStarted ? loc.t(.nsIngestFinishMsg) : loc.t(.nsIngestStartMsg)
        case .assignAudiences: loc.t(.nsAssignAudiencesMsg, AppIdentity.appName)
        case .reviewTimeline: loc.t(.nsReviewTimelineMsg)
        case .generatePairs: loc.t(.nsGeneratePairsMsg)
        case .trainModel: loc.t(.nsTrainMsg)
        case .retrainForNewModel: loc.t(.nsRetrainMsg)
        case .promote: loc.t(.nsPromoteMsg)
        }
    }

    @MainActor var buttonTitle: String {
        let loc = Localization.shared
        return switch self {
        case .installModel: loc.t(.nsOpenModels)
        case .ingest: loc.t(.nsOpenSources)
        case .assignAudiences: loc.t(.nsOpenPeople)
        case .reviewTimeline: loc.t(.nsOpenTimeline)
        case .generatePairs, .trainModel, .retrainForNewModel, .promote: loc.t(.nsOpenTrain)
        }
    }

    /// Sidebar section the card's button deep-links to.
    var destination: MainSection {
        switch self {
        case .installModel: .models
        case .ingest: .sources
        case .assignAudiences: .people
        case .reviewTimeline: .timeline
        case .generatePairs, .trainModel, .retrainForNewModel, .promote: .train
        }
    }

    /// First unmet step wins, in the order documented on each case above.
    static func compute(state: PipelineState) -> NextStep? {
        if !state.modelInstalled { return .installModel }
        if state.keptItems == 0 { return .ingest(hasStarted: false) }
        if state.unprocessedItems > 0 { return .ingest(hasStarted: true) }
        if state.audiencesAssignedCount == 0 { return .assignAudiences }
        if !state.timelineReviewed { return .reviewTimeline }
        if state.pendingOrClaimedPairs == 0 && state.succeededRuns == 0 { return .generatePairs }
        if state.succeededRuns == 0 { return .trainModel }
        if state.succeededRunsOnInstalledModel == 0 { return .retrainForNewModel }
        if !state.promotedRunUsable { return .promote }
        return nil
    }

    /// One row of the Overview guide checklist.
    struct GuideItem: Identifiable {
        let id: Int
        let step: NextStep
        let done: Bool
    }

    /// The full ordered checklist behind the Overview guide card — the same
    /// predicates as `compute`, in the same order, so the first not-done
    /// item is always exactly `compute`'s step. The tour ends at onboarding;
    /// this is what teaches the rest of the order (pairs → run → promote →
    /// Compose).
    static func guide(state: PipelineState) -> [GuideItem] {
        // Mirrors compute's retrain substitution: once runs exist but none
        // matches the installed base, the train slot reads "retrain".
        let trainStep: NextStep =
            (state.succeededRuns > 0 && state.succeededRunsOnInstalledModel == 0)
            ? .retrainForNewModel : .trainModel
        let entries: [(NextStep, Bool)] = [
            (.installModel, state.modelInstalled),
            (.ingest(hasStarted: state.keptItems > 0),
             state.keptItems > 0 && state.unprocessedItems == 0),
            (.assignAudiences, state.audiencesAssignedCount > 0),
            (.reviewTimeline, state.timelineReviewed),
            (.generatePairs, state.pendingOrClaimedPairs > 0 || state.succeededRuns > 0),
            (trainStep, state.succeededRunsOnInstalledModel > 0),
            (.promote, state.promotedRunUsable),
        ]
        return entries.enumerated().map { GuideItem(id: $0.offset, step: $0.element.0,
                                                    done: $0.element.1) }
    }
}
