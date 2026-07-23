import SwiftUI

/// Configure-then-run sheet for pair generation, mirroring the Start Run
/// sheet's pattern — pressing Generate Pairs (toolbar or Train tab) opens
/// this instead of firing a multi-hour generation with whatever settings
/// happened to be lying around. Item cap and generator-model choice live
/// here; the Train tab keeps the progress/summary display.
struct PairGenSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let model: TrainModel

    /// Draft text for the item-cap field — edits land on `model.itemCap`
    /// on submit/focus loss; slider drags sync the other way.
    @State private var itemCapText: String = ""
    @FocusState private var itemCapFieldFocused: Bool
    /// Mirrors the Models tab's Pair generation choice (same settings key,
    /// written back on Generate) — whichever place last set it wins.
    @State private var generatorChoice: PairGenModelChoice = .compose
    private var loc: Localization { .shared }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.t(.trGeneratePairsTitle)).font(.title3.bold())
                Text(loc.t(.trPairGenSheetCaption))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(loc.t(.trItemCapLabel))
                    Slider(value: Binding(
                        get: { Double(model.itemCap) },
                        // Round to the nearest 100 in the setter instead of
                        // `step:` — a stepped macOS Slider draws ~200 tick
                        // marks across this range, which read as a stray
                        // underline below the track.
                        set: { model.itemCap = $0.isFinite ? Int(($0 / 100).rounded() * 100) : model.itemCap }
                    ), in: 100...20_000)
                    TextField(loc.t(.trItemCapLabel), text: $itemCapText)
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .focused($itemCapFieldFocused)
                        .onSubmit { commitItemCapText() }
                        .onChange(of: itemCapFieldFocused) { _, focused in
                            if !focused { commitItemCapText() }
                        }
                }
                Text(loc.t(.trItemCapCaption, model.keptItemCount.formatted()))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Picker(loc.t(.trGenerateWithLabel), selection: $generatorChoice) {
                    Text(loc.t(.modelsPairGenComposeOption)).tag(PairGenModelChoice.compose)
                    Text(loc.t(.modelsPairGenLabelerOption)).tag(PairGenModelChoice.labeler)
                }
                .pickerStyle(.radioGroup)
                if let resolved = PairGenModelChoice.resolve(generatorChoice,
                                                            installed: env.modelLibrary.installed) {
                    Text(resolved.kind == generatorChoice.rawValue
                         ? loc.t(.trWillUse, resolved.id)
                         : loc.t(.trNoRoleModel, generatorChoice.rawValue, resolved.id))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Spacer()
                Button(loc.t(.cancel)) { dismiss() }
                Button(loc.t(.trGenerate)) { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(PairGenModelChoice.resolve(generatorChoice,
                                                         installed: env.modelLibrary.installed) == nil
                              || model.isBusy || env.ingest.isRunning)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { itemCapText = "\(model.itemCap)" }
        .onChange(of: model.itemCap) { _, newValue in
            if Int(itemCapText) != newValue { itemCapText = "\(newValue)" }
        }
        .task {
            let stored = (try? await SettingsStore(db: env.database)
                .get(PairGenModelChoice.settingsKey)) ?? nil
            if let choice = stored.flatMap(PairGenModelChoice.init(rawValue:)) {
                generatorChoice = choice
            }
        }
    }

    /// Commits the draft text on submit/focus-loss: a non-numeric entry
    /// reverts to the model's current value rather than silently no-opping.
    private func commitItemCapText() {
        guard let parsed = Int(itemCapText) else {
            itemCapText = "\(model.itemCap)"
            return
        }
        model.itemCap = TrainModel.clampItemCap(parsed)
        itemCapText = "\(model.itemCap)"
    }

    private func start() {
        commitItemCapText()
        let db = env.database
        let modelsRoot = AppEnvironment.modelsRoot
        let runtime = env.runtime
        let installed = env.modelLibrary.installed
        let choice = generatorChoice
        let ingestRunning = env.ingest.isRunning
        guard let generator = PairGenModelChoice.resolve(choice, installed: installed)
        else { return }
        let modelID = generator.id
        Task {
            // Persist the choice so the Models tab picker stays in sync.
            try? await SettingsStore(db: db).set(PairGenModelChoice.settingsKey,
                                                 choice.rawValue)
            model.startPairGeneration(
                db: db, generatorModelID: modelID,
                generatorFactory: {
                    let runtime = ModelRuntime(modelsRoot: modelsRoot)
                    do {
                        try await runtime.load(modelID: modelID)
                        return runtime
                    } catch {
                        return nil
                    }
                },
                // Evict Compose's resident copy before the factory loads its
                // own, so two full models are never in memory at once.
                beforeGeneration: { await runtime.unload() },
                ingestIsRunning: { ingestRunning })
        }
        dismiss()
    }
}
