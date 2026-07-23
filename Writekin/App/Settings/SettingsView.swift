import SwiftUI

enum SettingsTabID: Hashable, Sendable {
    case general, filtering, timeline, sources
}

/// Standard macOS Settings window (⌘,) — the one home for every scattered
/// options surface: Filters (`FilterConfigStore`), Timeline (`ScanSettings`,
/// formerly labeled "AI Scan"; formerly Timeline's own "Scan Settings"
/// popover), and Sources (per-source ingest toggles plus, for Documents,
/// `DocumentRootsStore` — formerly a "Documents" tab holding only the folder
/// list, formerly the Sources card's folder-gear popover before that).
/// Opened from either screen via `SettingsLink` instead of a local popover,
/// and from a `SettingsLink` in `MainView`'s toolbar present on every tab.
///
/// Width is fixed at ~600 (a little roomier than the old 520, mostly for the
/// Timeline tab's advanced fields); height is deliberately left unset so each
/// tab sizes the window to its own content -- standard macOS Settings
/// behavior. Each tab's `Form` carries `.fixedSize(horizontal: false,
/// vertical: true)` to make that work: without it, `Form`/`List` report a
/// flexible ideal size and the window sizes to whatever it happened to open
/// at, inner-scrolling any content that doesn't fit instead of growing. The
/// one deliberate exception is the stock-phrase list box (genuinely
/// unbounded content), which keeps its own fixed-height inner `ScrollView`.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selection: SettingsTabID = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsTab()
                .tabItem { Label(Localization.shared.t(.tabGeneral), systemImage: "gearshape") }
                .tag(SettingsTabID.general)
            FilterSettingsTab()
                .tabItem { Label(Localization.shared.t(.tabFiltering), systemImage: "line.3.horizontal.decrease.circle") }
                .tag(SettingsTabID.filtering)
            ScanSettingsTab()
                .tabItem { Label(Localization.shared.t(.sectionTimeline), systemImage: "chart.xyaxis.line") }
                .tag(SettingsTabID.timeline)
            SourceSettingsTab()
                .tabItem { Label(Localization.shared.t(.sectionSources), systemImage: "tray.and.arrow.down") }
                .tag(SettingsTabID.sources)
        }
        .frame(width: 600)
        .safeAreaInset(edge: .bottom) {
            // Version footer (packaging plan Task 1) — the one place in
            // Settings the running version is always visible.
            Text(AppVersion.displayLine)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(.bar)
        }
        // Contextual gears deep-link here (see AppNavigation): consume the
        // requested tab whether the window is opening fresh (onAppear) or
        // already open (onChange), then clear it so a later plain gear
        // doesn't replay it.
        .onAppear { consumeRequestedTab() }
        .onChange(of: env.navigation.requestedSettingsTab) { _, _ in consumeRequestedTab() }
    }

    private func consumeRequestedTab() {
        // No deep-link request → open on General every time, instead of
        // whatever tab the (kept-alive) Settings view last showed.
        guard let requested = env.navigation.requestedSettingsTab else {
            selection = .general
            return
        }
        selection = requested
        env.navigation.requestedSettingsTab = nil
    }
}
