import AppKit
import SwiftUI

struct ItemBrowser: View {
    let db: AppDatabase
    let refreshToken: Bool

    @State private var filter = ItemFilter(medium: nil, state: "kept")
    @State private var searchText = ""
    @State private var items: [Item] = []
    /// Total rows matching the current filter — `items` is capped at
    /// `fetchLimit`, and the list footer + subtitle disclose the difference.
    @State private var totalCount = 0
    private let fetchLimit = 500
    @State private var selection: Set<Int64> = []
    @State private var showRaw = false
    @State private var folderConfirmation: FolderConfirmation?
    /// Configured document roots (raw paths) — the boundary for how far up
    /// the folder exclude/restore menus and breadcrumbs may reach.
    @State private var docRoots: [String] = []
    /// Reasons present for the current Kind, with counts — feeds the Reason
    /// picker shown while Status is Filtered.
    @State private var reasonCounts: [(reason: String, count: Int)] = []

    var body: some View {
        // Plain HStack, not HSplitView (which renegotiates widths and shoved
        // the list under macOS 26's floating sidebar). The list column takes a
        // clamped PERCENTAGE of the available width, and everything inside it
        // is clipped to that width — an over-wide child (e.g. the filter bar)
        // must never push content beyond the column on either side.
        // Filter bar spans the FULL window width above the split — the
        // pickers + search were cramped when boxed into the list column;
        // the split below it is purely list | detail.
        VStack(alignment: .leading, spacing: 0) {
            filterBar
            Divider()
            GeometryReader { geo in
                let listWidth = min(max(geo.size.width * 0.38, 320), 480)
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        if items.isEmpty {
                            emptyState
                        } else {
                            List(items, id: \.persistedID, selection: $selection) { item in
                                rowContent(for: item)
                                    .contextMenu {
                                        itemContextMenu(for: item)
                                    }
                            }
                            .listStyle(.inset(alternatesRowBackgrounds: true))
                            if totalCount > items.count {
                                Text(Localization.shared.t(.brShowingOf,
                                     items.count.formatted(), totalCount.formatted()))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.bar)
                            }
                        }
                    }
                    .frame(width: listWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topLeading)
                        .clipped()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Search lives in the filter bar, not `.searchable(placement:
        // .toolbar)`: toolbar items from a detail view merge AFTER
        // MainView's, which parked the search field to the RIGHT of the
        // settings gear — and the gear stays rightmost on every tab.
        // Semantically it belongs with the filters anyway.
        .task(id: searchText) {
            // Debounce: wait for the user to pause typing before refetching.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            filter.searchText = searchText
            refetch()
        }
        .navigationTitle(MainSection.browse.title)
        .task {
            docRoots = await DocumentRootsStore
                .load(settings: SettingsStore(db: db)).map(\.path)
        }
        .navigationSubtitle(Localization.shared.t(.ovItemsSubtitle, totalCount.formatted()))
        .task(id: refreshToken) { refreshReasonCounts(); refetch() }
        .onChange(of: filter.medium) { _, _ in refreshReasonCounts(); refetch() }
        .onChange(of: filter.state) { _, _ in
            if filter.state != "filtered_out" { filter.dropReason = nil }
            refreshReasonCounts()
            refetch()
        }
        .onChange(of: filter.dropReason) { _, _ in refetch() }
        .onChange(of: filter.sort) { _, _ in refetch() }
        .confirmationDialog(
            folderConfirmationTitle,
            isPresented: Binding(
                get: { folderConfirmation != nil },
                set: { if !$0 { folderConfirmation = nil } }),
            presenting: folderConfirmation
        ) { conf in
            Button(conf.isRestore
                       ? Localization.shared.t(.brRestoreFolder)
                       : Localization.shared.t(.brExcludeFolder),
                   role: conf.isRestore ? nil : .destructive) {
                Task { await applyFolderAction(conf) }
            }
            Button(Localization.shared.t(.cancel), role: .cancel) {}
        } message: { conf in
            Text(conf.isRestore
                 ? Localization.shared.t(.brRestoreHelpMany)
                 : Localization.shared.t(.brFolderExcludeMsg))
        }
    }

    private var folderConfirmationTitle: String {
        guard let conf = folderConfirmation else { return "" }
        return Localization.shared.t(
            conf.isRestore ? .brFolderConfirmRestore : .brFolderConfirmExclude,
            conf.count.formatted(), conf.displayPath)
    }

    /// Two flexible rows so the bar can never outgrow the list column
    /// (fixed-width pickers wider than the column were sliding the whole
    /// column under the sidebar).
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScreenCaption(text: Localization.shared.t(.brCaption, AppIdentity.appName))
            // Inline labels ("Kind: All") on one row — stacked caption
            // labels forced the pickers onto a second line in the clamped
            // column width.
            HStack(spacing: 12) {
                Picker(Localization.shared.t(.brKind), selection: $filter.medium) {
                    Text(Localization.shared.t(.brAll)).tag(String?.none)
                    Text(Localization.shared.t(.brEmail)).tag(String?.some("email"))
                    Text(Localization.shared.t(.brMessages)).tag(String?.some("sms"))
                    Text(Localization.shared.t(.brDocs)).tag(String?.some("doc"))
                    Text(Localization.shared.t(.brAIChats)).tag(String?.some("chat"))
                }
                .fixedSize()
                Picker(Localization.shared.t(.brStatus), selection: $filter.state) {
                    Text(Localization.shared.t(.brKept)).tag(String?.some("kept"))
                    Text(Localization.shared.t(.brFilteredState)).tag(String?.some("filtered_out"))
                    Text(Localization.shared.t(.brUnprocessed)).tag(String?.some("ingested"))
                    Text(Localization.shared.t(.brAll)).tag(String?.none)
                }
                .fixedSize()
                if filter.state == "filtered_out" {
                    Picker(Localization.shared.t(.brReason), selection: $filter.dropReason) {
                        Text(Localization.shared.t(.brAll)).tag(String?.none)
                        ForEach(reasonCounts, id: \.reason) { entry in
                            Text("\(ItemQuery.humanLabel(forDropReason: entry.reason)) (\(entry.count))")
                                .tag(String?.some(entry.reason))
                        }
                    }
                    .fixedSize()
                }
                Text(Localization.shared.t(.brSort)).font(.caption).foregroundStyle(.secondary)
                Picker(Localization.shared.t(.brSort), selection: $filter.sort) {
                    Text(Localization.shared.t(.brDate)).tag(ItemSort.date)
                    Text(Localization.shared.t(.brName)).tag(ItemSort.name)
                    Text(Localization.shared.t(.brFolder)).tag(ItemSort.folder)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                Spacer(minLength: 12)
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(Localization.shared.t(.brSearch), text: $searchText)
                        .textFieldStyle(.plain)
                        .onSubmit { filter.searchText = searchText; refetch() }
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 7))
                .frame(width: 260)
            }
            .font(.callout)
        }
        .padding(8)
    }

    @ViewBuilder
    private var emptyState: some View {
        if filter.searchText.isEmpty && filter.medium == nil && filter.state == "kept" {
            let waiting = (try? ItemQuery.unprocessedCount(db)) ?? 0
            if waiting > 0 {
                // Items landed but the processing passes haven't finished, so
                // nothing is "kept" yet — say so instead of looking empty.
                ContentUnavailableView(
                    Localization.shared.t(.brWaitingTitle, waiting.formatted()),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(Localization.shared.t(.brWaitingDesc)))
            } else {
                ContentUnavailableView(
                    Localization.shared.t(.brNoItems),
                    systemImage: "tray",
                    description: Text(Localization.shared.t(.brNoItemsDesc)))
            }
        } else {
            ContentUnavailableView.search(text: filter.searchText)
        }
    }

    // MARK: - Row rendering

    @ViewBuilder
    private func rowContent(for item: Item) -> some View {
        if item.kind == "doc" {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.docFilename ?? snippet(of: item))
                        .lineLimit(1)
                    if let ext = item.docExtension {
                        Text(ext)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                Text(item.docFolderPath ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet(of: item)).lineLimit(2)
                Text(metaLine(of: item))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detail: some View {
        if selection.count > 1 {
            multiSelectionDetail
        } else if let selectedID = selection.first,
                  let selected = items.first(where: { $0.persistedID == selectedID }) {
            singleItemDetail(selected)
        } else {
            Text(Localization.shared.t(.brSelectItem)).foregroundStyle(.secondary).padding()
        }
    }

    private var multiSelectionDetail: some View {
        let selectedItems = items.filter { selection.contains($0.persistedID) }
        let allExcludable = !selectedItems.isEmpty &&
            selectedItems.allSatisfy { $0.state == "kept" || $0.state == "ingested" }
        return VStack(spacing: 12) {
            Text(Localization.shared.t(.brNSelected, selection.count.formatted()))
                .font(.title3)
            if allExcludable {
                Button(Localization.shared.t(.brExcludeN, selectedItems.count.formatted())) {
                    Task { await excludeItems(selection) }
                }
                .help(Localization.shared.t(.brExcludeHelpMany))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func singleItemDetail(_ selected: Item) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Toggle(Localization.shared.t(.brShowRaw), isOn: $showRaw)
                        .toggleStyle(.checkbox)
                    Spacer()
                    itemActionButton(for: selected)
                }
                if selected.kind == "doc", selected.externalId != nil {
                    HStack(alignment: .firstTextBaseline) {
                        docBreadcrumb(for: selected)
                        Spacer()
                        Button(Localization.shared.t(.brReveal)) {
                            revealInFinder(selected)
                        }
                    }
                }
                GroupBox(Localization.shared.t(.brDetails)) {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(Localization.shared.t(.brMedium),
                                       value: KindLabels.medium(selected.kind))
                        if let ext = selected.docExtension {
                            LabeledContent(Localization.shared.t(.brType), value: ext)
                        }
                        if let date = selected.authoredAt {
                            LabeledContent(Localization.shared.t(.brDate),
                                           value: date.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let words = selected.wordCount {
                            LabeledContent(Localization.shared.t(.brWords), value: words.formatted())
                        }
                        if let reason = selected.dropReason {
                            LabeledContent(Localization.shared.t(.brFilteredState),
                                           value: ItemQuery.humanLabel(forDropReason: reason))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(showRaw ? selected.rawText : (selected.cleanText ?? selected.rawText))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
        }
    }

    /// The doc's folder path as tappable breadcrumb segments (root-first),
    /// each triggering the same folder exclude/restore confirmation flow as
    /// the context menu, followed by the (non-tappable) filename.
    @ViewBuilder
    private func docBreadcrumb(for item: Item) -> some View {
        if let path = item.externalId {
            let ancestors = Array(
                ItemQuery.ancestorPaths(of: path, stoppingAt: docRoots).reversed())
            BreadcrumbFlow(spacing: 2) {
                ForEach(ancestors, id: \.self) { dir in
                    HStack(spacing: 2) {
                        Button((dir as NSString).lastPathComponent) {
                            if item.state == "kept" || item.state == "ingested" {
                                requestExcludeFolder(prefix: dir)
                            } else if item.dropReason == "not_your_writing" {
                                requestRestoreFolder(prefix: dir)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .underline()
                        .help(Localization.shared.t(
                            item.dropReason == "not_your_writing"
                                ? .brRestoreFolderHelp : .brExcludeFolderHelp,
                            (dir as NSString).abbreviatingWithTildeInPath))
                        Text("/").foregroundStyle(.tertiary)
                    }
                }
                Text((path as NSString).lastPathComponent)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private func revealInFinder(_ item: Item) {
        guard let path = item.externalId else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Context menu

    @ViewBuilder
    private func itemContextMenu(for item: Item) -> some View {
        let ids = effectiveSelection(for: item)
        let selectedItems = items.filter { ids.contains($0.persistedID) }
        if ids.count > 1 {
            if selectedItems.allSatisfy({ $0.state == "kept" || $0.state == "ingested" }) {
                Button(Localization.shared.t(.brExcludeN, ids.count.formatted())) {
                    Task { await excludeItems(ids) }
                }
                .help(Localization.shared.t(.brExcludeHelpMany))
            } else if selectedItems.allSatisfy({ $0.dropReason == "not_your_writing" }) {
                Button(Localization.shared.t(.brRestoreN, ids.count.formatted())) {
                    Task { await restoreItems(ids) }
                }
                .help(Localization.shared.t(.brRestoreHelpMany))
            }
        } else {
            if item.state == "kept" || item.state == "ingested" {
                Button(Localization.shared.t(.brExclude)) {
                    Task { await excludeItems([item.persistedID]) }
                }
                .help(Localization.shared.t(.brExcludeHelpOne))
            } else if item.dropReason == "not_your_writing" {
                Button(Localization.shared.t(.brRestore)) {
                    Task { await restoreItems([item.persistedID]) }
                }
                .help(Localization.shared.t(.brRestoreHelpOne))
            }
        }

        if item.kind == "doc", let path = item.externalId {
            let ancestors = ItemQuery.ancestorPaths(of: path, stoppingAt: docRoots)
            if !ancestors.isEmpty {
                if item.state == "kept" || item.state == "ingested" {
                    Divider()
                    Menu(Localization.shared.t(.brExcludeFolder)) {
                        ForEach(ancestors, id: \.self) { dir in
                            Button("\((dir as NSString).abbreviatingWithTildeInPath)…") {
                                requestExcludeFolder(prefix: dir)
                            }
                        }
                    }
                } else if item.dropReason == "not_your_writing" {
                    Divider()
                    Menu(Localization.shared.t(.brRestoreFolder)) {
                        ForEach(ancestors, id: \.self) { dir in
                            Button("\((dir as NSString).abbreviatingWithTildeInPath)…") {
                                requestRestoreFolder(prefix: dir)
                            }
                        }
                    }
                }
            }
        }
    }

    /// When the right-clicked row is part of a multi-item selection, actions
    /// apply to the whole selection; otherwise they apply to just that row.
    private func effectiveSelection(for item: Item) -> Set<Int64> {
        if selection.count > 1 && selection.contains(item.persistedID) {
            return selection
        }
        return [item.persistedID]
    }

    @ViewBuilder
    private func itemActionButton(for item: Item) -> some View {
        if item.state == "kept" || item.state == "ingested" {
            Button(action: {
                Task { await excludeItems([item.persistedID]) }
            }) {
                Image(systemName: "xmark.circle")
            }
            .help(Localization.shared.t(.brExcludeHelpOne))
        } else if item.dropReason == "not_your_writing" {
            Button(action: {
                Task { await restoreItems([item.persistedID]) }
            }) {
                Image(systemName: "checkmark.circle")
            }
            .help(Localization.shared.t(.brRestoreHelpOne))
        }
    }

    // MARK: - Actions

    private func excludeItems(_ ids: Set<Int64>) async {
        for itemID in ids {
            do {
                try await ItemQuery.exclude(itemID: itemID, db: db)
            } catch {
                print("Failed to exclude item \(itemID): \(error)")
            }
        }
        selection.removeAll()
        refetch()
    }

    private func restoreItems(_ ids: Set<Int64>) async {
        for itemID in ids {
            do {
                try await ItemQuery.restore(itemID: itemID, db: db)
            } catch {
                print("Failed to restore item \(itemID): \(error)")
            }
        }
        selection.removeAll()
        refetch()
    }

    private func requestExcludeFolder(prefix: String) {
        let displayPath = (prefix as NSString).abbreviatingWithTildeInPath
        Task {
            let count = (try? ItemQuery.countExcludableInFolder(prefix: prefix, db: db)) ?? 0
            guard count > 0 else { return }
            folderConfirmation = FolderConfirmation(
                prefix: prefix, displayPath: displayPath, isRestore: false, count: count)
        }
    }

    private func requestRestoreFolder(prefix: String) {
        let displayPath = (prefix as NSString).abbreviatingWithTildeInPath
        Task {
            let count = (try? ItemQuery.countRestorableInFolder(prefix: prefix, db: db)) ?? 0
            guard count > 0 else { return }
            folderConfirmation = FolderConfirmation(
                prefix: prefix, displayPath: displayPath, isRestore: true, count: count)
        }
    }

    private func applyFolderAction(_ conf: FolderConfirmation) async {
        defer { folderConfirmation = nil }
        do {
            if conf.isRestore {
                try await ItemQuery.restoreFolder(prefix: conf.prefix, db: db)
            } else {
                try await ItemQuery.excludeFolder(prefix: conf.prefix, db: db)
            }
            selection.removeAll()
            refetch()
        } catch {
            print("Failed folder action: \(error)")
        }
    }

    private func snippet(of item: Item) -> String {
        String((item.cleanText ?? item.rawText).prefix(120))
    }

    private func metaLine(of item: Item) -> String {
        var parts = [KindLabels.medium(item.kind)]
        if let date = item.authoredAt {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        if let words = item.wordCount {
            parts.append(Localization.shared.t(.brWordsCount, "\(words)"))
        }
        if let reason = item.dropReason {
            parts.append(ItemQuery.humanLabel(forDropReason: reason))
        }
        return parts.joined(separator: " · ")
    }

    private func refetch() {
        items = (try? ItemQuery.fetch(db, filter: filter, limit: fetchLimit)) ?? []
        totalCount = (try? ItemQuery.count(db, filter: filter)) ?? items.count
    }

    private func refreshReasonCounts() {
        reasonCounts = (try? ItemQuery.dropReasonCounts(db, medium: filter.medium)) ?? []
        // The selected reason may not exist under the new Kind — clear it.
        if let selected = filter.dropReason,
           !reasonCounts.contains(where: { $0.reason == selected }) {
            filter.dropReason = nil
        }
    }
}

/// Minimal left-aligned wrapping layout for the breadcrumb: segments flow
/// horizontally and wrap to new lines when the detail pane is narrow, so a
/// deep path never forces horizontal scrolling.
private struct BreadcrumbFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0
        var rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return CGSize(width: maxWidth.isFinite ? min(usedWidth, maxWidth) : usedWidth,
                      height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Pending confirmation for a folder-scale exclude/restore, shown before the
/// destructive (or corrective) bulk action runs.
private struct FolderConfirmation: Identifiable {
    let id = UUID()
    let prefix: String        // raw (non-abbreviated) path prefix for the LIKE match
    let displayPath: String   // ~-abbreviated path for the confirmation message
    let isRestore: Bool
    let count: Int
}
