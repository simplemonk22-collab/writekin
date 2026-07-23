import SwiftUI
import AppKit

/// The folder list behind the Documents source's settings: which folders are
/// scanned for documents. Edits persist immediately via `DocumentRootsStore`;
/// they take effect on the next detection scan / Ingest All (both load the
/// store just before running). Styled as a bordered, alternating-row list
/// (folder icon + tilde-abbreviated path, remove button on hover) with
/// Add Folder…/Reset to Defaults as a footer bar underneath, rather than the
/// old bare `HStack` rows.
struct DocumentFoldersSettings: View {
    @Environment(AppEnvironment.self) private var env
    @State private var roots: [URL] = []
    @State private var hoveredPath: String?
    @State private var disabledTypes: Set<String> = []

    private func typeBinding(_ typeID: String) -> Binding<Bool> {
        Binding(
            get: { !disabledTypes.contains(typeID) },
            set: { enabled in
                if enabled { disabledTypes.remove(typeID) } else { disabledTypes.insert(typeID) }
                let settings = env.settings
                Task { try? await DocumentTypeStore.setEnabled(enabled, typeID: typeID,
                                                               settings: settings) }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Localization.shared.t(.docFoldersTitle))
                .font(.headline)

            if roots.isEmpty {
                Text(Localization.shared.t(.docFoldersEmpty))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                List {
                    ForEach(roots, id: \.path) { root in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text((root.path as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if hoveredPath == root.path {
                                Button {
                                    Task {
                                        try? await DocumentRootsStore.remove(
                                            path: root.path, settings: env.settings)
                                        await reload()
                                    }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help(Localization.shared.t(.docRemoveFolderHelp))
                            }
                        }
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            hoveredPath = hovering ? root.path : nil
                        }
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(minHeight: 90, maxHeight: 200)
            }

            HStack {
                Button(Localization.shared.t(.docAddFolder)) { addFolder() }
                Button(Localization.shared.t(.docFoldersReset)) {
                    Task {
                        try? await DocumentRootsStore.reset(settings: env.settings)
                        await reload()
                    }
                }
                Spacer()
                Text(Localization.shared.t(.docFoldersNote))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
                .padding(.vertical, 4)

            Text(Localization.shared.t(.docFileTypes))
                .font(.headline)
            Text(Localization.shared.t(.docFileTypesNote))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(DocumentTypeStore.types) { type in
                Toggle(isOn: typeBinding(type.id)) {
                    HStack(spacing: 6) {
                        Text(type.title)
                        // Titles are format names (shared across languages);
                        // only the Pages row's detail is a real sentence.
                        Text(type.id == "pages"
                             ? Localization.shared.t(.docPagesDetail)
                             : type.detail)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 340, alignment: .leading)
        .task { await reload() }
    }

    private func reload() async {
        roots = await DocumentRootsStore.load(settings: env.settings)
        disabledTypes = await DocumentTypeStore.disabledTypeIDs(settings: env.settings)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = Localization.shared.t(.docAddPrompt)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls {
                try? await DocumentRootsStore.add(path: url.path, settings: env.settings)
            }
            await reload()
        }
    }
}
