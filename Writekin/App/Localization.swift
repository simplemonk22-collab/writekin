import Foundation
import Observation

/// In-app localization layer (Spanish is the proof language — every string
/// ships in both). A custom layer — not Apple String
/// Catalogs — because the language is a live in-app SETTING (Settings ›
/// General, and the welcome screen), while catalogs follow the system
/// locale and can't switch without relaunch.
///
/// ## How to add a language
/// 1. Add a case to `AppLanguage` — the compiler then walks you through
///    the rest: its `displayName` (in that language) and its `pack` arm
///    are exhaustive switches that refuse to build until wired.
/// 2. Create the `App/Locales/<Language>/` folder with
///    `L10nTables+<Language>.swift` (the `[L10nKey: String]` display
///    table) and `LanguagePack+<Language>.swift` (the pack: table +
///    greeting/signoff/casual/assistant-imperative MATCH lists over draft
///    text — union-matched across languages because a draft's language is
///    independent of the app language, which is why they aren't table
///    entries). Nothing else registers anything.
/// 3. Run the tests — `localizationTablesAreComplete` fails on any missing
///    key, so a partial translation can't ship silently (missing keys fall
///    back to English at runtime regardless), and the placeholder-parity
///    test fails if a translation's `%@`/`%d` format specifiers don't match
///    English's.
///
/// ## Conventions
/// - Values with runtime data use `String(format:)` placeholders; call
///   `t(key, args...)`. The app name is always passed as a `%@` argument
///   (never baked into the table) so a rename stays a one-file change.
/// - If a language needs arguments in a different ORDER than English, use
///   positional specifiers in that language's value ("%2$@ de %1$@") —
///   `String(format:)` supports them; call sites don't change.
enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case spanish = "es"

    /// Shown in ITS OWN language — a Spanish speaker lost in an English UI
    /// must be able to recognize their language.
    var displayName: String {
        switch self {
        case .english: "English"
        case .spanish: "Español"
        }
    }

    /// THE registration point: exhaustive, so adding a case refuses to
    /// build until its `LanguagePack` (Locales/<Language>/) is wired here.
    /// Everything language-derived — tables, boundary-marker unions —
    /// flows from this.
    var pack: LanguagePack {
        switch self {
        case .english: .english
        case .spanish: .spanish
        }
    }
}

/// Every localized string, as a typed key — typos are compile errors and
/// table completeness is testable.
enum L10nKey: String, CaseIterable, Sendable {
    // Onboarding
    case welcomeTitle, welcomeBody, welcomeFaith, welcomeSourceLink, welcomeGetStarted
    case skipTour
    case permissionTitle, permissionBody, permissionOpenSettings, permissionSkip
    case detectTitle, detectBody, detectStillScanning, continueButton
    case detectScanningCard, detectNotFound, detectNeedsFDA, detectUnreadable
    case detectGrantAccess, detectRescan, detectItemsCount
    case noteSentSampled, notePartialDownloads, noteSentEmpty, noteNoSentMailboxes
    case noteMaildir, noteSizeEstimate, noteItemsInFolder
    case noteClaudeCodeSessionOne, noteClaudeCodeSessions
    case noteClaudeDesktopSessionOne, noteClaudeDesktopSessions
    case noteClaudeDesktopServerSide, noteWhatsAppMirror
    case modelsTitle, modelsBody, modelsOpening
    // Sidebar sections
    case sectionOverview, sectionSources, sectionBrowse, sectionPeople
    case sectionTimeline, sectionTrain, sectionVoice, sectionCompose, sectionModels
    // Settings › General
    case settingsAbout, settingsVersion, settingsShowTour, settingsUpdates
    case settingsAutoCheck, settingsLastChecked, settingsNever, settingsCheckNow
    case settingsUpdatePrivacy, settingsUpdatesUnconfigured
    case settingsLanguage, settingsLanguagePicker
    // Full Disk Access
    case fdaBanner, fdaOpenSystemSettings, fdaRowBlocked
    case fdaDialogTitle, fdaDialogMessage, fdaIngestWithout, cancel
    // Menus
    case menuAbout, menuCheckUpdates, menuHelp, menuReportIssue
    // Settings tabs
    case tabGeneral, tabFiltering
    // Settings › Filtering
    case filterSectionLength, filterMinWordsEmailDoc, filterMinWordsEmailDocCaption
    case filterMinWordsChat, filterMinWordsChatCaption
    case filterSectionRatios, filterQuoteThreshold, filterQuoteCaption
    case filterLinksThreshold, filterLinksCaption
    case filterSectionRules, filterGameShares, filterGameSharesCaption
    case filterRequiredLanguage, filterLangOff, filterLangCaption
    case filterApplyNote, reapplyFilters, reapplyHelp, reapplyHelpTraining
    // Settings › Timeline (scan)
    case scanSectionSignals, scanEmDashes, scanEmDashesCaption
    case scanPhrases, scanPhrasesCaption, scanListFormatting, scanListFormattingCaption
    case scanSectionSensitivity, scanCustom, scanUsePreset, scanOverrideActive
    case scanSensLow, scanSensNormal, scanSensHigh
    case scanSensLowCaption, scanSensNormalCaption, scanSensHighCaption
    case scanAdvanced, scanBaselinePlaceholder, scanBaselineValid, scanBaselineInvalid
    case scanMinItems, scanMinItemsCaption, scanZOverride, scanStreakOverride
    case scanOverrideCaption, scanStockPhrases, scanUncheckCaption, scanResetDefaults
    case scanYourAdditions, scanRemovePhrase, scanAddPlaceholder, scanAdd
    case scanMatchedCaption, scanRescanNote
    // Settings › Sources
    case sourcePickerLabel, sourceInclude, sourceNoSettings
    // Settings › Sources › Documents
    case docFoldersTitle, docFoldersEmpty, docAddFolder, docFoldersReset
    case docFoldersNote, docFileTypes, docFileTypesNote
    case docRemoveFolderHelp, docAddPrompt, docPagesDetail
    // About panel
    case aboutRepo, aboutReportIssue, aboutLicense
    // Models screen
    case modelsCaption, modelsThisMac, modelsChip, modelsMemory, modelsCPU
    case modelsMemoryUnified, modelsMemoryNote, modelsCoresFull, modelsCores
    case modelsComposeTitle, modelsComposeCaption
    case modelsLabelerTitle, modelsLabelerCaption
    case modelsRoleInstalled, modelsNoLabelerWarn, modelsNoComposeWarn
    case modelsPairGenTitle, modelsPairGenCaption, modelsPairGenPicker
    case modelsPairGenComposeOption, modelsPairGenLabelerOption, modelsPairGenNoLabeler
    case modelsOtherModels, modelsOtherInstalled
    case modelsRemoveTitle, modelsRemoveGeneric, modelsRemove
    case modelsRemoveLabelerMsg, modelsRemoveComposeMsg, modelsRemoveOtherMsg
    case modelsRetry, modelsDownload, modelsInstalledBadge
    case modelsKindCompose, modelsKindLabeler, modelsTierLine
    case modelsPath, modelsSize, modelsProgressOf
    case modelsEstimating, modelsRateOnly, modelsEtaLeft
    case modelsAdoptedFrom, modelsDownloadedWord
    case modelsFoundOnMac, modelsRescanHelp, modelsNothingScouted
    case modelsFoundVia, modelsUseThisCopy
    case modelsFitHelp, modelsBestMatch, modelsBestMatchHelp
    case fitGreat, fitOk, fitTooBig
    case fitGreatDetail, fitOkDetail, fitTooBigDetail
    case scoutNoteGGUF, scoutNoteNameMatch
    // Overview
    case ovItemsSubtitle, ovItems, ovTokens, ovSpan, ovFilteredOut
    case ovBuildingTitle, ovBuildingDesc, ovAlmostThere, ovInterruptedDesc
    case ovEmptyTitle, ovEmptyDesc
    case chartCorpusOverTime, chartByAccount, chartWordsPerItem, chartYear, chartItems
    // Drop reasons (Filtered out panel + Browse)
    case dropTooShort, dropNonEnglish, dropQuoteDominated, dropUrlDominated
    case dropBoilerplate, dropBodyNotDownloaded, dropFormatUnsupported
    case dropSelfGenerated, dropNearDuplicate, dropGameShare, dropPastCutoff
    case dropNotYourWriting, dropUnparseable, dropFormDocument
    case dropCodeContent, dropLikelyPaste
    // Next-step card
    case nsInstallModelTitle, nsIngestFinishTitle, nsIngestStartTitle
    case nsAssignAudiencesTitle, nsReviewTimelineTitle, nsTrainTitle
    case nsRetrainTitle, nsPromoteTitle
    case nsGeneratePairsTitle, nsGeneratePairsMsg, guideTitle
    case nsInstallModelMsg, nsIngestFinishMsg, nsIngestStartMsg
    case nsAssignAudiencesMsg, nsReviewTimelineMsg, nsTrainMsg
    case nsRetrainMsg, nsPromoteMsg
    case nsOpenModels, nsOpenSources, nsOpenPeople, nsOpenTimeline, nsOpenTrain
    // Sources tab
    case catEmail, catMessaging, catDocuments, catAI
    case catEmailCaption, catMessagingCaption, catDocumentsCaption, catAICaption
    case caveatClaudeDesktop
    case nounMailbox, nounMailboxes, nounTranscript, nounTranscripts
    case nounChat, nounChats, nounFile, nounFiles
    case srcAdded, srcAlreadyIn, srcUnreadable, srcUnchanged, srcKeptTotal
    case srcRunning, srcRunningChecked
    case srcExcluded, srcLastSynced, srcNotIngested, srcStillWorking, srcStopped
    case srcDocsGearHelp, srcSetupMessages, srcDownloadingMessages
    case srcExporterFailed, srcExporterHelp, srcExporterMissing
    case srcResetCorpusEllipsis, srcResetDialogTitle, srcResetCorpus, srcResetMsg
    case srcStoppedProcessing, srcWaitingProcess
    // Browse tab
    case brShowingOf, brCaption, brKind, brStatus, brReason, brSort
    case brAll, brEmail, brMessages, brDocs, brAIChats
    case brKept, brFilteredState, brUnprocessed
    case brDate, brName, brFolder, brSearch
    case brWaitingTitle, brWaitingDesc, brNoItems, brNoItemsDesc
    case brSelectItem, brNSelected
    case brExcludeN, brRestoreN, brExclude, brRestore
    case brExcludeHelpMany, brRestoreHelpMany, brExcludeHelpOne, brRestoreHelpOne
    case brShowRaw, brReveal, brDetails, brMedium, brType, brWords, brWordsCount
    case brExcludeFolder, brRestoreFolder, brExcludeFolderHelp, brRestoreFolderHelp
    case brFolderConfirmExclude, brFolderConfirmRestore, brFolderExcludeMsg
    // People tab
    case peopleSection, peopleAccounts, peopleAudiences
    // Persona presets + audience buckets (display labels only — canonical
    // English/raw values are what's stored and matched)
    case personaPersonal, personaWork, personaSideProject, personaOldJob, personaSchool
    case bucketFamily, bucketFriend, bucketSelf, bucketWork, bucketInvestor, bucketCold
    // People › Accounts
    case paCaption1, paCaption2, paIngestLock, paEmptyTitle, paEmptyDesc
    case paIgnoreTitle, paIgnore, paIgnoreEllipsis, paUnignoreTitle, paUnignore
    case paAlsoExcludeOne, paAlsoExcludeMany, paAlsoRestoreOne, paAlsoRestoreMany
    case paMergeExplainer, paKeepsPersona, paNoPersona, paMergeSelectedCount
    case paDupFoundOne, paDupFoundMany, paReviewMergesOne, paReviewMergesMany
    case paDupResolvedElsewhere
    case paNIgnored, paShow, paHide
    case paColHandle, paColPersona, paColKept, paColDateRange
    case paServerArtifact, paServerArtifactIgnored
    case paMergeInto, paMergeSelectedInto
    case paPersonaPlaceholder, paCustom, paNone, paSetPersona
    case paHelpPersonal, paHelpWork, paHelpOldJob, paHelpSideProject, paHelpSchool
    case paPersonaHelpFooter
    case paErrLoadAccounts, paErrSavePersona, paErrIgnoredState, paErrIgnore
    case paErrUnignore, paErrMerge, paErrMergeDuplicates, paErrLoadMergeCandidates
    // People › Audiences
    case audCaption1, audCaption2, audApplyToCorpus, audNUpdated
    case audEmptyTitle, audEmptyDesc
    case audLinkSamePersonTitle, audLinkSamePersonEllipsis, audLinkToPersonEllipsis
    case audUseAsKeep, audLinkDialogMsg
    case audBucketHelpTitle, audHelpFamily, audHelpFriend, audHelpSelf
    case audHelpWork, audHelpInvestor, audHelpCold
    case audScope, audScopePeople, audScopeAddresses
    case audSelectAll, audDeselectAll, audSelectAllHelp, audSearchPrompt, audClear
    case audNSelected, audIgnore, audUnignore, audDeselect, audNIgnored
    case audLinksFoundOne, audLinksFoundMany, audReviewLinksOne, audReviewLinksMany
    case audLinkExplainer, audDismiss, audLinkSelectedCount
    case audColHandle, audColKept, audColAudience
    case audAssignToSelected, audAssignTo, audNone
    case audLinkToPersonMsg, audLink, audLinkedList
    case audErrLoadRecipients, audErrLoadLinks, audErrDismiss, audErrLink
    case audErrIgnoredState, audErrSaveAssignment, audErrBackfill
    // Timeline
    case tlScreenCaption, tlScanningStart, tlScanningProgress
    case tlScanFailedTitle, tlScanFailedMsg, tlRetry
    case tlEmptyTitle, tlEmptyDesc
    case tlCutoffsChangedBanner
    case tlProposed, tlAccept, tlDismiss, tlProposalDismissed, tlProposeAgain
    case tlChartExplainer, tlCutoffLabel, tlCutoffNone, tlClearCutoff, tlNoCutoffNeeded
    case tlYAxisLabel
    case tlMediumTexts
    case tlPluralEmails, tlPluralTexts, tlPluralDocs, tlPluralChats
    case tlCaptionWeakBaseline, tlCaptionInflect, tlCaptionClean
    case tlScoreExplainerHelp, tlExplainerTitle, tlExplainerIntro
    case tlSignalEmDashes, tlSignalPhrases, tlSignalLists, tlWeightRow
    case tlExplainerSum, tlPhrasesCounted, tlExplainerThreshold
    case tlExplainerNotTitle, tlNotDetector, tlNotCloud, tlNotSentenceLength
    // Voice profile
    case vpScreenCaption, vpFooter, vpAllWriting
    case vpItemCountOne, vpItemCountMany, vpThinProfile
    case vpSentenceLength, vpHowYouWrite
    case vpStatAvgSentence, vpStatContractions, vpStatExclaims, vpStatEmoji
    case vpContractionFrequent, vpContractionOccasional, vpContractionRare
    case vpYourPhrases, vpNoPhrases, vpShowCount, vpPhraseCountActual
    case vpSearchPhrases, vpPhraseMatches
    case vpOpeners, vpNoEmailSamples, vpOpensWith, vpSignsOff
    case vpSamplesTitle, vpNoSamples
    // Compose
    case cpNoModelTitle, cpNoModelDesc, cpGoToModels
    case cpModeRewrite, cpModeGenerate
    case cpRewriteStyleLabel, cpStyleAuto, cpStyleOnePass, cpStyleSections
    case cpStyleInfoHelp, cpStyleInfoBody
    case cpRunPickerLabel, cpRunBaseOption, cpRunOption, cpRunInactiveOption, cpRunPickerHelp
    case cpLoadingModel, cpWriting, cpRealizing, cpWrite, cpRealize, cpTrainBusyHelp
    case cpStop
    case cpAutoOnePassShort, cpAutoOnePassStructured, cpAutoChunked
    case cpStatusPart, cpStatusRetryReply, cpStatusRetryEcho, cpStatusAvoidWords
    case cpEtaLeft
    case cpSuggestReasonDoc, cpSuggestReasonEmail, cpSuggestReasonChat, cpSuggestSet
    case cpDraftHeader, cpInstructionHeader
    case cpGeneratePlaceholder, cpRewritePlaceholder
    case cpRealizedHeader, cpFineTunedBadge, cpFineTunedBadgeHelp
    case cpThinProfileCaption
    case cpCopy, cpCopied, cpCopyHelp, cpRegenerate, cpRegenerateHelp
    case cpShowChanges, cpRemovals, cpRemovalsHelpOn, cpRemovalsHelpOff
    case cpTabBase, cpWritingBaseVersion, cpBaseStillWriting
    case cpSaveAsMyVersion, cpSaveAsMyVersionHelp
    case cpCorrectionsWaitingOne, cpCorrectionsWaitingMany
    case cpAutoBaseToggle, cpAutoBaseHelp
    case cpYourVersionTitle, cpCorrectionExplainer, cpSaveCorrection, cpCorrectionUnchangedHelp
    case cpMovedToward, cpMovedAway, cpNoNetMovement
    case cpVsNameBase, cpVsNameFineTuned, cpVsPlus, cpVsMinus, cpVsTies, cpVsHelp
    case cpRegister, cpPersona, cpModeLabel, cpAny
    case cpModeCasual, cpModeLogistics, cpModeProfessional, cpModePitch, cpModeEssay
    case cpAdapterInactiveNotice
    case cpErrNoModelLoaded, cpErrLoadFailed, cpErrReplied
    case cpUnchangedNotice, cpUnchangedNoticeHelp
    case cpChipSignals, cpChipHelp, cpChipFooter
    case cpSigSentenceLen, cpSigContractions, cpSigPhrasing, cpSigExclaims, cpSigEmoji
    case cpSigDashes, cpSigQuestions, cpSigWordLen, cpSigRhythm, cpSigOpener, cpSigSignoff
    case cpSigNotYourWords, cpSigLengthVsDraft
    case cpSigSentenceMatchDetail, cpSigSentenceOffDetail, cpLonger, cpShorter
    case cpSigContractionsMatchDetail, cpSigContractionsOffDetail
    case cpSigPhrasingMatchDetail, cpSigPhrasingNeutralDetail
    case cpBucketRare, cpBucketOccasional, cpBucketConstant
    case cpThingExclaims, cpThingEmoji, cpThingDashes, cpThingQuestions
    case cpSigRateMatchDetail, cpSigRateOffDetail
    case cpSigWordLenMatchDetail, cpSigWordLenOffDetail, cpFancier, cpPlainer
    case cpSigRhythmMatchDetail, cpSigRhythmOffDetail
    case cpSigOpenerMatchDetail, cpSigOpenerOffDetail
    case cpSigSignoffMatchDetail, cpSigSignoffOffDetail
    case cpSigLeakMatchDetail, cpSigLeakOffDetail
    case cpSigLenDraftMatchDetail, cpSigLenDraftOffDetail
    case cpSigLenDraftLongDetail, cpSigLenDraftReferenceDetail
    // Train
    case trScreenCaption, trPairsCardTitle, trDatasetsHeader, trNoDatasets
    case trDeleteDatasetTitle, trDeleteDataset, trDeleteDatasetMsg
    case trCoverageCaption, trSparse, trSparseHelp
    case trInferred, trInferredAccountHelp, trInferredOneOffHelp
    case trUnlabeled, trUnlabeledHelp
    case trStop, trGeneratingPairs, trSkippedAlreadyPaired
    case trGeneratePairsEllipsis, trWaitIngest, trWaitTraining
    case trPairSummary, trPairSummaryReused, trPairSummaryFallbacks
    case trTrainingRunsHeader, trStartRunEllipsis, trNeedComposeForTraining, trNoRunsYet
    case trHowToReadRun, trRunsPopoverBody
    case trRunN, trResume, trResumeHelp
    case trExportAdapterEllipsis, trDeleteRunEllipsis, trDeleteRunTitle, trDeleteRun
    case trDeleteRunMsg, trRunMenuHelp
    case trDatasetN, trConfigSummary, trConfigLayers, trConfigSeed
    case trFinishingUp, trIterationProgress, trAddNote
    case trSampleValLow, trSampleValLowHelp, trScrollToPan
    case trSeriesTrain, trSeriesVal
    case trChipTrain, trChipVal, trChipGap
    case trTrainChipHelp, trValChipCompareHelp, trValChipHelp, trGapChipHelp
    case trBeats, trBehind, trTiesWord
    case trRegurgFlagged, trRegurgSkipped, trRegurgPartial
    case trBaseMissing, trStopUsing, trStopUsingInactive, trStopUsingInactiveHelp
    case trUseInCompose, trNeedsBaseFirst
    case trExportHelp, trExportNothing, trRevealHelp, trFilesNotOnDisk
    case trExportFailedTitle, trOK, trExportPanelTitle, trExportPrompt, trExportError
    case trStatusSucceeded, trStatusRunning, trStatusFailed, trStatusCancelled
    case trInsights, trInsightsHelp, trInsightsFooter
    case trDeleteDatasetHelp, trKeptAsRunRecord, trDatasetInfoHelp
    case trChipPairs, trChipHeldout, trChipReused, trChipCorrections
    case trChipMix, trChipGen, trChipCorpusGrown
    case trPairsChipHelp, trHeldoutChipHelp, trReusedChipHelp, trCorrectionsChipHelp
    case trMixChipHelp, trGenChipHelp, trCorpusGrownHelp
    case trMediaPrefix, trGeneratedWith, trReusedKeepModel, trCorpusNowHas
    case trNotUsedByRun, trUsedBy, trBestVal
    case trMixLabel, trMixTarget, trHeldoutTarget
    case trMixBelowDegradation, trMixBelowBacktranslation, trMixAboveCompletion
    case trHeldoutDeviantHelp, trReplyContext
    case trHowToReadDataset, trDatasetsPopoverBody
    case trStartRunTitle, trRecommendedLine
    case trSuggestionChangeData, trSuggestedNextRun, trApply, trApplyHelp, trFromRun
    case trDatasetLabel, trBaseModelLabel, trNoneInstalled
    case trRankLabel, trRankCaption, trIterationsLabel, trIterationsCaption
    case trLearningRateLabel, trLearningRateCaption
    case trLayersLabel, trLayersCaption, trSeqLenLabel, trSeqLenCaption
    case trSeedLabel, trSeedCaption, trStart
    case trGeneratePairsTitle, trPairGenSheetCaption, trItemCapLabel, trItemCapCaption
    case trGenerateWithLabel, trWillUse, trNoRoleModel, trGenerate
    case trTailQualityCheck, trTailSaving, trPairGenNoModel
    case trBgTraining, trBgTrainingIteration, trBgGeneratingPairs
    case trEtaEstimating, trEtaOverdue, trEtaLessThanMinute
    case trEtaMinLeft, trEtaHrLeft, trEtaHrMinLeft
    case trDsPairsCount, trDsSplit
    // Train › Advice
    case raKnobRank, raKnobLearningRate, raKnobIterations, raKnobLayers
    case raKnobSeqLen, raKnobSeed
    case raKnobBestUsed, raKnobCounterAlone, raKnobCounterMixed
    case raEvidenceBottomed, raEvidenceStillImproving, raEvidenceFlatBy
    case raEvidenceBestUsedIterations
    case raSugStopNearLow, raSugExtendIterations, raSugDataGap, raSugRideWinner
    case raSugDoubleRank, raSugMoreLayers, raSugAllTested
    case raFirstRunOnDataset, raSeedOnlyNoise, raWithinNoiseFloor
    case raSameSettingsNoise, raChangedHurt, raSingleChangeHelped, raMultiChangeHelped
    case raSmallWin, raSmallWinDuration, raSmallWinTail
    case raDatasetFloor, raFloorRegenerate, raFloorNewData
    case raValBottomed, raStillFalling, raFlatFinalStretch
    case raMemorizingGap, raHeadroom, raSlowerRun
    case raGapCaption, raGapHealthy, raGapWatch, raGapMemorizing
    case raDeltaBetter, raDeltaWorse, raDeltaSame
    // Ingest progress (typed IngestPhase / PassActivity / PassNote —
    // produced off the MainActor, translated at render time)
    case ipStarting, ipReadingAppleMail, ipReadingThunderbird, ipReadingDocuments
    case ipReadingWhatsApp, ipReadingClaudeCode, ipReadingClaudeDesktop
    case ipExportingMessages, ipScanningAllMail, ipReadingName, ipUpToDate
    case ipResettingFilters, ipRecleaning, ipStep, ipStepProgress
    case ipPassCleaning, ipPassFiltering, ipPassDedupe, ipPassLabeling
    case ipTimingDedupe
    case ipNoteLabelerLoadFailed, ipNoteLabelerNotInstalled
    case ipIngesting
}

/// The one observable language switch. Views read strings through
/// `Localization.shared.t(_:)` inside `body`, which registers observation —
/// flipping the language re-renders every localized view live.
@MainActor
@Observable
final class Localization {
    static let shared = Localization()

    private static let defaultsKey = "app.language"

    /// The SAME defaults instance for read and write — the first version
    /// read from the injected instance but wrote to `.standard`, so unit
    /// tests (whose host is the real app) silently flipped the actual
    /// app's language to Spanish on every suite run.
    @ObservationIgnored private let defaults: UserDefaults

    var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Self.defaultsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: Self.defaultsKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .english
    }

    /// The key's string in the current language, falling back to English
    /// for any key a table is missing.
    func t(_ key: L10nKey) -> String {
        L10nTables.table(for: language)[key] ?? L10nTables.english[key] ?? key.rawValue
    }

    /// Parameterized variant — table entries hold `String(format:)`
    /// placeholders ("Minimum words: %d"), so translations control where
    /// the value lands in the sentence.
    func t(_ key: L10nKey, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }
}

enum L10nTables {
    static func table(for language: AppLanguage) -> [L10nKey: String] {
        language.pack.table
    }

}
