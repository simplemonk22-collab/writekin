import SwiftUI

/// Voice Profile: its own sidebar page (formerly a Compose inspector)
/// surfacing what `StyleProfiler` (and, for samples, `ExemplarRetriever`)
/// learned for a chosen register — the same profile and exemplars Realize
/// itself consumes, made visible so the user can sanity-check what's
/// steering generation without needing Compose open. Owns its own register
/// pickers (independent of `ComposeViewModel`'s) so the two screens don't
/// share selection state.
struct VoiceProfileView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var personaAccountID: Int64?
    @State private var medium: String?
    @State private var audience: String?
    @State private var mode: String?
    @State private var personas: [AccountSummary] = []

    private var register: RegisterQuery {
        RegisterQuery(medium: medium, audience: audience, mode: mode, accountID: personaAccountID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenCaption(text: Localization.shared.t(.vpScreenCaption, AppIdentity.appName))
                RegisterControls(personaAccountID: $personaAccountID, medium: $medium,
                                  audience: $audience, mode: $mode, personas: personas)
                // Page width lets the stats breathe onto one row and the
                // samples show more of each excerpt than the old inspector's
                // ~320pt-wide sidebar could.
                VoiceProfileContent(register: register, draftForExemplars: "", personas: personas,
                                     wide: true, samplesLimit: 5, excerptChars: 300)
            }
            .padding(20)
        }
        .navigationTitle(MainSection.voice.title)
        .task {
            await env.modelLibrary.refresh()
            personas = (try? await AccountAdmin(db: env.database).summaries())?
                .filter { $0.persona != nil } ?? []
        }
    }
}

/// Read-only profile content for one register — the header/stats/phrases/
/// openers/samples sections, reused by `VoiceProfileView` at page width.
/// Purely presentational; owns only its own async-loaded state, keyed on the
/// register so switching any register knob refreshes it (both calls hit
/// `StyleProfiler`'s per-query cache, so this is cheap after the first
/// Realize for a register).
struct VoiceProfileContent: View {
    let register: RegisterQuery
    /// Draft text handed to `ExemplarRetriever` for FTS ranking — an empty
    /// draft (nothing typed yet, or "Write from prompt" mode) falls through
    /// to the retriever's recency-fill path, same as a fresh Realize would.
    let draftForExemplars: String
    let personas: [AccountSummary]
    /// True for the full-page `VoiceProfileView` layout: the "how you write"
    /// stats lay out in a single breathing row instead of two cramped ones.
    var wide: Bool = false
    var samplesLimit: Int = 3
    var excerptChars: Int = VoiceProfileContent.excerptLength

    @Environment(AppEnvironment.self) private var env
    @State private var profile: StyleProfile?
    @State private var exemplars: [Exemplar] = []
    /// The wide page's "Show N" phrase-count selection; non-default counts
    /// load into `expandedPhrases` (nil = use the profile's default list).
    @State private var phraseCount = StyleProfiler.defaultPhraseCap
    @State private var expandedPhrases: [String]?
    @State private var isLoadingPhrases = false
    @State private var phraseSearch = ""

    private var persona: AccountSummary? {
        guard let id = register.accountID else { return nil }
        return personas.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let profile {
                howYouWriteSection(profile)
                phrasesSection(profile)
                if register.medium == "email" {
                    openersSection(profile)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            samplesSection
            Text(Localization.shared.t(.vpFooter))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: register) {
            await load()
        }
    }

    private func load() async {
        profile = nil
        exemplars = []
        expandedPhrases = nil
        async let profileResult = try? env.styleProfiler.profile(for: register)
        async let exemplarResult = try? ExemplarRetriever(db: env.database)
            .exemplars(for: draftForExemplars, register: register, limit: samplesLimit)
        profile = await profileResult
        exemplars = await exemplarResult ?? []
        // A non-default count selection survives a register switch.
        if phraseCount != StyleProfiler.defaultPhraseCap {
            await loadPhrases(count: phraseCount)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Localization.shared.t(.sectionVoice)).font(.title3.bold())
            Text(Self.describeRegister(medium: register.medium, audience: register.audience,
                                        mode: register.mode, persona: persona))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let profile {
                Text(Self.itemCountText(profile.itemCount))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if profile.itemCount < StyleProfiler.minPoolSize {
                    Label(Self.thinProfileWarning(itemCount: profile.itemCount),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - How you write here

    private func howYouWriteSection(_ profile: StyleProfile) -> some View {
        let loc = Localization.shared
        let contraction = Self.contractionText(rate: profile.contractionRate)
        let contractionChip = "\(Self.contractionBucketLabel(contraction.bucket)) (\(contraction.percent))"
        return VStack(alignment: .leading, spacing: 8) {
            Text(loc.t(.vpHowYouWrite)).font(.headline)
            if wide {
                HStack(alignment: .top, spacing: 32) {
                    statChip(Self.sentenceLengthText(meanSentenceLen: profile.meanSentenceLen,
                                                      sentenceLenSD: profile.sentenceLenSD),
                             loc.t(.vpStatAvgSentence))
                    statChip(contractionChip, loc.t(.vpStatContractions))
                    statChip(Self.perThousandText(profile.exclamationPer1k), loc.t(.vpStatExclaims))
                    statChip(Self.perThousandText(profile.emojiPer1k), loc.t(.vpStatEmoji))
                    Spacer(minLength: 0)
                }
            } else {
                HStack(alignment: .top, spacing: 20) {
                    statChip(Self.sentenceLengthText(meanSentenceLen: profile.meanSentenceLen,
                                                      sentenceLenSD: profile.sentenceLenSD),
                             loc.t(.vpStatAvgSentence))
                    statChip(contractionChip, loc.t(.vpStatContractions))
                }
                HStack(alignment: .top, spacing: 20) {
                    statChip(Self.perThousandText(profile.exclamationPer1k), loc.t(.vpStatExclaims))
                    statChip(Self.perThousandText(profile.emojiPer1k), loc.t(.vpStatEmoji))
                }
            }
        }
    }

    /// Render-time display label for a raw contraction bucket — the raw
    /// "frequent"/"occasional"/"rare" value stays shared with
    /// `StyleProfile.promptBlock()`; only the display is localized.
    @MainActor
    private static func contractionBucketLabel(_ bucket: String) -> String {
        switch bucket {
        case "frequent": Localization.shared.t(.vpContractionFrequent)
        case "occasional": Localization.shared.t(.vpContractionOccasional)
        case "rare": Localization.shared.t(.vpContractionRare)
        default: bucket
        }
    }

    private func statChip(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Phrases

    /// Counts offered by the wide page's "Show" picker. 50 is the default
    /// (the engine's own cap); larger counts recompute the profile with a
    /// raised cap on demand.
    static let phraseCountOptions = [10, 50, 100, 500, 1000, 2500, 5000]

    private func phrasesSection(_ profile: StyleProfile) -> some View {
        let allPhrases = expandedPhrases ?? profile.favoritePhrases
        let phrases = filteredPhrases(allPhrases)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(Localization.shared.t(.vpYourPhrases)).font(.headline)
                if wide {
                    Picker(Localization.shared.t(.vpShowCount), selection: $phraseCount) {
                        ForEach(Self.phraseCountOptions, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .fixedSize()
                    TextField(Localization.shared.t(.vpSearchPhrases), text: $phraseSearch)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    if !phraseSearch.isEmpty {
                        Text(Localization.shared.t(.vpPhraseMatches, String(phrases.count)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if isLoadingPhrases {
                        ProgressView().controlSize(.small)
                    } else if phraseSearch.isEmpty, phraseCount > allPhrases.count {
                        // Asked for more than the corpus yields — say so
                        // instead of looking broken.
                        Text(Localization.shared.t(.vpPhraseCountActual,
                                                   String(allPhrases.count)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if phrases.isEmpty {
                Text(Localization.shared.t(.vpNoPhrases))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if phrases.count > 200 {
                // Thousands of capsule chips make the custom flow layout
                // crawl; one selectable text block is fast and lets any
                // suspicious phrase be copied out for a bug report.
                Text(phrases.joined(separator: "   ·   "))
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(phrases, id: \.self) { phrase in
                        Text(phrase)
                            .font(.caption)
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                }
            }
        }
        .onChange(of: phraseCount) { _, newCount in
            Task { await loadPhrases(count: newCount) }
        }
    }

    /// Case/diacritic-insensitive substring filter over the phrase list —
    /// the fastest way to hunt down a suspicious chip.
    private func filteredPhrases(_ phrases: [String]) -> [String] {
        guard !phraseSearch.isEmpty else { return phrases }
        func fold(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        }
        let needle = fold(phraseSearch)
        return phrases.filter { fold($0).contains(needle) }
    }

    private func loadPhrases(count: Int) async {
        if count == StyleProfiler.defaultPhraseCap {
            expandedPhrases = nil
            return
        }
        isLoadingPhrases = true
        defer { isLoadingPhrases = false }
        if count < StyleProfiler.defaultPhraseCap {
            // A shorter list is a prefix of the default one (the selection
            // order is deterministic) — serve it from the cached profile.
            expandedPhrases = (try? await env.styleProfiler.profile(for: register))
                .map { Array($0.favoritePhrases.prefix(count)) }
        } else {
            expandedPhrases = (try? await env.styleProfiler
                .profile(for: register, phraseCap: count))?.favoritePhrases
        }
    }

    // MARK: - Openers & signoffs

    private func openersSection(_ profile: StyleProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Localization.shared.t(.vpOpeners)).font(.headline)
            if profile.topGreetings.isEmpty && profile.topSignoffs.isEmpty {
                Text(Localization.shared.t(.vpNoEmailSamples))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                if !profile.topGreetings.isEmpty {
                    Text(Localization.shared.t(.vpOpensWith,
                                               profile.topGreetings.map { "\u{201C}\($0)\u{201D}" }
                                                   .joined(separator: ", ")))
                        .font(.callout)
                }
                if !profile.topSignoffs.isEmpty {
                    Text(Localization.shared.t(.vpSignsOff,
                                               profile.topSignoffs.map { "\u{201C}\($0)\u{201D}" }
                                                   .joined(separator: ", ")))
                        .font(.callout)
                }
            }
        }
    }

    // MARK: - Samples

    private var samplesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Localization.shared.t(.vpSamplesTitle)).font(.headline)
            if exemplars.isEmpty {
                Text(Localization.shared.t(.vpNoSamples))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(exemplars.prefix(samplesLimit), id: \.itemID) { exemplar in
                    Text("\u{201C}\(Self.excerpt(exemplar.text, length: excerptChars))\u{201D}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
        }
    }

    // MARK: - Pure formatting helpers (unit-tested)

    /// "Email · Investor · Pitch · Work — jane@company.com", omitting any
    /// unset dimension, and "All writing" when neither a register dimension
    /// nor a persona is selected. A selected persona is appended as another
    /// " · "-joined part (its name when it has one, otherwise its handle
    /// stands in directly); a *named* persona additionally gets its handle
    /// suffixed after an em dash, since the persona name alone can be
    /// ambiguous (several accounts can share one, e.g. "Work" × 4) — mirrors
    /// `RegisterControls.personaLabel(for:)`.
    @MainActor
    static func describeRegister(medium: String?, audience: String?, mode: String?,
                                  persona: AccountSummary?) -> String {
        var parts: [String] = []
        if let medium { parts.append(KindLabels.medium(medium)) }
        if let audience { parts.append(AudiencesTab.bucketLabel(audience)) }
        if let mode { parts.append(KindLabels.mode(mode)) }

        guard let persona else {
            return parts.isEmpty ? Localization.shared.t(.vpAllWriting) : parts.joined(separator: " · ")
        }
        if let personaName = persona.persona {
            parts.append(personaName)
            return parts.joined(separator: " · ") + " — " + persona.handle
        }
        parts.append(persona.handle)
        return parts.joined(separator: " · ")
    }

    @MainActor
    static func itemCountText(_ count: Int) -> String {
        count == 1 ? Localization.shared.t(.vpItemCountOne)
                   : Localization.shared.t(.vpItemCountMany, count)
    }

    @MainActor
    static func thinProfileWarning(itemCount: Int) -> String {
        Localization.shared.t(.vpThinProfile, itemCount)
    }

    /// "12 ± 4 words" — mean sentence length with its standard deviation,
    /// both rounded to whole words.
    @MainActor
    static func sentenceLengthText(meanSentenceLen: Double, sentenceLenSD: Double) -> String {
        Localization.shared.t(.vpSentenceLength,
                              Int(meanSentenceLen.rounded()), Int(sentenceLenSD.rounded()))
    }

    /// Bucket + percentage for a contraction rate, e.g. ("occasional",
    /// "9%") — the bucket reuses `StyleProfile.contractionBucket(forRate:)`
    /// so it can never disagree with what `promptBlock()` tells the model.
    static func contractionText(rate: Double) -> (bucket: String, percent: String) {
        let bucket = StyleProfile.contractionBucket(forRate: rate)
        let percent = Int((rate * 100).rounded())
        return (bucket, "\(percent)%")
    }

    static func perThousandText(_ value: Double) -> String {
        "\(Int(value.rounded()))/1k"
    }

    /// Clips `text` to `length` characters (trimmed of surrounding
    /// whitespace/newlines first), appending an ellipsis when it was
    /// actually cut down. `excerptLength` is the sidebar-era default; the
    /// full-page view passes a longer `excerptChars`.
    static let excerptLength = 200

    static func excerpt(_ text: String, length: Int = excerptLength) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > length else { return trimmed }
        return String(trimmed.prefix(length)) + "\u{2026}"
    }
}

/// Minimal left-to-right wrapping layout for phrase chips — no external
/// dependency, just enough to flow chips onto multiple lines within the
/// available width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + spacing + size.width > maxWidth {
                totalHeight += lineHeight + spacing
                totalWidth = max(totalWidth, lineWidth)
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += (lineWidth > 0 ? spacing : 0) + size.width
            lineHeight = max(lineHeight, size.height)
        }
        totalHeight += lineHeight
        totalWidth = max(totalWidth, lineWidth)
        return CGSize(width: maxWidth.isFinite ? maxWidth : totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
