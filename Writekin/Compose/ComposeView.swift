import AppKit
import SwiftUI

/// Compose: pick a register (persona/medium/audience/mode), write a draft,
/// and realize it into the author's voice via the on-device compose model.
/// Purely presentational — all state and actions live in `ComposeViewModel`.
struct ComposeView: View {
    /// Transient "Copied" feedback for the output pane's Copy button.
    @State private var justCopied = false
    @Environment(AppEnvironment.self) private var env
    @State private var model: ComposeViewModel?
    private var loc: Localization { .shared }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .task {
            if model == nil {
                model = ComposeViewModel(env: env)
            }
            await env.modelLibrary.refresh()
            // Runs + promotion state feed the Register row's trained-run
            // picker — loaded here so it works even when Compose is the
            // first tab visited this session.
            await env.train.refresh(db: env.database)
            await model?.loadPersonas()
            await model?.refreshAdapterNotice()
            await model?.refreshPendingCorrections()
        }
        .navigationTitle(MainSection.compose.title)
    }

    @ViewBuilder
    private func content(_ model: ComposeViewModel) -> some View {
        if model.installedComposeModel == nil {
            emptyState
        } else {
            @Bindable var model = model
            VStack(alignment: .leading, spacing: 12) {
                if let notice = model.adapterInactiveNotice {
                    // lineLimit + frame, NOT fixedSize(horizontal:false,
                    // vertical:true): wrapping text sized that way next to
                    // the sidebar's AppKit List retriggers a layout
                    // recursion that blanks the sidebar (first hit on the
                    // People tab, then again here).
                    Label(notice, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                registerControls(model)
                if let suggestion = model.registerSuggestion {
                    registerSuggestionBar(model, suggestion: suggestion)
                }
                // Mode picker + action button share one full-width row above
                // the split view: picker leading, button trailing — keeps
                // the Draft/Realized pane headers level with each other.
                HStack {
                    Picker(loc.t(.cpModeLabel), selection: $model.flowMode) {
                        ForEach(ComposeViewModel.Mode.allCases, id: \.self) { flowMode in
                            Text(loc.t(flowMode.labelKey)).tag(flowMode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)
                    if model.flowMode == .rewrite {
                        Picker(loc.t(.cpRewriteStyleLabel), selection: $model.rewriteStyle) {
                            Text(loc.t(.cpStyleAuto)).tag(RewriteStyle.auto)
                            Text(loc.t(.cpStyleOnePass)).tag(RewriteStyle.onePass)
                            Text(loc.t(.cpStyleSections)).tag(RewriteStyle.sections)
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        RewriteStyleInfoPopover()
                        // Auto changes behavior per draft — say WHICH way it
                        // resolved (and roughly why) so a bad result can be
                        // traced to a mode and overridden with the picker.
                        if model.rewriteStyle == .auto,
                           !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(Self.autoPathCaption(for: model.draft))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    realizeButton(model)
                }
                Divider()
                HSplitView {
                    // Breathing room on both sides of the split divider —
                    // without it the panes' text boxes butt directly against
                    // NSSplitView's hard divider line.
                    draftEditor(model)
                        .padding(.trailing, 12)
                    outputPane(model)
                        .padding(.leading, 12)
                }
                if case .error(let message) = model.phase {
                    errorBanner(message, model: model)
                }
            }
            .padding(16)
            // Draft-shape suggestion: debounced on typing, refreshed when a
            // register control changes (filling a field by hand narrows or
            // clears the pending suggestion immediately).
            .task(id: model.draft) {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                model.refreshRegisterSuggestion()
            }
            .onChange(of: model.medium) { _, _ in model.refreshRegisterSuggestion() }
            .onChange(of: model.mode) { _, _ in model.refreshRegisterSuggestion() }
            .onChange(of: model.flowMode) { _, _ in model.refreshRegisterSuggestion() }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(loc.t(.cpNoModelTitle))
                .font(.headline)
            Text(loc.t(.cpNoModelDesc))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(loc.t(.cpGoToModels)) {
                env.navigation.section = .models
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Register controls

    private func registerControls(_ model: ComposeViewModel) -> some View {
        @Bindable var model = model
        return RegisterControls(personaAccountID: $model.personaAccountID, medium: $model.medium,
                                 audience: $model.audience, mode: $model.mode,
                                 personas: model.personas) {
            runPicker(model)
        }
    }

    /// The draft-shape suggestion: same visual grammar as the merge banner
    /// and the next-run suggestion box — the machine has an opinion, the
    /// user has the button. Only ever offers to fill fields still on
    /// "Any"; dismiss suppresses this detection until the shape changes.
    private func registerSuggestionBar(_ model: ComposeViewModel,
                                       suggestion: RegisterDetector.Detection) -> some View {
        var parts: [String] = []
        if let medium = suggestion.medium {
            parts.append("\(loc.t(.brMedium)): \(KindLabels.medium(medium))")
        }
        if let mode = suggestion.mode {
            parts.append("\(loc.t(.cpModeLabel)): \(KindLabels.mode(mode))")
        }
        let reasonKey: L10nKey = switch suggestion.reason {
        case .markdownDocument: .cpSuggestReasonDoc
        case .emailShape: .cpSuggestReasonEmail
        case .chatShape: .cpSuggestReasonChat
        }
        return HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(Color.accentColor)
            Text(loc.t(.cpSuggestSet, loc.t(reasonKey), parts.joined(separator: ", ")))
                .font(.subheadline)
            Spacer()
            Button(loc.t(.trApply)) { model.applyRegisterSuggestion() }
            Button {
                model.dismissRegisterSuggestion()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The trained-run selector, right-aligned in the Register row — the
    /// same promote/demote as the Train tab's run cards, without the tab
    /// flip. The next realize resolves whatever is promoted, so switching
    /// here takes effect immediately.
    private func runPicker(_ model: ComposeViewModel) -> some View {
        let installedID = model.installedComposeModel?.id
        let eligible = env.train.runs.filter {
            $0.status == "succeeded" && $0.baseModel == installedID
        }
        return Picker(loc.t(.cpRunPickerLabel), selection: Binding<Int64?>(
            get: { env.train.promotedRunID },
            set: { newValue in
                Task {
                    if let newValue {
                        await env.train.promoteAdapter(db: env.database, runID: newValue)
                    } else {
                        await env.train.demoteAdapter(db: env.database)
                    }
                    await model.refreshAdapterNotice()
                }
            })) {
            Text(loc.t(.cpRunBaseOption)).tag(Int64?.none)
            ForEach(eligible, id: \.id) { run in
                Text(loc.t(.cpRunOption, String(run.id ?? 0))).tag(Int64?.some(run.id ?? 0))
            }
            // A promoted run trained on a DIFFERENT base stays selectable so
            // the picker never shows an empty selection — labeled honestly.
            if let promoted = env.train.promotedRunID,
               !eligible.contains(where: { $0.id == promoted }) {
                Text(loc.t(.cpRunInactiveOption, String(promoted))).tag(Int64?.some(promoted))
            }
        }
        .fixedSize()
        .help(loc.t(.cpRunPickerHelp))
    }

    /// "Auto → One pass — mixed content" etc.: the live resolution of the
    /// Auto rewrite style for the current draft, from the same
    /// `ComposeEngine.autoPath` the engine itself uses — the caption and
    /// the behavior cannot disagree.
    static func autoPathCaption(for draft: String) -> String {
        let loc = Localization.shared
        return switch ComposeEngine.autoPath(for: draft) {
        case .onePassShort: loc.t(.cpAutoOnePassShort)
        case .onePassStructured: loc.t(.cpAutoOnePassStructured)
        case .chunkedLongProse: loc.t(.cpAutoChunked)
        }
    }

    @ViewBuilder
    private func realizeButton(_ model: ComposeViewModel) -> some View {
        if model.isGenerating {
            // Long chunked rewrites can take a while — always offer a
            // visible way out. Cancellation lands at the next chunk
            // boundary; the partial streamed output stays.
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    // Ticks each second so the appended "about Ns left"
                    // counts down between engine events.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(model.generatingStatusText
                             + (model.etaSuffix(now: context.date) ?? ""))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Button(loc.t(.cpStop)) { model.cancelRealize() }
            }
        } else {
            Button {
                model.startRealize()
            } label: {
                Label(model.flowMode == .generate ? loc.t(.cpWrite) : loc.t(.cpRealize),
                      systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canRealize)
            .help(env.train.isBusy ? loc.t(.cpTrainBusyHelp) : "")
        }
    }

    // MARK: - Draft / output

    private func draftEditor(_ model: ComposeViewModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 6) {
            Text(loc.t(model.flowMode == .rewrite ? .cpDraftHeader : .cpInstructionHeader))
                .font(.headline)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.draft)
                    .font(.system(.body, design: .rounded))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                if model.draft.isEmpty {
                    Text(model.flowMode == .generate
                         ? loc.t(.cpGeneratePlaceholder)
                         : loc.t(.cpRewritePlaceholder, AppIdentity.appName))
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.secondary)
                        // Matches TextEditor's first-line origin (outer
                        // padding 8 + NSTextView's ~5pt container inset), so
                        // typed text replaces the placeholder in place
                        // instead of appearing slightly above it.
                        .padding(.horizontal, 13)
                        .padding(.vertical, 13)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(minWidth: 280)
    }

    private func outputPane(_ model: ComposeViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(loc.t(.cpRealizedHeader)).font(.headline)
                if model.fineTunedRunID != nil, model.selectedOutputTab == .fineTuned {
                    Text(loc.t(.cpFineTunedBadge))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                        .help(loc.t(.cpFineTunedBadgeHelp))
                }
                if model.rewriteUnchangedNotice {
                    Label(loc.t(.cpUnchangedNotice), systemImage: "equal.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(loc.t(.cpUnchangedNoticeHelp))
                }
                Spacer()
                if model.profileIsThin {
                    Text(loc.t(.cpThinProfileCaption))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !model.output.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.selectedOutputText, forType: .string)
                        justCopied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            justCopied = false
                        }
                    } label: {
                        Label(loc.t(justCopied ? .cpCopied : .cpCopy),
                              systemImage: justCopied ? "checkmark" : "doc.on.doc")
                    }
                    .controlSize(.small)
                    .help(loc.t(.cpCopyHelp))
                    if model.flowMode == .generate {
                        // No draft to diff against in generate mode — offer
                        // a fresh sample instead (temperature already gives
                        // variety run to run).
                        Button {
                            model.startRealize()
                        } label: {
                            Label(loc.t(.cpRegenerate), systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .disabled(!model.canRealize)
                        .help(loc.t(.cpRegenerateHelp))
                    } else {
                        Toggle(loc.t(.cpShowChanges), isOn: Binding(
                            get: { model.showDiff },
                            set: { model.showDiff = $0 }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        // Always present, but only meaningful (and enabled) while
                        // the diff is showing — a sub-option of "Show changes"
                        // rather than a control that pops in and out of the bar.
                        Toggle(loc.t(.cpRemovals), isOn: Binding(
                            get: { model.showRemovals },
                            set: { model.showRemovals = $0 }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!model.showDiff)
                            .help(loc.t(model.showDiff ? .cpRemovalsHelpOn : .cpRemovalsHelpOff))
                    }
                }
            }
            // The tab strip appears once a base version exists (or is on
            // its way), turning every realize into a labeled A/B.
            if model.fineTunedRunID != nil,
               model.isComparingBase || !model.baselineOutput.isEmpty {
                HStack(spacing: 8) {
                    Picker("", selection: Binding(
                        get: { model.selectedOutputTab },
                        set: { model.selectedOutputTab = $0 })) {
                        Text(loc.t(.cpFineTunedBadge)).tag(ComposeViewModel.OutputTab.fineTuned)
                        Text(loc.t(.cpTabBase)).tag(ComposeViewModel.OutputTab.base)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                    if model.isComparingBase, model.baselineOutput.isEmpty {
                        ProgressView().controlSize(.small)
                        Text(loc.t(.cpWritingBaseVersion))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            ScrollView {
                Group {
                    if model.selectedOutputTab == .base {
                        Text(model.baselineOutput.isEmpty
                             ? loc.t(.cpBaseStillWriting)
                             : model.baselineOutput)
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(model.baselineOutput.isEmpty ? .secondary : .primary)
                    } else if model.flowMode == .rewrite && model.showDiff {
                        diffText(model)
                    } else {
                        Text(model.output)
                            .font(.system(.body, design: .rounded))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            if model.selectedOutputTab == .base {
                if let check = model.baselineVoiceCheck, !model.baselineOutput.isEmpty {
                    HStack(spacing: 8) {
                        if model.flowMode == .rewrite, let draftCheck = model.draftVoiceCheck {
                            VoiceCheckChip(check: draftCheck, title: loc.t(.cpDraftHeader))
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        VoiceCheckChip(check: check, title: loc.t(.cpTabBase))
                        if let tuned = model.voiceCheck {
                            relativeCaption(mine: check, other: tuned,
                                            otherNameKey: .cpVsNameFineTuned)
                        }
                    }
                }
            } else if let check = model.voiceCheck, model.phase == .idle, !model.output.isEmpty {
                HStack(spacing: 8) {
                    if model.flowMode == .rewrite, let draftCheck = model.draftVoiceCheck {
                        VoiceCheckChip(check: draftCheck, title: loc.t(.cpDraftHeader))
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        VoiceCheckChip(check: check,
                                       title: loc.t(model.fineTunedRunID != nil
                                                    ? .cpFineTunedBadge : .cpRealizedHeader))
                        movementCaption(from: draftCheck, to: check)
                    } else {
                        VoiceCheckChip(check: check,
                                       title: model.fineTunedRunID != nil
                                           ? loc.t(.cpFineTunedBadge) : nil)
                    }
                    if let base = model.baselineVoiceCheck {
                        relativeCaption(mine: check, other: base, otherNameKey: .cpVsNameBase)
                    }
                }
            }
            if model.phase == .idle, !model.selectedOutputText.isEmpty {
                correctionRow(model)
            }
        }
        .frame(minWidth: 280)
    }


    /// The corrections loop's entry point: fix the model's output into
    /// what you'd actually say, and that (ask → your version) pair becomes
    /// training data in your next dataset — the most targeted voice signal
    /// there is, aimed exactly at what the model just got wrong.
    @ViewBuilder
    private func correctionRow(_ model: ComposeViewModel) -> some View {
        HStack(spacing: 8) {
            Button(loc.t(.cpSaveAsMyVersion)) { model.beginCorrection() }
                .controlSize(.small)
                .help(loc.t(.cpSaveAsMyVersionHelp))
            if model.pendingCorrections > 0 {
                Text(model.pendingCorrections == 1
                     ? loc.t(.cpCorrectionsWaitingOne)
                     : loc.t(.cpCorrectionsWaitingMany, model.pendingCorrections))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.fineTunedRunID != nil {
                Toggle(loc.t(.cpAutoBaseToggle), isOn: Binding(
                    get: { model.autoCompareBase },
                    set: { on in
                        model.autoCompareBase = on
                        // Turning it on after the fact: fetch the base
                        // version for the realize already on screen.
                        if on, model.baselineOutput.isEmpty, !model.isComparingBase {
                            Task { await model.compareWithBase() }
                        }
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(loc.t(.cpAutoBaseHelp))
            }
        }
        .sheet(isPresented: Binding(
            get: { model.showCorrectionSheet },
            set: { model.showCorrectionSheet = $0 })) {
            correctionSheet(model)
        }
    }

    private func correctionSheet(_ model: ComposeViewModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            Text(loc.t(.cpYourVersionTitle)).font(.title3.bold())
            Text(loc.t(.cpCorrectionExplainer))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextEditor(text: $model.correctionDraft)
                .font(.system(.body, design: .rounded))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button(loc.t(.cancel)) { model.showCorrectionSheet = false }
                Button(loc.t(.cpSaveCorrection)) {
                    Task {
                        _ = await model.saveCorrection()
                        model.showCorrectionSheet = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.correctionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || model.correctionDraft == model.correctionSource)
                .help(model.correctionDraft == model.correctionSource
                      ? loc.t(.cpCorrectionUnchangedHelp) : "")
            }
        }
        .padding(20)
        .frame(width: 480, height: 360)
    }

    /// Net signal movement of a rewrite: did realizing move the text
    /// toward the author's voice or away from it? Compares matched-signal
    /// counts; the denominators can differ (e.g. the rewrite gained a
    /// greeting the draft lacked), which is why the chips show fractions
    /// and this caption only claims direction.
    private func movementCaption(from draft: VoiceCheck, to realized: VoiceCheck) -> some View {
        let delta = realized.matchCount - draft.matchCount
        let (text, color): (String, Color) = delta > 0
            ? (loc.t(.cpMovedToward, delta), .green)
            : delta < 0
                ? (loc.t(.cpMovedAway, delta), .orange)
                : (loc.t(.cpNoNetMovement), .secondary)
        return Text(text)
            .font(.caption)
            .foregroundStyle(color)
    }

    /// Head-to-head caption between the two generated versions: how the
    /// tab you're viewing scores against the other one ("+1 vs base" /
    /// "−1 vs fine-tuned" / "ties base").
    private func relativeCaption(mine: VoiceCheck, other: VoiceCheck,
                                 otherNameKey: L10nKey) -> some View {
        let otherName = loc.t(otherNameKey)
        let delta = mine.matchCount - other.matchCount
        let (text, color): (String, Color) = delta > 0
            ? (loc.t(.cpVsPlus, delta, otherName), .green)
            : delta < 0
                ? (loc.t(.cpVsMinus, delta, otherName), .orange)
                : (loc.t(.cpVsTies, otherName), .secondary)
        return Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .help(loc.t(.cpVsHelp, otherName, mine.matchCount, mine.countableTotal,
                        other.matchCount, other.countableTotal))
    }

    private func diffText(_ model: ComposeViewModel) -> Text {
        let pieces = WordDiff.diff(from: model.draft, to: model.output)
        return pieces.reduce(Text("")) { acc, piece in
            let (word, kind) = piece
            switch kind {
            case .same:
                return acc + Text(word + " ")
            case .added:
                return acc + Text(word + " ").foregroundColor(.accentColor).bold()
            case .removed:
                guard model.showRemovals else { return acc }
                return acc + Text(word + " ").foregroundColor(.secondary).strikethrough()
            }
        }
        .font(.system(.body, design: .rounded))
    }

    // MARK: - Error

    private func errorBanner(_ message: String, model: ComposeViewModel) -> some View {
        HStack {
            Label {
                Text(message).foregroundStyle(.orange)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button(loc.t(.tlRetry)) {
                model.startRealize()
            }
        }
        .padding(10)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}
