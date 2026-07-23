import SwiftUI
import AppKit

struct SourceCardView: View {
    @Environment(AppEnvironment.self) private var env

    let kind: SourceKind
    let state: DetectionRunner.CardState

    private var enabledBinding: Binding<Bool> {
        Binding(get: { env.toggles.isEnabled(kind) },
                set: { env.toggles.set($0, for: kind) })
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbolName)
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName)
                    .font(.headline)
                statusView
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if case .needsFullDiskAccess = state {
                    HStack(spacing: 12) {
                        Button(Localization.shared.t(.detectGrantAccess)) {
                            NSWorkspace.shared.open(FullDiskAccessLink.settingsURL)
                        }
                        .buttonStyle(.link)
                        Button(Localization.shared.t(.detectRescan)) {
                            rescan()
                        }
                        .buttonStyle(.link)
                        .disabled(env.runner.isRunning)
                    }
                    .font(.subheadline)
                }
            }
            Spacer()
            if case .found = state {
                Toggle("Include \(kind.displayName)", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .scanning:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(Localization.shared.t(.detectScanningCard))
            }
        case .notFound(let report):
            Text(report.notes.isEmpty
                 ? Localization.shared.t(.detectNotFound)
                 : report.notes.map(Self.noteText).joined(separator: "; "))
        case .needsFullDiskAccess:
            Text(Localization.shared.t(.detectNeedsFDA))
        case .unreadable:
            Text(Localization.shared.t(.detectUnreadable, kind.displayName))
        case .found(let report):
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.summaryLine(for: report))
                ForEach(report.notes, id: \.self) { note in
                    Text(Self.noteText(note))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Detector caveats arrive as typed `DetectNote`s (adapters run off the
    /// MainActor and can't localize); the card renders them in the current
    /// language.
    static func noteText(_ note: DetectNote) -> String {
        let loc = Localization.shared
        switch note {
        case .sentCountSampled:
            return loc.t(.noteSentSampled)
        case .partialDownloads(let count):
            return loc.t(.notePartialDownloads, count.formatted())
        case .sentMailboxesEmpty:
            return loc.t(.noteSentEmpty)
        case .noSentMailboxes:
            return loc.t(.noteNoSentMailboxes)
        case .maildirUnsupported:
            return loc.t(.noteMaildir)
        case .countEstimatedFromSize:
            return loc.t(.noteSizeEstimate)
        case .itemsInFolder(let count, let name):
            return loc.t(.noteItemsInFolder, count.formatted(), name)
        case .claudeCodeSessions(let count):
            return count == 1 ? loc.t(.noteClaudeCodeSessionOne)
                              : loc.t(.noteClaudeCodeSessions, count.formatted())
        case .claudeDesktopSessions(let count):
            return count == 1 ? loc.t(.noteClaudeDesktopSessionOne)
                              : loc.t(.noteClaudeDesktopSessions, count.formatted())
        case .claudeDesktopServerSide:
            return loc.t(.noteClaudeDesktopServerSide)
        case .whatsAppMirrorsPhone:
            return loc.t(.noteWhatsAppMirror)
        }
    }

    private func rescan() {
        Task {
            let roots = await DocumentRootsStore.load(settings: env.settings)
            await env.runner.run(adapters: AppEnvironment.defaultAdapters(documentRoots: roots))
        }
    }

    static func summaryLine(for report: SourceReport) -> String {
        var parts: [String] = []
        if let count = report.estimatedItemCount {
            parts.append(Localization.shared.t(.detectItemsCount, count.formatted()))
        }
        if let range = report.dateRange {
            let style = Date.FormatStyle().year()
            parts.append("\(range.lowerBound.formatted(style)) → \(range.upperBound.formatted(style))")
        }
        return parts.joined(separator: " · ")
    }
}
