import Testing
import Foundation
import GRDB
@testable import Writekin

struct CutoffStoreTests {
    @Test func roundTripAndDelete() async throws {
        let store = CutoffStore(settings: SettingsStore(db: try AppDatabase.inMemory()))
        #expect(try await store.get(medium: "email") == nil)
        try await store.set(medium: "email", "2023-06")
        #expect(try await store.get(medium: "email") == "2023-06")
        try await store.set(medium: "email", "2023-07")
        #expect(try await store.get(medium: "email") == "2023-07")
        try await store.set(medium: "email", nil)
        #expect(try await store.get(medium: "email") == nil)
    }

    @Test func appliedDiffersIsFalseWhenNoCutoffSet() async throws {
        let store = CutoffStore(settings: SettingsStore(db: try AppDatabase.inMemory()))
        #expect(try await store.appliedDiffers(medium: "email") == false)
    }

    @Test func appliedDiffersIsTrueAfterSettingCutoffWithoutApplying() async throws {
        let store = CutoffStore(settings: SettingsStore(db: try AppDatabase.inMemory()))
        try await store.set(medium: "email", "2023-06")
        #expect(try await store.appliedDiffers(medium: "email") == true)
    }

    @Test func markAppliedClearsAppliedDiffers() async throws {
        let store = CutoffStore(settings: SettingsStore(db: try AppDatabase.inMemory()))
        try await store.set(medium: "email", "2023-06")
        try await store.markApplied(medium: "email")
        #expect(try await store.appliedDiffers(medium: "email") == false)
    }

    @Test func appliedDiffersIsTrueAgainAfterCutoffChangesPostApply() async throws {
        let store = CutoffStore(settings: SettingsStore(db: try AppDatabase.inMemory()))
        try await store.set(medium: "email", "2023-06")
        try await store.markApplied(medium: "email")
        try await store.set(medium: "email", "2023-08")
        #expect(try await store.appliedDiffers(medium: "email") == true)
    }

    @Test func clearingCutoffAfterApplyStillDiffersFromStaleApplied() async throws {
        let store = CutoffStore(settings: SettingsStore(db: try AppDatabase.inMemory()))
        try await store.set(medium: "email", "2023-06")
        try await store.markApplied(medium: "email")
        try await store.set(medium: "email", nil)
        #expect(try await store.appliedDiffers(medium: "email") == true)
    }

    // MARK: - reviewed (item 3)

    @Test func reviewedIsFalseBeforeAnyDecision() async throws {
        let store = CutoffStore(settings: SettingsStore(db: try AppDatabase.inMemory()))
        #expect(try await store.reviewed(medium: "email") == false)
    }

    @Test func settingACutoffMarksReviewed() async throws {
        let store = CutoffStore(settings: SettingsStore(db: try AppDatabase.inMemory()))
        try await store.set(medium: "email", "2023-06")
        #expect(try await store.reviewed(medium: "email") == true)
    }

    @Test func clearingACutoffStillMarksReviewed() async throws {
        let store = CutoffStore(settings: SettingsStore(db: try AppDatabase.inMemory()))
        try await store.set(medium: "email", "2023-06")
        try await store.set(medium: "email", nil)
        #expect(try await store.reviewed(medium: "email") == true)
    }

    @Test func markNoCutoffNeededMarksReviewedAndLeavesNoCutoffStored() async throws {
        let store = CutoffStore(settings: SettingsStore(db: try AppDatabase.inMemory()))
        try await store.markNoCutoffNeeded(medium: "sms")
        #expect(try await store.get(medium: "sms") == nil)
        #expect(try await store.reviewed(medium: "sms") == true)
    }

    @Test func markNoCutoffNeededClearsAnExistingCutoff() async throws {
        let store = CutoffStore(settings: SettingsStore(db: try AppDatabase.inMemory()))
        try await store.set(medium: "sms", "2023-06")
        try await store.markNoCutoffNeeded(medium: "sms")
        #expect(try await store.get(medium: "sms") == nil)
    }

    // MARK: - markNoCutoffNeeded also dismisses the current proposal (item 3)

    @Test func markNoCutoffNeededWithProposedCutoffAlsoDismissesIt() async throws {
        let store = CutoffStore(settings: SettingsStore(db: try AppDatabase.inMemory()))
        try await store.markNoCutoffNeeded(medium: "email", proposedCutoff: "2018-11")
        #expect(try await store.dismissedProposal(medium: "email") == "2018-11")
        #expect(try await store.get(medium: "email") == nil)
    }

    @Test func markNoCutoffNeededWithProposedCutoffEndsUpReviewedAsNone() async throws {
        // "No cutoff needed" is the decision that actually happened -- the
        // dismissed-proposal marker is a side effect of it, so the final
        // `reviewed` value should read "none", not "dismissed".
        let settings = SettingsStore(db: try AppDatabase.inMemory())
        let store = CutoffStore(settings: settings)
        try await store.markNoCutoffNeeded(medium: "email", proposedCutoff: "2018-11")
        #expect(try await settings.get("cutoff.reviewed.email") == "none")
    }

    @Test func markNoCutoffNeededWithoutProposedCutoffLeavesNoDismissalRecorded() async throws {
        let store = CutoffStore(settings: SettingsStore(db: try AppDatabase.inMemory()))
        try await store.markNoCutoffNeeded(medium: "email")
        #expect(try await store.dismissedProposal(medium: "email") == nil)
    }

    @Test func markNoCutoffNeededWithProposedCutoffOverwritesAPriorDifferentDismissal() async throws {
        let store = CutoffStore(settings: SettingsStore(db: try AppDatabase.inMemory()))
        try await store.dismissProposal(medium: "email", month: "2017-01")
        try await store.markNoCutoffNeeded(medium: "email", proposedCutoff: "2018-11")
        #expect(try await store.dismissedProposal(medium: "email") == "2018-11")
    }

    // MARK: - dismissed proposals (item 4)

    @Test func dismissedProposalIsNilByDefault() async throws {
        let store = CutoffStore(settings: SettingsStore(db: try AppDatabase.inMemory()))
        #expect(try await store.dismissedProposal(medium: "email") == nil)
    }

    @Test func dismissProposalRoundTripsAndMarksReviewed() async throws {
        let store = CutoffStore(settings: SettingsStore(db: try AppDatabase.inMemory()))
        try await store.dismissProposal(medium: "email", month: "2018-11")
        #expect(try await store.dismissedProposal(medium: "email") == "2018-11")
        #expect(try await store.reviewed(medium: "email") == true)
    }

    @Test func clearDismissedProposalRemovesTheMarker() async throws {
        let store = CutoffStore(settings: SettingsStore(db: try AppDatabase.inMemory()))
        try await store.dismissProposal(medium: "email", month: "2018-11")
        try await store.clearDismissedProposal(medium: "email")
        #expect(try await store.dismissedProposal(medium: "email") == nil)
    }

    // MARK: - applyAllPending must not be confused by the new key prefixes

    @Test func applyAllPendingIgnoresReviewedAndDismissedKeys() async throws {
        let settings = SettingsStore(db: try AppDatabase.inMemory())
        let store = CutoffStore(settings: settings)
        try await store.set(medium: "email", "2023-06")
        try await store.markNoCutoffNeeded(medium: "sms")
        try await store.dismissProposal(medium: "doc", month: "2019-01")
        try await store.applyAllPending()
        #expect(try await store.appliedDiffers(medium: "email") == false)
        // "sms" and "doc" never had a real cutoff applied -- applyAllPending
        // must not have synthesized bogus applied keys like
        // "cutoff.applied.reviewed.sms" from the new key prefixes.
        #expect(try await settings.get("cutoff.applied.reviewed.sms") == nil)
        #expect(try await settings.get("cutoff.applied.proposal.dismissed.doc") == nil)
    }
}
