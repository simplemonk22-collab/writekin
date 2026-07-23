import SwiftUI

/// Table-style list of accounts with kept-item counts and date spans, an
/// inline-editable persona label, and a multi-select "merge duplicates"
/// flow. Disabled while an ingest run is in flight since a run may create or
/// update accounts underneath the list.
///
/// Purely presentational — domain state and actions live in
/// ``AccountsModel``. The view owns only interaction ephemera (list
/// selection, the custom-persona field set, focus, sheet targets and their
/// checkboxes) and mutates those around model calls so the semantics stay
/// visible at the call sites.
///
/// Explicitly `@MainActor` (mirroring `ComposeView`) rather than relying on
/// `View.body`'s implicit main-actor isolation to cover the whole type:
/// row actions live in plain instance methods reached through
/// `Task { await … }` closures built OUTSIDE `body`, which are not
/// automatically main-actor-isolated just because the type conforms to
/// `View`. Without this, those `Task`s can resume off the main actor and
/// their `@State` writes land off-thread — SwiftUI does not reliably
/// schedule a re-render for that (the root cause of "Ignore appears to do
/// nothing").
@MainActor
struct AccountsTab: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: AccountsModel?
    @State private var selection = Set<Int64>()
    @State private var showIgnored = false
    @State private var customPersonaFieldFor = Set<Int64>()
    @State private var ignoreConfirm: IgnoreConfirmTarget?
    @State private var excludeFromCorpusChecked = false
    @State private var unignoreRestoreConfirm: UnignoreRestoreTarget?
    @State private var restoreExcludedChecked = false
    @State private var showPersonaHelp = false
    @FocusState private var focusedAccountID: Int64?

    /// The "Ignore" confirm sheet's target: an account plus its current kept
    /// count, so the sheet can offer "Also exclude its N items from the
    /// corpus" — for non-user mail (e.g. `autocreate@dreamhost.com`, a
    /// server artifact that landed in a Sent folder) that shouldn't just be
    /// hidden from this list but actually dropped from the corpus.
    private struct IgnoreConfirmTarget: Identifiable {
        let id: Int64
        let handle: String
        let keptCount: Int
    }

    /// The "Unignore" restore-offer sheet's target: an account plus how many
    /// of its items are currently excluded via `excludeFromCorpus`, so
    /// un-ignoring can offer to bring them back into the corpus.
    private struct UnignoreRestoreTarget: Identifiable {
        let id: Int64
        let handle: String
        let excludedCount: Int
    }

    /// Common persona presets offered from the per-account persona menu,
    /// ahead of "Custom…" (which reveals the free-text field) and "None"
    /// (which clears the persona).
    private static let commonPersonas = ["Personal", "Work", "Side project", "Old job", "School"]

    /// Display label for a persona value. Preset personas are STORED as
    /// their canonical English values (`commonPersonas`) — matching logic
    /// like `AudienceAdmin.audienceForPersona` and merge dedupe depend on
    /// them — but DISPLAY in the current language. Custom personas show
    /// exactly as typed.
    static func personaLabel(_ persona: String) -> String {
        let loc = Localization.shared
        return switch persona {
        case "Personal": loc.t(.personaPersonal)
        case "Work": loc.t(.personaWork)
        case "Side project": loc.t(.personaSideProject)
        case "Old job": loc.t(.personaOldJob)
        case "School": loc.t(.personaSchool)
        default: persona
        }
    }

    private var ingestRunning: Bool { env.ingest.isRunning }
    private var loc: Localization { Localization.shared }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if model == nil {
                model = AccountsModel(db: env.database, settings: env.settings)
            }
            await model?.refresh()
        }
        .onChange(of: ingestRunning) { _, running in
            if !running { Task { await model?.refresh() } }
        }
    }

    @ViewBuilder
    private func content(_ model: AccountsModel) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            header
            if !model.activeSuggestedGroups.isEmpty {
                duplicateBanner(model)
            }
            if ingestRunning {
                Text(loc.t(.paIngestLock))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20)
            }
            Divider()
            if model.summaries.isEmpty {
                ContentUnavailableView(
                    loc.t(.paEmptyTitle),
                    systemImage: "person.crop.circle",
                    description: Text(loc.t(.paEmptyDesc)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table(model)
                if !model.ignoredIDs.isEmpty {
                    ignoredFooter(model)
                }
            }
        }
        .sheet(item: $model.mergeReviewPlan) { plan in
            mergeReviewSheet(model, rows: plan.rows)
        }
        .sheet(item: $ignoreConfirm) { target in
            ignoreConfirmSheet(model, target: target)
        }
        .sheet(item: $unignoreRestoreConfirm) { target in
            unignoreRestoreSheet(model, target: target)
        }
    }

    // MARK: - Selection/edit-state wrappers
    // Preserve the pre-model semantics: merges clear the list selection,
    // persona commits close that row's custom field.

    private func merge(_ model: AccountsModel, sources: [Int64], into target: Int64) async {
        await model.merge(sources: sources, into: target)
        selection.removeAll()
    }

    private func setPersona(_ model: AccountsModel, _ persona: String?,
                            accountID: Int64) async {
        await model.setPersona(persona, accountID: accountID)
        customPersonaFieldFor.remove(accountID)
    }

    private func commitPersona(_ model: AccountsModel, accountID: Int64) async {
        await model.commitPersona(accountID: accountID)
        customPersonaFieldFor.remove(accountID)
    }

    /// "Unignore" entry point: if the account has any corpus-excluded items
    /// (from a prior "Also exclude its N items…"), routes through
    /// `unignoreRestoreSheet` to offer restoring them; otherwise just clears
    /// the ignored flag directly, matching the old one-click behavior.
    private func beginUnignore(_ model: AccountsModel, _ summary: AccountSummary) async {
        guard let excludedCount = await model.excludedFromCorpusCount(accountID: summary.id)
        else { return }
        guard excludedCount > 0 else {
            await model.setIgnored(false, accountID: summary.id)
            return
        }
        restoreExcludedChecked = true
        unignoreRestoreConfirm = UnignoreRestoreTarget(id: summary.id, handle: summary.handle,
                                                       excludedCount: excludedCount)
    }

    // MARK: - Sheets

    /// "Ignore" confirmation: names the target handle and, when it has any
    /// kept items, offers "Also exclude its N items from the corpus" — the
    /// corpus-purity escape hatch for non-user mail (server artifacts,
    /// autoresponder addresses) that landed in a Sent folder under `From`.
    private func ignoreConfirmSheet(_ model: AccountsModel,
                                    target: IgnoreConfirmTarget) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc.t(.paIgnoreTitle, target.handle)).font(.headline)
            if target.keptCount > 0 {
                Toggle(isOn: $excludeFromCorpusChecked) {
                    Text(target.keptCount == 1
                         ? loc.t(.paAlsoExcludeOne)
                         : loc.t(.paAlsoExcludeMany, String(target.keptCount)))
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button(loc.t(.cancel), role: .cancel) { ignoreConfirm = nil }
                Button(loc.t(.paIgnore)) {
                    let accountID = target.id
                    let exclude = excludeFromCorpusChecked
                    ignoreConfirm = nil
                    Task { await model.confirmIgnore(accountID: accountID,
                                                     excludeFromCorpus: exclude) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    /// "Unignore" restore offer, shown only when the account has items
    /// previously excluded via "Also exclude its N items from the corpus" —
    /// lets restoring visibility also restore the corpus data if that's what
    /// was wanted.
    private func unignoreRestoreSheet(_ model: AccountsModel,
                                      target: UnignoreRestoreTarget) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc.t(.paUnignoreTitle, target.handle)).font(.headline)
            Toggle(isOn: $restoreExcludedChecked) {
                Text(target.excludedCount == 1
                     ? loc.t(.paAlsoRestoreOne)
                     : loc.t(.paAlsoRestoreMany, String(target.excludedCount)))
            }
            .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button(loc.t(.cancel), role: .cancel) { unignoreRestoreConfirm = nil }
                Button(loc.t(.paUnignore)) {
                    let accountID = target.id
                    let restore = restoreExcludedChecked
                    unignoreRestoreConfirm = nil
                    Task { await model.confirmUnignore(accountID: accountID, restore: restore) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    /// The "Review N suggested merges…" flow's confirmation surface: one
    /// toggleable row per suggested-duplicate group (all on by default) so
    /// individual groups can be excluded before anything merges, plus any
    /// persona-conflict notes so the user can see what wins before it
    /// happens.
    private func mergeReviewSheet(_ model: AccountsModel,
                                  rows: [AccountsModel.MergeGroupRow]) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            Text(loc.t(.paMergeExplainer))
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Toggle("", isOn: Binding(
                                get: { model.groupIncluded[row.id] ?? true },
                                set: { model.groupIncluded[row.id] = $0 }
                            ))
                            .labelsHidden()
                            (Text(row.sourceHandles.joined(separator: ", "))
                             + Text(" → ")
                             + Text(row.targetHandle).bold())
                                .font(.callout)
                        }
                        if let conflict = model.pendingPersonaConflicts
                            .first(where: { $0.targetHandle == row.targetHandle }) {
                            let winning = conflict.winningPersona ?? loc.t(.paNoPersona)
                            let discarded = conflict.discardedPersonas.joined(separator: ", ")
                            Text(loc.t(.paKeepsPersona, winning, discarded))
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .padding(.leading, 24)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)

            HStack {
                Spacer()
                Button(loc.t(.cancel), role: .cancel) {
                    model.mergeReviewPlan = nil
                    model.clearPendingConflicts()
                }
                Button(loc.t(.paMergeSelectedCount, String(model.selectedReviewCount(rows)))) {
                    model.mergeReviewPlan = nil
                    Task {
                        await model.mergeSuggested()
                        selection.removeAll()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedReviewCount(rows) == 0)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 320)
    }

    // MARK: - Header, banner, footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            ScreenCaption(text: loc.t(.paCaption1))
            ScreenCaption(text: loc.t(.paCaption2))
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    /// One-liners behind the Persona column's "?" help popover — the same
    /// presets offered from `personaControl`'s menu, explained so "which
    /// bucket is this" doesn't require guessing. Ends with the standing
    /// guidance that personas are Compose voice controls, not a filing
    /// system, so eras should only split when the voice actually differs.
    private var personaHelpContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                personaHelpLine(Self.personaLabel("Personal"), loc.t(.paHelpPersonal))
                personaHelpLine(Self.personaLabel("Work"), loc.t(.paHelpWork))
                personaHelpLine(Self.personaLabel("Old job"), loc.t(.paHelpOldJob))
                personaHelpLine(Self.personaLabel("Side project"), loc.t(.paHelpSideProject))
                personaHelpLine(Self.personaLabel("School"), loc.t(.paHelpSchool))
            }
            Divider()
            Text(loc.t(.paPersonaHelpFooter))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private func personaHelpLine(_ name: String, _ description: String) -> some View {
        (Text(name).bold() + Text(" — " + description))
            .font(.callout)
    }

    private func duplicateBanner(_ model: AccountsModel) -> some View {
        let plan = model.bannerPlanRows
        let duplicateCount = model.activeSuggestedGroups.reduce(0) { $0 + $1.count - 1 }
        return HStack {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text(duplicateCount == 1
                 ? loc.t(.paDupFoundOne)
                 : loc.t(.paDupFoundMany, String(duplicateCount)))
                .font(.subheadline)
            Spacer()
            Button(plan.count == 1
                   ? loc.t(.paReviewMergesOne)
                   : loc.t(.paReviewMergesMany, String(plan.count))) {
                Task { await model.openMergeReview() }
            }
            .disabled(model.isMergingSuggested || ingestRunning
                      || model.isOpeningMergeReview || plan.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.1))
    }

    private func ignoredFooter(_ model: AccountsModel) -> some View {
        HStack {
            let ignoredCount = model.summaries.filter { model.ignoredIDs.contains($0.id) }.count
            Text(loc.t(.paNIgnored, String(ignoredCount)))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(showIgnored ? loc.t(.paHide) : loc.t(.paShow)) {
                showIgnored.toggle()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
    }

    // MARK: - Table

    private func table(_ model: AccountsModel) -> some View {
        List(selection: $selection) {
            HStack {
                Text(loc.t(.paColHandle)).frame(width: 220, alignment: .leading)
                HStack(spacing: 3) {
                    Text(loc.t(.paColPersona))
                    Button {
                        showPersonaHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .popover(isPresented: $showPersonaHelp) {
                        personaHelpContent
                    }
                }
                .frame(width: 180, alignment: .leading)
                Text(loc.t(.paColKept)).frame(width: 60, alignment: .trailing)
                Text(loc.t(.paColDateRange)).frame(maxWidth: .infinity, alignment: .leading)
                Text("").frame(width: 32, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(model.visibleSummaries(showIgnored: showIgnored)) { summary in
                accountRow(model, summary)
                    .tag(summary.id)
                    .contextMenu {
                        mergeMenu(model, target: summary)
                    }
            }
        }
        .listStyle(.inset)
        .disabled(ingestRunning)
    }

    @ViewBuilder
    private func accountRow(_ model: AccountsModel, _ summary: AccountSummary) -> some View {
        let ignored = model.ignoredIDs.contains(summary.id)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.handle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(ignored ? .secondary : .primary)
                if AccountAdmin.isServerArtifact(summary.handle) {
                    Text(ignored ? loc.t(.paServerArtifactIgnored) : loc.t(.paServerArtifact))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 220, alignment: .leading)
            personaControl(model, summary)
                .frame(width: 180, alignment: .leading)
            Text("\(summary.keptCount)")
                .frame(width: 60, alignment: .trailing)
                .monospacedDigit()
            Text(dateRangeText(summary.span))
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.secondary)
            rowActions(model, summary, ignored: ignored)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    /// Trailing controls for a row: a single compact ellipsis menu (instead
    /// of a column of per-row buttons, which didn't scale once "Merge
    /// Into…" and "Ignore"/"Unignore" both needed to live somewhere)
    /// offering "Merge Into…" (every other account, as a submenu) and
    /// "Ignore"/"Unignore". Multi-select "Merge Selected Into…" remains in
    /// the row's right-click context menu (`mergeMenu`), unchanged.
    ///
    /// `.menuIndicator(.hidden)` suppresses the disclosure chevron SwiftUI
    /// draws next to a `Menu`'s label by default — without it, the row
    /// showed both the ellipsis icon AND that system-drawn chevron, reading
    /// as two separate controls (a leftover from before this collapsed down
    /// to one menu).
    @ViewBuilder
    private func rowActions(_ model: AccountsModel, _ summary: AccountSummary,
                            ignored: Bool) -> some View {
        Menu {
            Menu(loc.t(.paMergeInto)) {
                ForEach(model.otherSummaries(excluding: summary.id)) { candidate in
                    Button(candidate.handle) {
                        Task { await merge(model, sources: [summary.id], into: candidate.id) }
                    }
                }
            }
            if ignored {
                Button(loc.t(.paUnignore)) {
                    Task { await beginUnignore(model, summary) }
                }
            } else {
                Button(loc.t(.paIgnoreEllipsis)) {
                    excludeFromCorpusChecked = false
                    ignoreConfirm = IgnoreConfirmTarget(id: summary.id, handle: summary.handle,
                                                        keptCount: summary.keptCount)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
    }

    @ViewBuilder
    private func mergeMenu(_ model: AccountsModel, target: AccountSummary) -> some View {
        let others = selection.subtracting([target.id])
        if !others.isEmpty {
            Button(loc.t(.paMergeSelectedInto, target.handle)) {
                Task { await merge(model, sources: Array(others), into: target.id) }
            }
        }
    }

    /// The persona cell for a row: a `Menu` offering `commonPersonas` plus
    /// "Custom…" (reveals the free-text field below) and "None" (clears the
    /// persona), replacing the old bare `TextField` affordance. A persona
    /// already set to something outside the preset list — or the custom
    /// field having been opened this session — keeps the text field
    /// visible/shows the raw value as the menu label, so nothing already
    /// saved appears to vanish.
    @ViewBuilder
    private func personaControl(_ model: AccountsModel, _ summary: AccountSummary) -> some View {
        @Bindable var model = model
        if customPersonaFieldFor.contains(summary.id) {
            TextField(loc.t(.paPersonaPlaceholder), text: Binding(
                get: { model.draftPersonas[summary.id] ?? "" },
                set: { model.draftPersonas[summary.id] = $0 }
            ))
                .textFieldStyle(.plain)
                .disabled(ingestRunning)
                .focused($focusedAccountID, equals: summary.id)
                .onSubmit {
                    Task { await commitPersona(model, accountID: summary.id) }
                }
                .onChange(of: focusedAccountID) { _, newFocused in
                    if newFocused != summary.id && focusedAccountID == nil {
                        Task { await commitPersona(model, accountID: summary.id) }
                    }
                }
        } else {
            Menu {
                ForEach(Self.commonPersonas, id: \.self) { option in
                    // Localized label; the canonical English value is stored.
                    Button(Self.personaLabel(option)) {
                        Task { await setPersona(model, option, accountID: summary.id) }
                    }
                }
                Divider()
                Button(loc.t(.paCustom)) {
                    customPersonaFieldFor.insert(summary.id)
                    focusedAccountID = summary.id
                }
                Button(loc.t(.paNone)) {
                    Task { await setPersona(model, nil, accountID: summary.id) }
                }
            } label: {
                let persona = summary.persona ?? ""
                Text(persona.isEmpty ? loc.t(.paSetPersona) : Self.personaLabel(persona))
                    .foregroundStyle(persona.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .disabled(ingestRunning)
        }
    }

    private func dateRangeText(_ span: ClosedRange<Date>?) -> String {
        guard let span else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "\(formatter.string(from: span.lowerBound)) – \(formatter.string(from: span.upperBound))"
    }
}
