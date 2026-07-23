import SwiftUI

struct DetectView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Localization.shared.t(.detectTitle))
                .font(.title.bold())
            Text(Localization.shared.t(.detectBody, AppIdentity.appName))
                .foregroundStyle(.secondary)
            // Scrolls: seven sources of cards outgrew the window (the
            // original four fit) — an unscrolled VStack pushed the
            // Continue button clean off the bottom edge, dead-ending the
            // tour with no visible way forward.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(SourceKind.allCases, id: \.self) { kind in
                        SourceCardView(kind: kind, state: env.runner.cards[kind] ?? .scanning)
                    }
                }
            }
            HStack {
                if !allResolved {
                    Text(Localization.shared.t(.detectStillScanning))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Never a hostage: a slow (or wedged) detector must not be
                // able to dead-end onboarding, so Continue is always live.
                Button(Localization.shared.t(.continueButton)) { env.flow.advance() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .task {
            let roots = await DocumentRootsStore.load(settings: env.settings)
            await env.runner.run(adapters: AppEnvironment.defaultAdapters(documentRoots: roots))
        }
    }

    private var allResolved: Bool {
        SourceKind.allCases.allSatisfy { (env.runner.cards[$0] ?? .scanning) != .scanning }
    }
}
