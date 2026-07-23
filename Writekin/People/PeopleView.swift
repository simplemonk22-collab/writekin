import SwiftUI

/// People: who the corpus is attributed to. Accounts admin (per-sender
/// identity/persona) and Audiences (contact → intimacy bucket mapping, with
/// corpus backfill).
///
/// A segmented switcher, deliberately NOT `TabView`: on macOS 26, TabView
/// hosting `Table`-based tabs inside a NavigationSplitView detail triggered
/// an AppKit layout recursion ("reentrant operation in its NSTableView
/// delegate") that corrupted the sidebar's own table — it rendered empty
/// and unrecoverable until relaunch. The segmented control + `switch` keeps
/// the same two screens without nesting AppKit tab machinery around them.
struct PeopleView: View {
    private enum Tab: CaseIterable {
        case accounts, audiences

        var titleKey: L10nKey {
            switch self {
            case .accounts: .peopleAccounts
            case .audiences: .peopleAudiences
            }
        }
    }

    @State private var tab: Tab = .accounts

    var body: some View {
        VStack(spacing: 0) {
            Picker(Localization.shared.t(.peopleSection), selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(Localization.shared.t(tab.titleKey)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .padding(.top, 10)
            .padding(.bottom, 4)
            switch tab {
            case .accounts: AccountsTab()
            case .audiences: AudiencesTab()
            }
        }
        .navigationTitle(MainSection.people.title)
    }
}
