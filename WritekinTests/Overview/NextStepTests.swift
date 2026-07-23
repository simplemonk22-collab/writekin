import Testing
@testable import Writekin

/// Truth table for `NextStep.compute` — each test isolates one boundary by
/// starting from a state where every later step is already satisfied, then
/// flips exactly the field under test.
struct NextStepTests {
    /// A state where every step is satisfied — `compute` should return nil.
    private var allDone: PipelineState {
        PipelineState(modelInstalled: true, keptItems: 10, unprocessedItems: 0,
                       audiencesAssignedCount: 1, timelineReviewed: true,
                       pendingOrClaimedPairs: 5, succeededRuns: 1,
                       succeededRunsOnInstalledModel: 1, promotedRunUsable: true)
    }

    @Test func nilWhenEverythingSatisfied() {
        #expect(NextStep.compute(state: allDone) == nil)
    }

    @Test func installModelWinsWhenNoModel() {
        var state = allDone
        state.modelInstalled = false
        #expect(NextStep.compute(state: state) == .installModel)
    }

    @Test func ingestWhenNoKeptItems() {
        var state = allDone
        state.keptItems = 0
        #expect(NextStep.compute(state: state) == .ingest(hasStarted: false))
    }

    @Test func finishIngestWhenUnprocessedItemsRemain() {
        var state = allDone
        state.unprocessedItems = 3
        #expect(NextStep.compute(state: state) == .ingest(hasStarted: true))
    }

    @Test func assignAudiencesWhenNoneAssigned() {
        var state = allDone
        state.audiencesAssignedCount = 0
        #expect(NextStep.compute(state: state) == .assignAudiences)
    }

    @Test func reviewTimelineWhenCutoffsNeverApplied() {
        var state = allDone
        state.timelineReviewed = false
        #expect(NextStep.compute(state: state) == .reviewTimeline)
    }

    @Test func trainModelWhenNoSucceededRuns() {
        var state = allDone
        state.succeededRuns = 0
        state.succeededRunsOnInstalledModel = 0
        #expect(NextStep.compute(state: state) == .trainModel)
    }

    /// The step BEFORE training: no pairs and no runs yet means "generate
    /// pairs", not "train" — the guide teaches the real order.
    @Test func generatePairsWhenNoPairsAndNoRuns() {
        var state = allDone
        state.pendingOrClaimedPairs = 0
        state.succeededRuns = 0
        state.succeededRunsOnInstalledModel = 0
        #expect(NextStep.compute(state: state) == .generatePairs)
    }

    /// A succeeded run implies pairs were consumed — zero pending pairs must
    /// NOT resurface the generate-pairs step after a successful run.
    @Test func noGeneratePairsStepOnceARunSucceeded() {
        var state = allDone
        state.pendingOrClaimedPairs = 0
        #expect(NextStep.compute(state: state) == nil)
    }

    /// The guide checklist uses the same predicates in the same order as
    /// `compute`, so its first not-done row IS the current step.
    @Test func guideFirstNotDoneMatchesCompute() {
        var state = allDone
        state.pendingOrClaimedPairs = 0
        state.succeededRuns = 0
        state.succeededRunsOnInstalledModel = 0
        state.promotedRunUsable = false
        let items = NextStep.guide(state: state)
        let firstNotDone = items.first(where: { !$0.done })
        #expect(items.count == 7)
        #expect(firstNotDone?.step == NextStep.compute(state: state))
        let firstFourDone = items.prefix(4).allSatisfy(\.done)
        #expect(firstFourDone)
    }

    /// Base-model swap: the guide's train slot reads "retrain" and un-does
    /// itself, even though runs exist.
    @Test func guideTrainSlotBecomesRetrainAfterBaseSwap() {
        var state = allDone
        state.succeededRunsOnInstalledModel = 0
        state.promotedRunUsable = false
        let items = NextStep.guide(state: state)
        let firstNotDone = items.first(where: { !$0.done })
        #expect(items[5].step == .retrainForNewModel)
        #expect(!items[5].done)
        #expect(firstNotDone?.step == NextStep.compute(state: state))
    }

    /// Base-model swap: runs exist, but none on the installed model — the
    /// trained voice can't apply, so the card demands a retrain rather than
    /// reading as done.
    @Test func retrainWhenNoRunMatchesInstalledModel() {
        var state = allDone
        state.succeededRunsOnInstalledModel = 0
        state.promotedRunUsable = false
        #expect(NextStep.compute(state: state) == .retrainForNewModel)
    }

    @Test func promoteWhenMatchingRunSucceededButPromotionNotUsable() {
        var state = allDone
        state.promotedRunUsable = false
        #expect(NextStep.compute(state: state) == .promote)
    }

    /// Ordering: an earlier unmet step wins even when several are unmet at
    /// once — no model installed AND nothing assigned should still surface
    /// `installModel`.
    @Test func earlierStepWinsOverLaterUnmetSteps() {
        var state = allDone
        state.modelInstalled = false
        state.audiencesAssignedCount = 0
        state.succeededRuns = 0
        #expect(NextStep.compute(state: state) == .installModel)
    }

    /// Same idea one step later: model installed and corpus built, but
    /// unprocessed items AND unassigned audiences both present — ingest wins.
    @Test func ingestWinsOverAssignAudiencesWhenBothUnmet() {
        var state = allDone
        state.unprocessedItems = 2
        state.audiencesAssignedCount = 0
        #expect(NextStep.compute(state: state) == .ingest(hasStarted: true))
    }

    /// An empty corpus (`keptItems == 0`) takes priority even if
    /// `unprocessedItems` also happens to be non-zero — "build your corpus"
    /// copy, not "finish processing."
    @Test func emptyCorpusWinsOverUnprocessedItems() {
        var state = allDone
        state.keptItems = 0
        state.unprocessedItems = 5
        #expect(NextStep.compute(state: state) == .ingest(hasStarted: false))
    }
}
