import SwiftUI

// MARK: - Timeline

/// The entire scan-settings surface, moved here from Timeline's "Scan
/// Settings" popover: the three signal toggles, the sensitivity picker (with
/// captions), the last-active-signal guard, the full `TicLexicon` list
/// inline in a scrollable box, and — new in this pass — a per-toggle
/// explanatory caption, an "Advanced" disclosure group (baseline era month,
/// minimum items/month, and a custom z-threshold/streak override that
/// supersedes the sensitivity preset), and an editable list of user-added
/// phrases matched alongside the built-in lexicon.
///
/// Change semantics are unchanged from the old popover: every edit persists
/// via `ScanSettingsStore`, clears any dismissed-proposal markers (a
/// different signal set / sensitivity / advanced knob makes an old dismissal
/// meaningless), and drops both the in-memory and persisted scan cache
/// (`ContaminationModel.clearCache`) — the cache's fingerprint already
/// includes the whole `ScanSettings` value (JSON-encoded), so every field
/// added here participates automatically. What's different is how the
/// actual rescan happens: the old popover lived inside
/// `ContaminationTimelineView` and could call `model.rescan(db:)` directly.
/// This tab is a separate window that may be open with Timeline not even on
/// screen, so instead it calls `model.invalidate()` (state -> `.idle`) after
/// clearing the cache. The next time Timeline appears, its `.task` calls
/// `model.startScanIfNeeded(db:)`, which — finding no in-memory cache
/// (cleared), no persisted cache (also cleared), and thus no fingerprint to
/// match — falls through to a real `rescan(db:)`. Verified against
/// `ContaminationModelTests.changedScanSettingsTriggersRescanEvenWithUnchangedCorpus`
/// and the `startScanIfNeeded` cache-miss path in `ContaminationModel.swift`.
struct ScanSettingsTab: View {
    @Environment(AppEnvironment.self) private var env
    @State private var settings = ScanSettings()
    @State private var settingsLoaded = false
    @State private var baselineEraMonthText = ""
    @State private var baselineEraMonthIsValid = true
    @State private var newPhrase = ""
    @State private var addPhraseError: String?

    var body: some View {
        Form {
            Section(Localization.shared.t(.scanSectionSignals)) {
                Toggle(Localization.shared.t(.scanEmDashes), isOn: $settings.emDashEnabled)
                    .disabled(isLastActiveSignal(\.emDashEnabled))
                    .help(isLastActiveSignal(\.emDashEnabled) ? Self.lastSignalHelp : "")
                Text(Localization.shared.t(.scanEmDashesCaption))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(Localization.shared.t(.scanPhrases), isOn: $settings.phrasesEnabled)
                    .disabled(isLastActiveSignal(\.phrasesEnabled))
                    .help(isLastActiveSignal(\.phrasesEnabled) ? Self.lastSignalHelp : "")
                Text(Localization.shared.t(.scanPhrasesCaption))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(Localization.shared.t(.scanListFormatting), isOn: $settings.listFormattingEnabled)
                    .disabled(isLastActiveSignal(\.listFormattingEnabled))
                    .help(isLastActiveSignal(\.listFormattingEnabled) ? Self.lastSignalHelp : "")
                Text(Localization.shared.t(.scanListFormattingCaption))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(Localization.shared.t(.scanSectionSensitivity)) {
                if settings.isCustomSensitivity {
                    HStack {
                        Text(Localization.shared.t(.scanCustom)).bold()
                        Spacer()
                        Button(Localization.shared.t(.scanUsePreset)) {
                            settings.customZThreshold = nil
                            settings.customStreakMonths = nil
                        }
                    }
                    Text(Localization.shared.t(.scanOverrideActive))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Sensitivity", selection: $settings.sensitivity) {
                        ForEach(ScanSettings.Sensitivity.allCases, id: \.self) { level in
                            Text(Localization.shared.t(level.labelKey)).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    Text(Localization.shared.t(settings.sensitivity.captionKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // Selecting a preset while a custom override is active clears
            // the override -- the picker above is only shown when there's
            // no active override, but the sensitivity value itself can still
            // change indirectly (e.g. `Use Preset` reverting to whatever
            // preset was last selected), so this stays a plain `onChange`
            // on `settings.sensitivity` rather than living inside the picker
            // action.
            .onChange(of: settings.sensitivity) { _, _ in
                guard settingsLoaded else { return }
                settings.customZThreshold = nil
                settings.customStreakMonths = nil
            }

            Section {
                DisclosureGroup(Localization.shared.t(.scanAdvanced)) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(Localization.shared.t(.scanBaselinePlaceholder), text: $baselineEraMonthText)
                            .onSubmit { commitBaselineEraMonth() }
                            .onChange(of: baselineEraMonthText) { _, newValue in
                                baselineEraMonthIsValid = ScanSettings.isValidEraMonth(newValue)
                                if baselineEraMonthIsValid { commitBaselineEraMonth() }
                            }
                        Text(baselineEraMonthIsValid
                             ? Localization.shared.t(.scanBaselineValid)
                             : Localization.shared.t(.scanBaselineInvalid))
                            .font(.caption)
                            .foregroundStyle(baselineEraMonthIsValid ? Color.secondary : Color.red)
                    }
                    .padding(.vertical, 2)

                    Stepper(Localization.shared.t(.scanMinItems, settings.minItemsPerMonth),
                            value: $settings.minItemsPerMonth, in: 1...20)
                    Text(Localization.shared.t(.scanMinItemsCaption))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Stepper(Localization.shared.t(.scanZOverride, zThresholdBinding.wrappedValue),
                            value: zThresholdBinding, in: 0.5...3.0, step: 0.1)
                    Stepper(Localization.shared.t(.scanStreakOverride, streakBinding.wrappedValue),
                            value: streakBinding, in: 1...6)
                    Text(Localization.shared.t(.scanOverrideCaption))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(Localization.shared.t(.scanStockPhrases,
                                          TicLexicon.words.count - settings.disabledBuiltinPhrases.count,
                                          TicLexicon.words.count)) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading, spacing: 4) {
                        ForEach(TicLexicon.words.sorted(), id: \.self) { phrase in
                            Toggle(phrase, isOn: builtinPhraseBinding(phrase))
                                .toggleStyle(.checkbox)
                                .font(.caption)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 180)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Text(Localization.shared.t(.scanUncheckCaption))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(Localization.shared.t(.scanResetDefaults)) { settings.disabledBuiltinPhrases = [] }
                        .disabled(settings.disabledBuiltinPhrases.isEmpty)
                }
            }

            Section(Localization.shared.t(.scanYourAdditions, settings.customPhrases.count)) {
                if !settings.customPhrases.isEmpty {
                    ForEach(settings.customPhrases, id: \.self) { phrase in
                        HStack {
                            Text(phrase)
                            Spacer()
                            Button {
                                settings.customPhrases.removeAll { $0 == phrase }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .help(Localization.shared.t(.scanRemovePhrase, phrase))
                        }
                    }
                }
                HStack {
                    TextField(Localization.shared.t(.scanAddPlaceholder), text: $newPhrase)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addPhrase() }
                        .onChange(of: newPhrase) { _, _ in addPhraseError = nil }
                    Button(Localization.shared.t(.scanAdd)) { addPhrase() }
                        .disabled(newPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let addPhraseError {
                    Text(addPhraseError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(Localization.shared.t(.scanMatchedCaption))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(Localization.shared.t(.scanRescanNote))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // NOT `.fixedSize(vertical: true)` like the other tabs: this tab
        // outgrew the screen (sensitivity + advanced + stock phrases), and
        // a fixed-size Form inside a screen-clamped window just clips its
        // bottom with no way to scroll. A capped height lets the grouped
        // Form scroll natively instead.
        .frame(height: 620)
        .task {
            settings = await ScanSettingsStore.load(settings: env.settings)
            baselineEraMonthText = settings.baselineEraMonth
            settingsLoaded = true
        }
        // `settingsLoaded` guards against the initial `.task` load above
        // (assigning the just-loaded value into `settings`) being mistaken
        // for a user edit — mirrors the old popover's `scanSettingsLoaded`.
        .onChange(of: settings) { _, newValue in
            guard settingsLoaded else { return }
            Task { await applyScanSettings(newValue) }
        }
    }

    private func commitBaselineEraMonth() {
        guard ScanSettings.isValidEraMonth(baselineEraMonthText) else { return }
        settings.baselineEraMonth = baselineEraMonthText
    }

    private func addPhrase() {
        let trimmed = newPhrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }
        // Silently clearing on a duplicate looked exactly like a broken Add
        // button — say what happened instead.
        if TicLexicon.words.contains(trimmed) {
            addPhraseError = "\u{201C}\(trimmed)\u{201D} is already in the built-in list above."
            return
        }
        if settings.customPhrases.contains(trimmed) {
            addPhraseError = "\u{201C}\(trimmed)\u{201D} is already in your additions."
            return
        }
        settings.customPhrases.append(trimmed)
        newPhrase = ""
        addPhraseError = nil
    }

    /// Two-way binding for one built-in phrase's checkbox: "on" means the
    /// phrase counts (i.e. it's absent from `disabledBuiltinPhrases`);
    /// unchecking adds it to the set, checking removes it.
    private func builtinPhraseBinding(_ phrase: String) -> Binding<Bool> {
        Binding(
            get: { !settings.disabledBuiltinPhrases.contains(phrase) },
            set: { enabled in
                if enabled {
                    settings.disabledBuiltinPhrases.remove(phrase)
                } else {
                    settings.disabledBuiltinPhrases.insert(phrase)
                }
            })
    }

    private var zThresholdBinding: Binding<Double> {
        Binding(
            get: { settings.customZThreshold ?? settings.sensitivity.zThreshold },
            set: { settings.customZThreshold = $0 })
    }

    private var streakBinding: Binding<Int> {
        Binding(
            get: { settings.customStreakMonths ?? settings.sensitivity.sustainedMonths },
            set: { settings.customStreakMonths = $0 })
    }

    private func applyScanSettings(_ newSettings: ScanSettings) async {
        try? await ScanSettingsStore.save(newSettings, settings: env.settings)
        try? await CutoffStore(settings: env.settings).clearAllDismissedProposals()
        env.contamination.clearCache(db: env.database)
        env.contamination.invalidate()
    }

    /// True when `keyPath` is currently the ONLY enabled signal — disables
    /// its own toggle (with a `.help` explaining why) so the user can't
    /// switch off the last active signal and leave the composite score
    /// permanently zero (`ScanSettings.hasActiveSignal`).
    private func isLastActiveSignal(_ keyPath: KeyPath<ScanSettings, Bool>) -> Bool {
        settings[keyPath: keyPath] && activeSignalCount == 1
    }

    private var activeSignalCount: Int {
        [settings.emDashEnabled, settings.phrasesEnabled, settings.listFormattingEnabled]
            .filter { $0 }.count
    }

    private static let lastSignalHelp = "At least one signal must stay enabled"
}
