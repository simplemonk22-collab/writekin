import SwiftUI

struct SourceIngestRow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openSettings) private var openSettings

    let kind: SourceKind
    let state: IngestCoordinator.SourceRunState
    let lastSynced: Date?
    @State private var installingExporter = false
    @State private var exporterInstallError: String?

    /// This source's kept-item count in the whole corpus — the run tallies
    /// ("35 added · 49 already in corpus") only describe THIS run's window,
    /// which reads as if older messages vanished once ingest went
    /// incremental. Nil hides the segment (no items yet).
    var keptCount: Int?

    private var enabledBinding: Binding<Bool> {
        Binding(get: { env.toggles.isEnabled(kind) },
                set: { env.toggles.set($0, for: kind) })
    }

    /// The source's data can't be read right now: it needs Full Disk
    /// Access and FDA is off.
    private var blockedByFDA: Bool {
        kind.requiresFullDiskAccess && env.fda.status == .denied
    }

    /// Messages can't be read without the (never-bundled, GPL)
    /// imessage-exporter tool — same treatment as an FDA block until the
    /// row's "Set up Messages support" download installs it.
    private var blockedByMissingExporter: Bool {
        kind == .iMessage && ImessageExporterCLI.locateBinary() == nil
    }

    /// A blocked row shows its include toggle OFF and disabled — a
    /// checkmark next to a source that structurally cannot be read reads
    /// as a lie. The stored preference is untouched — once
    /// the block clears (FDA granted / exporter installed) the toggle shows
    /// the real state again.
    private var blocked: Bool { blockedByFDA || blockedByMissingExporter }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: kind.symbolName).font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName).font(.headline)
                    if blockedByFDA {
                        Text(Localization.shared.t(.fdaRowBlocked))
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    } else if blockedByMissingExporter {
                        Text(Localization.shared.t(.srcExporterMissing))
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    } else {
                        statusView.font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let caveatKey = kind.coverageCaveatKey, env.toggles.isEnabled(kind) {
                        Text(Localization.shared.t(caveatKey))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Shown whenever the exporter is missing — not gated on
                    // the include toggle, which is disabled while blocked
                    // (the setup button is the only way OUT of the block).
                    if kind == .iMessage {
                        messagesSetup
                    }
                }
            }
            .opacity(env.toggles.isEnabled(kind) && !blocked ? 1 : 0.6)
            Spacer()
            if kind == .fileSystem {
                // Deep-links to Settings › Sources › Documents rather than
                // whatever tab the Settings window last showed.
                Button {
                    env.navigation.requestedSettingsTab = .sources
                    env.navigation.requestedSettingsSource = kind
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help(Localization.shared.t(.srcDocsGearHelp))
            }
            Toggle(Localization.shared.t(.sourceInclude, kind.displayName),
                   isOn: blocked ? .constant(false) : enabledBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(env.ingest.isRunning || blocked)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .idle:
            if !env.toggles.isEnabled(kind) {
                Text(Localization.shared.t(.srcExcluded))
            } else if let lastSynced {
                Text(Localization.shared.t(
                        .srcLastSynced,
                        lastSynced.formatted(date: .abbreviated, time: .shortened))
                     + Self.keptSuffix(keptCount))
            } else {
                Text(Localization.shared.t(.srcNotIngested))
            }
        case .running(let progress):
            TimelineView(.periodic(from: .now, by: 5)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(Self.runningLine(progress))
                    }
                    if let lastProgressAt = env.ingest.lastProgressAt[kind],
                       context.date.timeIntervalSince(lastProgressAt) > 30 {
                        Text(Localization.shared.t(.srcStillWorking))
                    }
                }
            }
        case .finished(let progress):
            Text(Self.finishedSummary(progress, kind: kind)
                 + Self.keptSuffix(keptCount))
        case .failed(let message):
            Text(message).foregroundStyle(.orange)
        case .cancelled:
            Text(Localization.shared.t(.srcStopped)).foregroundStyle(.secondary)
        }
    }

    /// Shows work done, not just landed items — a dedupe-heavy re-ingest that
    /// lands nothing still visibly progresses via "checked" count.
    static func runningLine(_ progress: IngestProgress) -> String {
        let processed = progress.itemsLanded + progress.skipped
        let phase = Self.phaseText(progress.phase)
        if progress.skipped > 0 {
            return Localization.shared.t(.srcRunningChecked, phase,
                                         progress.itemsLanded.formatted(),
                                         processed.formatted())
        }
        return Localization.shared.t(.srcRunning, phase,
                                     progress.itemsLanded.formatted())
    }

    /// Ingestors run off the MainActor and report typed `IngestPhase`
    /// values (the `DetectNote` pattern) — the row translates at render
    /// time, so a language switch mid-ingest re-renders live. Names in the
    /// data-carrying cases (account dirs, mailboxes, chats, folders) are
    /// data, not copy.
    static func phaseText(_ phase: IngestPhase) -> String {
        let loc = Localization.shared
        return switch phase {
        case .starting: loc.t(.ipStarting)
        case .readingAppleMail: loc.t(.ipReadingAppleMail)
        case .readingThunderbirdMailboxes: loc.t(.ipReadingThunderbird)
        case .readingDocuments: loc.t(.ipReadingDocuments)
        case .readingWhatsAppMessages: loc.t(.ipReadingWhatsApp)
        case .readingClaudeCodeSessions: loc.t(.ipReadingClaudeCode)
        case .readingClaudeDesktopSessions: loc.t(.ipReadingClaudeDesktop)
        case .exportingMessages: loc.t(.ipExportingMessages)
        case .scanningAllMail: loc.t(.ipScanningAllMail)
        case .reading(let name): loc.t(.ipReadingName, name)
        case .upToDate(let name): loc.t(.ipUpToDate, name)
        }
    }

    /// Every source converges on the same shape — "N added · …" — so rows
    /// can be compared at a glance ("Up to date" here, "0 added" there read
    /// as different outcomes when they're the same one). `kind` names what a
    /// whole-file skip skipped in this source's own vocabulary ("mailbox"
    /// for mail, "transcript" for chat exports) — see
    /// `SourceKind.skippedNounKeys`.
    static func finishedSummary(_ progress: IngestProgress,
                                kind: SourceKind = .fileSystem) -> String {
        let loc = Localization.shared
        var line = loc.t(.srcAdded, progress.itemsLanded.formatted())
        if progress.skipped > 0 {
            line += loc.t(.srcAlreadyIn, progress.skipped.formatted())
        }
        if progress.unparseable > 0 {
            line += loc.t(.srcUnreadable, progress.unparseable.formatted())
        }
        if progress.skippedFiles > 0 {
            let nounKeys = kind.skippedNounKeys
            let noun = loc.t(progress.skippedFiles == 1 ? nounKeys.one : nounKeys.many)
            line += loc.t(.srcUnchanged, progress.skippedFiles.formatted(), noun)
        }
        return line
    }

    /// Messages needs the (GPL, so never-bundled) imessage-exporter tool —
    /// one-click, checksum-pinned download when it's missing (packaging
    /// plan Task 2). Re-checked per render via `exporterCheck` so the
    /// button disappears the moment installation lands.
    @ViewBuilder
    private var messagesSetup: some View {
        if ImessageExporterCLI.locateBinary() == nil {
            HStack(spacing: 8) {
                if installingExporter {
                    ProgressView().controlSize(.mini)
                    Text(Localization.shared.t(.srcDownloadingMessages))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(Localization.shared.t(.srcSetupMessages)) {
                        installingExporter = true
                        exporterInstallError = nil
                        Task {
                            do {
                                try await ExporterInstaller().install()
                            } catch {
                                exporterInstallError =
                                    Localization.shared.t(.srcExporterFailed)
                            }
                            installingExporter = false
                        }
                    }
                    .controlSize(.small)
                    .help(Localization.shared.t(.srcExporterHelp))
                }
            }
            if let exporterInstallError {
                Text(exporterInstallError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// "· 1,234 kept total" — the whole-corpus count for this source,
    /// appended after run-scoped tallies so an incremental run's small
    /// numbers never read as the corpus shrinking. Pure, exposed for tests.
    static func keptSuffix(_ keptCount: Int?) -> String {
        guard let keptCount, keptCount > 0 else { return "" }
        return Localization.shared.t(.srcKeptTotal, keptCount.formatted())
    }
}
