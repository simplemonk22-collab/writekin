import SwiftUI

/// Audiences: assign each top recipient handle to an intimacy bucket
/// (family/friend/self/work/investor/cold — matching the seeded `audiences`
/// order), then backfill `items.audience` corpus-wide from those
/// assignments via ``AudienceAdmin``.
///
/// Assignment: click a row to focus it, then press 1–6 (matching the bucket
/// order above) or 0/Delete to clear — chosen over per-row buttons because
/// the list can run to 150 rows and a keyboard flow is far faster to
/// triage than mousing a segmented control each time. The segmented control
/// remains as the mouse-driven equivalent for anyone who prefers it (or
/// isn't focus-driving the list).
///
/// Purely presentational — domain state and actions live in
/// ``AudiencesModel``. The view owns only interaction ephemera (list
/// selection, search text, scope, focus, transient dialogs) and mutates
/// selection around model calls (clear after linking, subtract after
/// ignoring) so those semantics stay visible at the call site.
/// Which subset of recipients the table shows — mouse-driven equivalent of
/// typing "@" in the search field, and a quick way to get emails (which tend
/// to dominate a mixed mail+iMessage corpus) out of the way while triaging
/// display names, or vice versa.
enum RecipientScope: String, CaseIterable, Identifiable {
    case all, people, addresses

    var id: String { rawValue }

    /// Localization key for the segment's label — a key (not a translated
    /// string) because this enum is nonisolated and must not touch the
    /// @MainActor `Localization`; the view translates at render time.
    var titleKey: L10nKey {
        switch self {
        case .all: .brAll
        case .people: .audScopePeople
        case .addresses: .audScopeAddresses
        }
    }
}

@MainActor
struct AudiencesTab: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: AudiencesModel?
    @State private var selection = Set<String>()
    @State private var showBucketHelp = false
    @State private var searchText = ""
    @State private var scope: RecipientScope = .all
    @State private var showIgnored = false
    @State private var linkCanonicalPicker: [String]?
    @State private var linkToPersonTarget: LinkToPersonTarget?
    @State private var linkToPersonSearch = ""
    @State private var linkToPersonSelectedHandle: String?
    @FocusState private var focusedHandle: String?

    /// Identifies which row opened "Link to Person…" (`id` is that row's
    /// handle), presented via `sheet(item:)` like the other link sheets in
    /// this file.
    private struct LinkToPersonTarget: Identifiable {
        let id: String
    }

    static let buckets = AudienceAdmin.intimacyOrder

    /// Display label for a bucket. Buckets are STORED as the raw seeded
    /// `audiences` values ("family", "friend", …) — keyboard assignment,
    /// backfill, and training conditioning all key off them — but DISPLAY
    /// in the current language. Unknown values fall back to capitalized raw.
    static func bucketLabel(_ bucket: String) -> String {
        let loc = Localization.shared
        return switch bucket {
        case "family": loc.t(.bucketFamily)
        case "friend": loc.t(.bucketFriend)
        case "self": loc.t(.bucketSelf)
        case "work": loc.t(.bucketWork)
        case "investor": loc.t(.bucketInvestor)
        case "cold": loc.t(.bucketCold)
        default: bucket.capitalized
        }
    }

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
                model = AudiencesModel(db: env.database, settings: env.settings)
            }
            await model?.refresh()
        }
        .onDisappear { model?.backfillOnDisappearIfNeeded() }
    }

    private func filteredRecipients(_ model: AudiencesModel) -> [RecipientSummary] {
        AudiencesModel.filter(model.recipients, scope: scope, search: searchText,
                              showIgnored: showIgnored, ignored: model.ignoredHandles)
    }

    @ViewBuilder
    private func content(_ model: AudiencesModel) -> some View {
        @Bindable var model = model
        let filtered = filteredRecipients(model)
        VStack(alignment: .leading, spacing: 8) {
            header(model)
            searchAndScopeBar(filtered)
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20)
            }
            if !selection.isEmpty {
                bulkAssignBar(model)
            }
            if !model.suggestedLinks.isEmpty {
                suggestedLinksBanner(model)
            }
            Divider()
            if model.recipients.isEmpty {
                ContentUnavailableView(
                    loc.t(.audEmptyTitle),
                    systemImage: "person.3",
                    description: Text(loc.t(.audEmptyDesc)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(model, filtered: filtered)
                if !model.ignoredHandles.isEmpty {
                    ignoredFooter(model)
                }
            }
        }
        .confirmationDialog(loc.t(.audLinkSamePersonTitle),
                             isPresented: Binding(
                                get: { linkCanonicalPicker != nil },
                                set: { if !$0 { linkCanonicalPicker = nil } }),
                             presenting: linkCanonicalPicker) { handles in
            ForEach(handles, id: \.self) { handle in
                Button(loc.t(.audUseAsKeep, model.displayCasing(for: handle))) {
                    Task { await linkAsSamePerson(model, handles, canonical: handle) }
                }
            }
            Button(loc.t(.cancel), role: .cancel) {}
        } message: { _ in
            Text(loc.t(.audLinkDialogMsg))
        }
        .sheet(item: $model.linkReviewPlan) { plan in
            linkReviewSheet(model, plan: plan)
        }
        .sheet(item: $linkToPersonTarget) { target in
            linkToPersonSheet(model, target: target)
        }
    }

    // MARK: - Selection-aware wrappers
    // Selection is view state; these preserve the exact semantics the
    // pre-model code had (clear after linking, subtract after ignoring,
    // untouched after bulk assignment).

    private func linkAsSamePerson(_ model: AudiencesModel,
                                  _ handles: [String], canonical: String) async {
        await model.linkAsSamePerson(handles, canonical: canonical)
        selection.removeAll()
    }

    private func setIgnored(_ model: AudiencesModel,
                            _ ignored: Bool, handles: Set<String>) async {
        await model.setIgnored(ignored, handles: handles)
        selection.subtract(handles)
    }

    // MARK: - Header + bars

    private func header(_ model: AudiencesModel) -> some View {
        // Captions in their own full-width column, controls in a trailing
        // column — sharing a single HStack row squeezed the first caption
        // against the Apply button, wrapping it to two lines and making
        // Audiences' header visibly taller than Accounts'.
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                ScreenCaption(text: loc.t(.audCaption1))
                HStack(spacing: 6) {
                    ScreenCaption(text: loc.t(.audCaption2))
                    Button {
                        showBucketHelp.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .popover(isPresented: $showBucketHelp, arrowEdge: .bottom) {
                        bucketHelp
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if model.isBackfilling {
                    ProgressView().controlSize(.small)
                    if let backfillProgress = model.backfillProgress {
                        Text(loc.t(.audNUpdated, String(backfillProgress)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button(loc.t(.audApplyToCorpus)) {
                    Task { await model.applyBackfill() }
                }
                .disabled(model.isBackfilling)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    /// Buckets are writing registers, not an org chart — this is the one
    /// place that says so out loud.
    private var bucketHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc.t(.audBucketHelpTitle)).font(.headline)
            Group {
                bucketHelpLine(Self.bucketLabel("family"), loc.t(.audHelpFamily))
                bucketHelpLine(Self.bucketLabel("friend"), loc.t(.audHelpFriend))
                bucketHelpLine(Self.bucketLabel("self"), loc.t(.audHelpSelf))
                bucketHelpLine(Self.bucketLabel("work"), loc.t(.audHelpWork))
                bucketHelpLine(Self.bucketLabel("investor"), loc.t(.audHelpInvestor))
                bucketHelpLine(Self.bucketLabel("cold"), loc.t(.audHelpCold))
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 340)
    }

    private func bucketHelpLine(_ name: String, _ description: String) -> some View {
        Text(name).bold() + Text(" — " + description)
    }

    /// Mirrors `AccountsTab.ignoredFooter`: count of currently-ignored
    /// recipient handles plus a Show/Hide toggle for the ignore filter.
    private func ignoredFooter(_ model: AudiencesModel) -> some View {
        HStack {
            Text(loc.t(.audNIgnored, String(model.ignoredHandles.count)))
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

    private func searchAndScopeBar(_ filtered: [RecipientSummary]) -> some View {
        HStack(spacing: 12) {
            Picker(loc.t(.audScope), selection: $scope) {
                ForEach(RecipientScope.allCases) { scope in
                    Text(loc.t(scope.titleKey)).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            Button(selection.count == filtered.count && !selection.isEmpty
                   ? loc.t(.audDeselectAll) : loc.t(.audSelectAll)) {
                if selection.count == filtered.count && !selection.isEmpty {
                    selection.removeAll()
                } else {
                    selection = Set(filtered.map(\.handle))
                }
            }
            .disabled(filtered.isEmpty)
            .help(loc.t(.audSelectAllHelp))

            TextField(loc.t(.audSearchPrompt), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)

            if !searchText.isEmpty {
                Button(loc.t(.audClear)) { searchText = "" }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
    }

    /// Appears whenever the selection is non-empty: the mouse-driven
    /// equivalent of the 1–6 keyboard shortcuts, since the per-row `Picker`
    /// that used to offer this was removed (it silently swallowed row clicks
    /// before `List(selection:)` ever saw them, breaking multi-select
    /// entirely).
    private func bulkAssignBar(_ model: AudiencesModel) -> some View {
        HStack {
            Text(loc.t(.audNSelected, String(selection.count))).font(.subheadline)
            Spacer()
            ForEach(Self.buckets, id: \.self) { bucket in
                Button(Self.bucketLabel(bucket)) {
                    Task { await model.bulkAssign(bucket, handles: selection) }
                }
            }
            Button(loc.t(.audClear)) {
                Task { await model.bulkAssign(nil, handles: selection) }
            }
            Divider().frame(height: 16)
            Button(loc.t(.audIgnore)) {
                Task { await setIgnored(model, true, handles: selection) }
            }
            Button(loc.t(.audDeselect)) { selection.removeAll() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    /// "Same person" suggestions from ``LinkSuggester``: a duplicate-style
    /// banner (mirroring `AccountsTab`'s merge-duplicates banner) rather than
    /// an always-expanded inline section, since these are a one-time triage
    /// task rather than an ongoing view. "Review…" opens `linkReviewSheet`
    /// with a FRESH fetch of suggestions (see `AudiencesModel.openLinkReview`)
    /// so a suggestion dismissed or linked elsewhere since this tab last
    /// refreshed can't show up as a stale row.
    private func suggestedLinksBanner(_ model: AudiencesModel) -> some View {
        HStack {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.blue)
            Text(model.suggestedLinks.count == 1
                 ? loc.t(.audLinksFoundOne)
                 : loc.t(.audLinksFoundMany, String(model.suggestedLinks.count)))
                .font(.subheadline)
            Spacer()
            Button(model.suggestedLinks.count == 1
                   ? loc.t(.audReviewLinksOne)
                   : loc.t(.audReviewLinksMany, String(model.suggestedLinks.count))) {
                Task { await model.openLinkReview() }
            }
            .disabled(model.isOpeningLinkReview)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: - Link review sheet

    /// One row per suggestion: toggle, "name ↔ email" with a confidence dot,
    /// and a per-row "Dismiss" that persists immediately and removes the row
    /// from the still-open sheet (rather than requiring "Cancel"/reopen).
    private func linkReviewSheet(_ model: AudiencesModel,
                                 plan: AudiencesModel.LinkReviewPlan) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            Text(loc.t(.audLinkExplainer))
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.suggestions) { suggestion in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { model.linkToggle[suggestion.id] ?? (suggestion.confidence >= 0.9) },
                                set: { model.linkToggle[suggestion.id] = $0 }
                            ))
                            .labelsHidden()
                            Circle()
                                .fill(confidenceColor(suggestion.confidence))
                                .frame(width: 8, height: 8)
                            Text("\(model.displayCasing(for: suggestion.nameHandle)) ↔ \(model.displayCasing(for: suggestion.emailHandle))")
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(loc.t(.audDismiss)) {
                                Task { await model.dismissLinkInReview(suggestion) }
                            }
                            .buttonStyle(.plain)
                            .controlSize(.small)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)

            HStack {
                Spacer()
                Button(loc.t(.cancel), role: .cancel) {
                    model.linkReviewPlan = nil
                }
                Button(loc.t(.audLinkSelectedCount, String(model.selectedLinkCount(plan)))) {
                    model.linkReviewPlan = nil
                    Task {
                        await model.linkSelectedSuggestions(plan.suggestions)
                        selection.removeAll()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedLinkCount(plan) == 0)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 320)
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.9 { return .green }
        if confidence >= 0.75 { return .yellow }
        return .orange
    }

    // MARK: - List

    private func list(_ model: AudiencesModel, filtered: [RecipientSummary]) -> some View {
        List(selection: $selection) {
            HStack {
                Text("").frame(width: 20)
                Text(loc.t(.audColHandle)).frame(width: 260, alignment: .leading)
                Text(loc.t(.audColKept)).frame(width: 60, alignment: .trailing)
                Text(loc.t(.audColAudience)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(filtered) { recipient in
                row(recipient)
                    .tag(recipient.handle)
                    .contextMenu {
                        rowContextMenu(model, recipient: recipient)
                    }
            }
        }
        .listStyle(.inset)
        .onKeyPress { keyPress in
            guard let digit = keyPress.characters.first?.wholeNumberValue,
                  (0...Self.buckets.count).contains(digit) else { return .ignored }
            let targets = selection.isEmpty ? Set([focusedHandle].compactMap { $0 }) : selection
            guard !targets.isEmpty else { return .ignored }
            let bucket = digit == 0 ? nil : Self.buckets[digit - 1]
            Task { await model.bulkAssign(bucket, handles: targets) }
            return .handled
        }
    }

    @ViewBuilder
    private func rowContextMenu(_ model: AudiencesModel,
                                recipient: RecipientSummary) -> some View {
        let targets = selection.contains(recipient.handle) ? selection : [recipient.handle]
        Menu(targets.count > 1
             ? loc.t(.audAssignToSelected)
             : loc.t(.audAssignTo, recipient.displayName)) {
            ForEach(Self.buckets, id: \.self) { bucket in
                Button(Self.bucketLabel(bucket)) {
                    Task { await model.bulkAssign(bucket, handles: Set(targets)) }
                }
            }
            Button(loc.t(.audNone)) {
                Task { await model.bulkAssign(nil, handles: Set(targets)) }
            }
        }
        if targets.count >= 2 {
            Button(loc.t(.audLinkSamePersonEllipsis)) {
                linkCanonicalPicker = Array(targets).sorted()
            }
        }
        Button(loc.t(.audLinkToPersonEllipsis)) {
            linkToPersonSearch = ""
            linkToPersonSelectedHandle = nil
            linkToPersonTarget = LinkToPersonTarget(id: recipient.handle)
        }
        if model.ignoredHandles.contains(recipient.handle) {
            Button(loc.t(.audUnignore)) {
                Task { await setIgnored(model, false, handles: Set(targets)) }
            }
        } else {
            Button(loc.t(.audIgnore)) {
                Task { await setIgnored(model, true, handles: Set(targets)) }
            }
        }
    }

    /// "Link to Person…" sheet: a search-filtered candidate list (filtering
    /// over BOTH handle and displayName, so searching "user42" still surfaces
    /// "user42@…" once it's already linked to display as "Robin Doe", and
    /// searching "user42" still surfaces a not-yet-linked "Robin Doe" row)
    /// with click-to-select and a confirm "Link" button -- the fix for not
    /// being able to find a mismatched name/address pair via the top-level
    /// search field, which filters the same handle+displayName text but
    /// can't show both a name row and an unrelated-looking email row at once
    /// unless the query happens to match both.
    private func linkToPersonSheet(_ model: AudiencesModel,
                                   target: LinkToPersonTarget) -> some View {
        let targetName = model.displayCasing(for: target.id)
        let candidates = model.recipients.filter { $0.handle != target.id }.filter { recipient in
            guard !linkToPersonSearch.isEmpty else { return true }
            let needle = AudiencesModel.foldForSearch(linkToPersonSearch)
            return AudiencesModel.foldForSearch(recipient.handle).contains(needle)
                || AudiencesModel.foldForSearch(recipient.displayName).contains(needle)
        }

        return VStack(alignment: .leading, spacing: 12) {
            Text(loc.t(.audLinkToPersonMsg, targetName))
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField(loc.t(.audSearchPrompt), text: $linkToPersonSearch)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(candidates) { candidate in
                        let isSelected = linkToPersonSelectedHandle == candidate.handle
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.displayName)
                                Text(candidate.handle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .onTapGesture { linkToPersonSelectedHandle = candidate.handle }
                    }
                }
            }
            .frame(maxHeight: 280)

            HStack {
                Spacer()
                Button(loc.t(.cancel), role: .cancel) {
                    linkToPersonTarget = nil
                }
                Button(loc.t(.audLink)) {
                    let selected = linkToPersonSelectedHandle
                    linkToPersonTarget = nil
                    guard let selected else { return }
                    let canonical = AudiencesModel.canonicalHandle(target.id, selected)
                    Task { await linkAsSamePerson(model, [target.id, selected], canonical: canonical) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(linkToPersonSelectedHandle == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private func row(_ recipient: RecipientSummary) -> some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { selection.contains(recipient.handle) },
                set: { isOn in
                    if isOn { selection.insert(recipient.handle) }
                    else { selection.remove(recipient.handle) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 0) {
                Text(recipient.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !recipient.linkedHandles.isEmpty {
                    Text(loc.t(.audLinkedList, recipient.linkedHandles.joined(separator: ", ")))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(width: 260, alignment: .leading)
            Text("\(recipient.keptCount)")
                .frame(width: 60, alignment: .trailing)
                .monospacedDigit()
            audienceBadge(recipient.audience)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .focused($focusedHandle, equals: recipient.handle)
        // No tap gesture here: it would swallow shift/cmd-clicks and break
        // the List's native range selection. Clicking selects natively, and
        // the 1–6 keys act on the selection.
    }

    /// Read-only badge showing the current assignment — assignment itself
    /// now happens only via keyboard (1–6), the bulk-assignment bar, or the
    /// row's context menu, never by clicking here (a per-row `Picker` used
    /// to live in this spot and silently ate the clicks `List(selection:)`
    /// needed for multi-select).
    @ViewBuilder
    private func audienceBadge(_ audience: String?) -> some View {
        if let audience {
            Text(Self.bucketLabel(audience))
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}
