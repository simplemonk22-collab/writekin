import SwiftUI

/// Models Library: a unified, state-driven list of every manifest model
/// (not installed / downloading / installed), plus whatever `ModelScout`
/// found in other apps' local caches, plus any installed model that isn't
/// in the manifest at all. Purely presentational — all state and actions
/// live in `ModelLibrary`.
struct ModelsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var removeTarget: InstalledModel?
    /// Models tab › Pair generation role choice, mirrored from settings
    /// (`PairGenModelChoice.settingsKey`) on appear and written on change.
    @State private var pairGenChoice: PairGenModelChoice = .compose
    /// Read once per view lifetime — hardware doesn't change under us.
    private let specs = MachineSpecs.detect()

    private var library: ModelLibrary { env.modelLibrary }

    private func bestMatchID(kind: String) -> String? {
        ModelFit.bestMatch(manifest: library.manifest, machineRamGB: specs.ramGB, kind: kind)
    }

    /// Installed rows whose id doesn't match any manifest model — genuinely
    /// orphaned installs (e.g. adopted copies of models later dropped from
    /// the manifest), not the normal "downloaded a manifest model" case.
    private var otherInstalled: [InstalledModel] {
        let manifestIDs = Set(library.manifest.map(\.id))
        return library.installed.filter { !manifestIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenCaption(text: Localization.shared.t(
                    .modelsCaption, AppIdentity.appName, AppIdentity.appName))
                specsSection
                roleSection(kind: "compose",
                            title: Localization.shared.t(.modelsComposeTitle),
                            caption: Localization.shared.t(.modelsComposeCaption))
                roleSection(kind: "labeler",
                            title: Localization.shared.t(.modelsLabelerTitle),
                            caption: Localization.shared.t(.modelsLabelerCaption))
                pairGenSection
                otherManifestSection
                otherInstalledSection
                scoutedSection
            }
            .padding(20)
        }
        .navigationTitle(MainSection.models.title)
        .task { await library.refresh() }
        .confirmationDialog(
            removeTarget.map { Localization.shared.t(.modelsRemoveTitle, $0.id) }
                ?? Localization.shared.t(.modelsRemoveGeneric),
            isPresented: Binding(
                get: { removeTarget != nil },
                set: { if !$0 { removeTarget = nil } }),
            presenting: removeTarget
        ) { model in
            Button(Localization.shared.t(.modelsRemove), role: .destructive) {
                Task { await library.remove(model.id) }
            }
            Button(Localization.shared.t(.cancel), role: .cancel) {}
        } message: { model in
            Text(dependentFeaturesMessage(for: model.kind))
        }
    }

    // MARK: - This Mac (specs + what they mean for model choice)

    private var specsSection: some View {
        let loc = Localization.shared
        return GroupBox(loc.t(.modelsThisMac)) {
            HStack(alignment: .top, spacing: 24) {
                specStat(loc.t(.modelsChip), specs.chipName)
                specStat(loc.t(.modelsMemory), loc.t(.modelsMemoryUnified, "\(specs.ramGB)"))
                specStat(loc.t(.modelsCPU), coresLine)
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
            Text(loc.t(.modelsMemoryNote, "\(specs.ramGB)"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        }
    }

    /// Localized version of `MachineSpecs.coresLine` (the specs type is a
    /// plain model with no Localization access).
    private var coresLine: String {
        if let p = specs.performanceCores, let e = specs.efficiencyCores {
            return Localization.shared.t(.modelsCoresFull, "\(specs.totalCores)", "\(p)", "\(e)")
        }
        return Localization.shared.t(.modelsCores, "\(specs.totalCores)")
    }

    private func specStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
        }
    }

    // MARK: - Models, grouped by the role they fill

    /// One section per role the app requires. The header carries the
    /// role's status — a green check when the need is met, an explicit
    /// warning naming the disabled feature when it isn't — so "you need
    /// one of each" is visible without reading any card.
    @ViewBuilder
    private func roleSection(kind: String, title: String, caption: String) -> some View {
        let models = library.manifest.filter { $0.kind == kind }
        if !models.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(models) { model in
                        modelCard(model)
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                    roleStatus(kind: kind)
                }
            }
        }
    }

    @ViewBuilder
    private func roleStatus(kind: String) -> some View {
        if library.installed.contains(where: { $0.kind == kind }) {
            Label(Localization.shared.t(.modelsRoleInstalled), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        } else {
            Label(kind == "labeler"
                    ? Localization.shared.t(.modelsNoLabelerWarn)
                    : Localization.shared.t(.modelsNoComposeWarn),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
        }
    }

    /// Not a downloadable role — a CHOICE between the two installed roles.
    /// Pair generation's prompts (bland degradations, one-line
    /// instructions) don't need the big compose model, so the labeler-size
    /// model can do the same job several times faster.
    private var pairGenSection: some View {
        GroupBox(Localization.shared.t(.modelsPairGenTitle)) {
            VStack(alignment: .leading, spacing: 8) {
                Text(Localization.shared.t(.modelsPairGenCaption))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Picker(Localization.shared.t(.modelsPairGenPicker), selection: $pairGenChoice) {
                    Text(Localization.shared.t(.modelsPairGenComposeOption))
                        .tag(PairGenModelChoice.compose)
                    Text(Localization.shared.t(.modelsPairGenLabelerOption))
                        .tag(PairGenModelChoice.labeler)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if pairGenChoice == .labeler,
                   !library.installed.contains(where: { $0.kind == "labeler" }) {
                    Label(Localization.shared.t(.modelsPairGenNoLabeler),
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
        .task {
            let stored = (try? await SettingsStore(db: env.database)
                .get(PairGenModelChoice.settingsKey)) ?? nil
            if let choice = stored.flatMap(PairGenModelChoice.init(rawValue:)) {
                pairGenChoice = choice
            }
        }
        .onChange(of: pairGenChoice) { _, newValue in
            Task {
                try? await SettingsStore(db: env.database)
                    .set(PairGenModelChoice.settingsKey, newValue.rawValue)
            }
        }
    }

    /// Manifest models whose kind isn't one of the known role sections —
    /// empty today, but a future manifest kind shouldn't silently vanish.
    @ViewBuilder
    private var otherManifestSection: some View {
        let models = library.manifest.filter { $0.kind != "compose" && $0.kind != "labeler" }
        if !models.isEmpty {
            GroupBox(Localization.shared.t(.modelsOtherModels)) {
                VStack(spacing: 12) {
                    ForEach(models) { model in
                        modelCard(model)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func modelCard(_ model: ManifestModel) -> some View {
        let state = library.states[model.id] ?? .idle
        let installedModel = library.installed.first { $0.id == model.id }

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.displayName).font(.headline)
                        licenseBadge(model.license)
                        fitBadge(model)
                        if model.id == bestMatchID(kind: model.kind) {
                            bestMatchBadge
                        }
                    }
                    if let installedModel, case .installed = state {
                        installedSubtitle(installedModel)
                    } else {
                        Text(Localization.shared.t(
                            .modelsTierLine, Self.kindWord(model.kind), "\(model.ramTierGB)",
                            ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        sourceLine(model)
                    }
                }
                Spacer(minLength: 12)
                modelCardAction(model, state: state, installedModel: installedModel)
            }
            if case .downloading(let progress) = state {
                downloadProgressView(progress, modelID: model.id)
            } else if case .failed(let message) = state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .modelsCardStyle()
    }

    @ViewBuilder
    private func modelCardAction(_ model: ManifestModel, state: DownloadState, installedModel: InstalledModel?) -> some View {
        switch state {
        case .idle, .failed:
            Button(state.isFailedCase
                   ? Localization.shared.t(.modelsRetry)
                   : Localization.shared.t(.modelsDownload)) {
                library.download(model)
            }
        case .downloading:
            Button(Localization.shared.t(.cancel)) {
                library.cancelDownload(model.id)
            }
        case .installed:
            HStack(spacing: 8) {
                Label(Localization.shared.t(.modelsInstalledBadge),
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                Button(Localization.shared.t(.modelsRemove), role: .destructive) {
                    removeTarget = installedModel
                }
            }
        }
    }

    /// Role names for the card subtitle lines ("Compose · 16 GB tier · …").
    static func kindWord(_ kind: String) -> String {
        switch kind {
        case "compose": Localization.shared.t(.modelsKindCompose)
        case "labeler": Localization.shared.t(.modelsKindLabeler)
        default: kind.capitalized
        }
    }

    private func installedSubtitle(_ model: InstalledModel) -> some View {
        let sizeStr = library.installedSizes[model.id].map { size in
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        } ?? "—"
        return VStack(alignment: .leading, spacing: 2) {
            Text(Localization.shared.t(.modelsPath, model.path))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(Localization.shared.t(.modelsSize, sizeStr))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Trust cue: before (and during) a download, show exactly where the
    /// bytes come from — a real link to the Hugging Face repo page.
    private func sourceLine(_ model: ManifestModel) -> some View {
        let caption = "huggingface.co/\(model.hfRepo)"
        return Group {
            if let url = URL(string: "https://huggingface.co/\(model.hfRepo)") {
                Link(destination: url) {
                    Label(caption, systemImage: "link")
                }
                .buttonStyle(.plain)
            } else {
                Label(caption, systemImage: "link")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Fixed-width, monospaced-digit progress readout so the row doesn't
    /// reflow on every tick, and a full-width bar so nothing shifts either.
    private func downloadProgressView(_ progress: DownloadProgress, modelID: String) -> some View {
        let fraction = progress.totalBytes > 0
            ? Double(progress.bytesDownloaded) / Double(progress.totalBytes)
            : 0
        return VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: fraction)
                .frame(maxWidth: .infinity)
            Text(Localization.shared.t(.modelsProgressOf,
                                       formatGB(progress.bytesDownloaded),
                                       formatGB(progress.totalBytes))
                 + etaSuffix(modelID: modelID))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// " · 42 MB/s · about 3 minutes left", or "estimating…" while the
    /// rolling window warms up. Rate in bytes/s from the shared ProgressETA.
    private func etaSuffix(modelID: String) -> String {
        guard let eta = library.downloadETA[modelID] else {
            return Localization.shared.t(.modelsEstimating)
        }
        let rate = ByteCountFormatter.string(fromByteCount: Int64(eta.itemsPerSecond),
                                             countStyle: .file)
        guard eta.secondsRemaining > 0 else {
            return Localization.shared.t(.modelsRateOnly, rate)
        }
        let remaining = Duration.seconds(eta.secondsRemaining)
            .formatted(.units(allowed: [.hours, .minutes, .seconds],
                              width: .abbreviated, maximumUnitCount: 2))
        return Localization.shared.t(.modelsEtaLeft, rate, remaining)
    }

    /// Always "X.XX GB" — fixed precision so the string's width barely
    /// changes between ticks (combined with `.monospacedDigit()`, this is
    /// what kills the jitter).
    private func formatGB(_ bytes: Int64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }

    // MARK: - Other installed (installed but not in the manifest)

    @ViewBuilder
    private var otherInstalledSection: some View {
        if !otherInstalled.isEmpty {
            GroupBox(Localization.shared.t(.modelsOtherInstalled)) {
                VStack(spacing: 12) {
                    ForEach(otherInstalled, id: \.id) { model in
                        otherInstalledCard(model)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func otherInstalledCard(_ model: InstalledModel) -> some View {
        let sizeStr = library.installedSizes[model.id].map { size in
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        } ?? "—"

        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.id).font(.headline)
                Text("\(Self.kindWord(model.kind)) · \(model.source == "cloned" ? Localization.shared.t(.modelsAdoptedFrom, model.path) : Localization.shared.t(.modelsDownloadedWord)) · \(model.installedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Localization.shared.t(.modelsPath, model.path))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(Localization.shared.t(.modelsSize, sizeStr))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(Localization.shared.t(.modelsRemove), role: .destructive) {
                removeTarget = model
            }
        }
        .modelsCardStyle()
    }

    // MARK: - Scouted

    private var scoutedSection: some View {
        GroupBox {
            scoutedContent
        } label: {
            HStack(spacing: 8) {
                Text(Localization.shared.t(.modelsFoundOnMac))
                // Rescan lives with the section it refreshes, not in the
                // window toolbar — the toolbar is Settings-only on this tab.
                Button(Localization.shared.t(.detectRescan), systemImage: "arrow.clockwise") {
                    Task { await library.refresh() }
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .help(Localization.shared.t(.modelsRescanHelp))
            }
        }
    }

    @ViewBuilder
    private var scoutedContent: some View {
        Group {
            if library.scouted.isEmpty {
                Text(Localization.shared.t(.modelsNothingScouted))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(library.scouted.enumerated()), id: \.offset) { _, scouted in
                        scoutedRow(scouted)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func scoutedRow(_ scouted: ScoutedModel) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(scouted.location.lastPathComponent).font(.headline)
                Text(Localization.shared.t(.modelsFoundVia, scouted.appName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let note = scouted.note {
                    // Honest, never oversold: say exactly why this either
                    // can't be used, or was matched with less confidence.
                    Text(Localization.shared.t(note.l10nKey))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if scouted.matchedManifestID != nil {
                Button(Localization.shared.t(.modelsUseThisCopy)) {
                    Task { await library.adopt(scouted) }
                }
            }
        }
        .modelsCardStyle()
    }

    // MARK: - Helpers

    /// How this model suits this Mac's memory, judged from its RAM tier —
    /// green/orange/red at a glance, the reasoning in the tooltip.
    private func fitBadge(_ model: ManifestModel) -> some View {
        let fit = ModelFit.rate(ramTierGB: model.ramTierGB, machineRamGB: specs.ramGB)
        let color: Color = switch fit {
        case .great: .green
        case .ok: .orange
        case .tooBig: .red
        }
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(Localization.shared.t(fit.labelKey))
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
        .help(Localization.shared.t(.modelsFitHelp,
                                    Localization.shared.t(fit.detailKey),
                                    "\(model.ramTierGB)", "\(specs.ramGB)"))
    }

    private var bestMatchBadge: some View {
        Label(Localization.shared.t(.modelsBestMatch), systemImage: "sparkles")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.12), in: Capsule())
            .foregroundStyle(.tint)
            .help(Localization.shared.t(.modelsBestMatchHelp))
    }

    private func licenseBadge(_ license: String) -> some View {
        Text(license)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.15), in: Capsule())
    }

    /// Removing a model isn't purely local cleanup — it silently disables
    /// whatever feature depended on it, so the confirmation says so by name
    /// instead of a generic "are you sure?".
    private func dependentFeaturesMessage(for kind: String) -> String {
        switch kind {
        case "labeler": return Localization.shared.t(.modelsRemoveLabelerMsg)
        case "compose": return Localization.shared.t(.modelsRemoveComposeMsg)
        default: return Localization.shared.t(.modelsRemoveOtherMsg)
        }
    }
}

private extension DownloadState {
    var isFailedCase: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Shared card chrome for every row on the Models screen: generous inner
/// padding (so text never crowds the edges) and a soft rounded background
/// instead of dividers between rows — no stray lines at the bottom of a card.
private extension View {
    func modelsCardStyle() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.15))
            )
    }
}
