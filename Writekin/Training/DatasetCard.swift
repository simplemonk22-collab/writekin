import SwiftUI
import GRDB

/// One dataset's card in the Train screen's Datasets section — the runs
/// list got rich (chips, insights, verdicts) while datasets stayed a
/// one-liner, even though everything interesting about a dataset is
/// already recorded: composition, provenance, reuse, staleness, and the
/// runs it trained. Extracted from `TrainView` and grown accordingly.
struct DatasetCard: View {
    @Environment(AppEnvironment.self) private var env
    let dataset: Dataset
    let usedByRuns: [TrainingRun]
    /// Current kept-item count, for the staleness line.
    let keptItemCount: Int
    /// Only the LATEST dataset wears the "corpus grown" chip — every older
    /// dataset trivially predates new writing, so the chip on all of them
    /// is noise; the latest is the one you'd actually regenerate from.
    let isLatest: Bool
    let onDelete: () -> Void
    private var loc: Localization { .shared }

    /// Async bits that need their own queries (not in stats_json).
    @State private var reusedPairs: Int?
    @State private var bestRun: (id: Int64, val: Double)?
    @State private var showingDetail = false

    var body: some View {
        let stats = DatasetSummary.decodeStats(dataset.statsJson)
        let filter = try? JSONDecoder().decode(DatasetFilter.self,
                                               from: Data(dataset.filterJson.utf8))
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                header(stats: stats, filter: filter)
                if let stats {
                    chipsRow(stats, filter: filter)
                }
                runsLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .task(id: dataset.id) {
            guard let id = dataset.id else { return }
            reusedPairs = try? await DatasetDetailQuery.reusedPairCount(
                db: env.database, datasetID: id)
            bestRun = try? await DatasetDetailQuery.bestFinalVal(
                db: env.database, datasetID: id)
        }
    }

    private func header(stats: DatasetStats?, filter: DatasetFilter?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(dataset.name)
                .font(.callout.weight(.semibold))
            if let exportedAt = dataset.exportedAt {
                Text(Self.dateFormatter.string(from: exportedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            detailPopoverButton(stats: stats, filter: filter)
            Spacer()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!usedByRuns.isEmpty)
            .help(usedByRuns.isEmpty
                  ? loc.t(.trDeleteDatasetHelp)
                  : loc.t(.trKeptAsRunRecord))
        }
    }

    /// The prose lives behind an info button (same pattern as the run
    /// cards' insights popover) — the card itself stays a header, one chip
    /// row, and one caption.
    private func detailPopoverButton(stats: DatasetStats?, filter: DatasetFilter?) -> some View {
        Button {
            showingDetail = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(loc.t(.trDatasetInfoHelp))
        .popover(isPresented: $showingDetail) {
            VStack(alignment: .leading, spacing: 8) {
                Text(dataset.name).font(.headline)
                if let stats {
                    qualityCaption(stats)
                    mediumMixLine(stats)
                }
                provenanceLine(filter)
                stalenessLine(filter)
            }
            .padding(12)
            .frame(width: 460, alignment: .leading)
        }
    }

    /// One row of colored capsules — the run cards' visual language.
    /// Neutral counts stay quiet; the informative ones carry color: reused
    /// (green = model time saved), corrections (purple = your taste in the
    /// data), mix (green on target / orange off), stale (orange, only when
    /// the corpus has outgrown the cap).
    @ViewBuilder
    private func chipsRow(_ stats: DatasetStats, filter: DatasetFilter?) -> some View {
        let train = stats.pairsBySplit["train"] ?? 0
        let heldout = stats.pairsBySplit["heldout"] ?? 0
        HStack(spacing: 8) {
            chip(loc.t(.trChipPairs), DatasetSummary.formatCount(train + heldout),
                 help: loc.t(.trPairsChipHelp, DatasetSummary.formatCount(train),
                             DatasetSummary.formatCount(heldout)))
            chip(loc.t(.trChipHeldout), DatasetSummary.formatCount(heldout),
                 help: loc.t(.trHeldoutChipHelp))
            if let reusedPairs, reusedPairs > 0 {
                chip(loc.t(.trChipReused), DatasetSummary.formatCount(reusedPairs), color: .green,
                     help: loc.t(.trReusedChipHelp))
            }
            if let corrections = stats.pairsByType["correction"], corrections > 0 {
                chip(loc.t(.trChipCorrections), DatasetSummary.formatCount(corrections), color: .purple,
                     help: loc.t(.trCorrectionsChipHelp))
            }
            if let summary = DatasetQuality.mixSummary(stats) {
                mixChip(summary)
            }
            if let filter {
                // Which model wrote the generated drafts — surfaced on the
                // card (not just the popover) so a quality difference
                // between compose-generated and labeler-generated datasets
                // is traceable at a glance.
                chip(loc.t(.trChipGen), Self.shortModelName(filter.generatorModelID),
                     help: loc.t(.trGenChipHelp, filter.generatorModelID))
            }
            if isLatest, let filter, keptItemCount > filter.itemCap {
                chip(loc.t(.trChipCorpusGrown), "+\(DatasetSummary.formatCount(keptItemCount - filter.itemCap))",
                     color: .orange,
                     help: loc.t(.trCorpusGrownHelp, keptItemCount.formatted(),
                                 filter.itemCap.formatted()))
            }
        }
    }

    /// "mix 50/25/25" — green when every share is inside tolerance, orange
    /// with the detailed help when any drifts (see DatasetQuality).
    private func mixChip(_ summary: DatasetQuality.MixSummary) -> some View {
        let deviant = DatasetQuality.isTypeDeviant(summary.degradationPercent,
                                                   target: DatasetQuality.targetDegradationPercent)
            || DatasetQuality.isTypeDeviant(summary.backtranslationPercent,
                                            target: DatasetQuality.targetBacktranslationPercent)
            || DatasetQuality.isTypeDeviant(summary.completionPercent,
                                            target: DatasetQuality.targetCompletionPercent)
            || DatasetQuality.isHeldoutDeviant(summary.heldoutPercent)
        return chip(loc.t(.trChipMix),
                    "\(summary.degradationPercent)/\(summary.backtranslationPercent)/\(summary.completionPercent)",
                    color: deviant ? .orange : .green,
                    help: loc.t(.trMixChipHelp, summary.heldoutPercent))
    }

    /// Capsule chip in the run cards' exact style, string-valued.
    private func chip(_ label: String, _ value: String, color: Color = .secondary,
                      help: String = "") -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2)
            Text(value).font(.caption.weight(.medium)).monospacedDigit()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(color == .secondary ? 0.12 : 0.14), in: Capsule())
        .foregroundStyle(color == .secondary ? Color.secondary : color)
        .help(help)
    }

    /// "mostly sms 61% · email 30% · doc 9%" — aggregated from the per-cell
    /// stats already in stats_json.
    @ViewBuilder
    private func mediumMixLine(_ stats: DatasetStats) -> some View {
        let mix = Self.mediumMix(fromCells: stats.pairsByCell)
        if !mix.isEmpty {
            let total = mix.reduce(0) { $0 + $1.count }
            Text(loc.t(.trMediaPrefix) + mix.prefix(4).map { entry in
                let percent = Int((Double(entry.count) / Double(max(total, 1)) * 100).rounded())
                let medium = entry.medium == "unlabeled"
                    ? loc.t(.trUnlabeled) : KindLabels.medium(entry.medium)
                return "\(medium) \(percent)%"
            }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func provenanceLine(_ filter: DatasetFilter?) -> some View {
        if let filter {
            Text(loc.t(.trGeneratedWith, filter.generatorModelID)
                 + ((reusedPairs ?? 0) > 0
                    ? loc.t(.trReusedKeepModel) : ""))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// Names the numbers behind "this dataset is getting stale": how many
    /// kept items exist NOW vs the cap it drew from.
    @ViewBuilder
    private func stalenessLine(_ filter: DatasetFilter?) -> some View {
        if let filter, keptItemCount > filter.itemCap {
            Text(loc.t(.trCorpusNowHas, keptItemCount.formatted(), filter.itemCap.formatted()))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var runsLine: some View {
        var line = usedByRuns.isEmpty
            ? loc.t(.trNotUsedByRun)
            : loc.t(.trUsedBy, usedByRuns
                .map { loc.t(.trRunN, "\($0.id ?? 0)") }
                .joined(separator: ", "))
        if let bestRun {
            line += loc.t(.trBestVal, String(format: "%.3f", bestRun.val), Int(bestRun.id))
        }
        return Text(line)
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    /// Actual-vs-target mix/heldout caption (spec §3 targets: 50/25/25
    /// degradation/backtranslation/completion, ~10% heldout) — see
    /// `DatasetQuality` for the pure percentage/tolerance math.
    @ViewBuilder
    private func qualityCaption(_ stats: DatasetStats) -> some View {
        if let summary = DatasetQuality.mixSummary(stats) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text(loc.t(.trMixLabel)).foregroundStyle(.secondary)
                    mixValue(summary.degradationPercent,
                             target: DatasetQuality.targetDegradationPercent,
                             reason: loc.t(.trMixBelowDegradation))
                    Text(" / ").foregroundStyle(.secondary)
                    mixValue(summary.backtranslationPercent,
                             target: DatasetQuality.targetBacktranslationPercent,
                             reason: loc.t(.trMixBelowBacktranslation))
                    Text(" / ").foregroundStyle(.secondary)
                    mixValue(summary.completionPercent,
                             target: DatasetQuality.targetCompletionPercent,
                             reason: loc.t(.trMixAboveCompletion))
                    Text(loc.t(.trMixTarget, DatasetQuality.targetDegradationPercent,
                               DatasetQuality.targetBacktranslationPercent,
                               DatasetQuality.targetCompletionPercent))
                        .foregroundStyle(.secondary)
                    heldoutValue(summary.heldoutPercent)
                    Text(loc.t(.trHeldoutTarget, DatasetQuality.targetHeldoutPercent))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                if let contextCount = stats.contextPairCount {
                    let total = (stats.pairsBySplit["train"] ?? 0) + (stats.pairsBySplit["heldout"] ?? 0)
                    if total > 0 {
                        let percent = Int((Double(contextCount) / Double(total) * 100).rounded())
                        Text(loc.t(.trReplyContext, percent))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func mixValue(_ percent: Int, target: Int, reason: String) -> some View {
        if DatasetQuality.isTypeDeviant(percent, target: target) {
            Text("\(percent)").foregroundStyle(.orange).help(reason)
        } else {
            Text("\(percent)").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func heldoutValue(_ percent: Int) -> some View {
        if DatasetQuality.isHeldoutDeviant(percent) {
            Text("\(percent)")
                .foregroundStyle(.orange)
                .help(loc.t(.trHeldoutDeviantHelp))
        } else {
            Text("\(percent)").foregroundStyle(.secondary)
        }
    }

    /// "qwen2.5-1.5b" from "qwen2.5-1.5b-instruct-4bit" — chip-sized model
    /// name; the full id stays in the chip's help. Pure, exposed for tests.
    nonisolated static func shortModelName(_ id: String) -> String {
        id.replacingOccurrences(of: "-instruct", with: "")
            .replacingOccurrences(of: "-4bit", with: "")
            .replacingOccurrences(of: "-8bit", with: "")
    }

    /// Aggregates per-cell counts ("[medium: sms] [audience: …] …") into a
    /// per-medium mix, sorted largest first. Cells without a medium tag
    /// land under "unlabeled". Pure, exposed for tests — and explicitly
    /// nonisolated: a static on a View type is implicitly @MainActor, and
    /// calling it from Swift Testing's off-main executor trips the runtime
    /// isolation check (SIGTRAP — crashed the whole test host).
    nonisolated static func mediumMix(fromCells cells: [String: Int]) -> [(medium: String, count: Int)] {
        var byMedium: [String: Int] = [:]
        for (cell, count) in cells {
            if let match = cell.firstMatch(of: /\[medium: ([^\]]+)\]/) {
                byMedium[String(match.1), default: 0] += count
            } else {
                byMedium["unlabeled", default: 0] += count
            }
        }
        return byMedium.sorted { $0.value > $1.value }
            .map { (medium: $0.key, count: $0.value) }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

/// "How to read a dataset" — the Datasets section-header explainer,
/// mirroring `RunsInfoPopover`. Every chip's meaning and color in one
/// place, since capsule colors aren't self-evident and hover help is only
/// discoverable chip by chip.
struct DatasetsInfoPopover: View {
    @State private var showing = false
    private var loc: Localization { .shared }

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(loc.t(.trHowToReadDataset))
        .popover(isPresented: $showing) {
            Text(loc.t(.trDatasetsPopoverBody))
                .font(.callout)
                .frame(width: 340, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding()
        }
    }
}

/// Per-card queries for facts not captured in `stats_json`.
enum DatasetDetailQuery {
    /// Pairs copied from an earlier dataset instead of freshly generated
    /// (see PairGenerator's cross-dataset reuse): same item, type, and
    /// target as a pair in a LOWER-numbered dataset.
    static func reusedPairCount(db: AppDatabase, datasetID: Int64) async throws -> Int {
        try await db.writer.read { dbc in
            try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM pairs p
                WHERE p.dataset_id = ? AND p.item_id IS NOT NULL
                  AND EXISTS (SELECT 1 FROM pairs q
                              WHERE q.item_id = p.item_id
                                AND q.dataset_id IS NOT NULL
                                AND q.dataset_id < p.dataset_id
                                AND q.pair_type = p.pair_type
                                AND q.target_text = p.target_text)
                """, arguments: [datasetID]) ?? 0
        }
    }

    /// Best (lowest) final val among this dataset's succeeded runs.
    static func bestFinalVal(db: AppDatabase,
                             datasetID: Int64) async throws -> (id: Int64, val: Double)? {
        let rows = try await db.writer.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT id, metrics_json FROM training_runs
                WHERE dataset_id = ? AND status = 'succeeded' AND metrics_json IS NOT NULL
                """, arguments: [datasetID])
        }
        var best: (id: Int64, val: Double)?
        for row in rows {
            guard let json: String = row["metrics_json"],
                  let metrics = try? JSONDecoder().decode(TrainingMetrics.self,
                                                          from: Data(json.utf8)),
                  let val = metrics.finalValLoss else { continue }
            if best == nil || val < best!.val { best = (row["id"], val) }
        }
        return best
    }
}
