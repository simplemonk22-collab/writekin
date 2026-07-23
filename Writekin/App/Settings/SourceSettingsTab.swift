import SwiftUI

// MARK: - Sources

/// Lists the four ingest sources (`SourceKind.allCases`) behind a compact
/// segmented sub-picker, each showing its include-in-ingest `Toggle` bound to
/// the same `env.toggles` store `SourceIngestRow` uses on the Sources screen
/// — editing either place updates the other, since both bindings just read
/// and write `SourceToggles`. Below the toggle, each source shows whatever
/// per-source settings it has: Documents gets the restyled folder list
/// (`DocumentFoldersSettings`); the rest have nothing further configurable
/// yet and say so.
struct SourceSettingsTab: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selectedKind: SourceKind = .appleMail

    var body: some View {
        sourceTabBody
            // Second half of the contextual-gear deep link: land on the
            // requested source's sub-segment (e.g. Documents), then clear.
            .onAppear { consumeRequestedSource() }
            .onChange(of: env.navigation.requestedSettingsSource) { _, _ in
                consumeRequestedSource()
            }
    }

    private func consumeRequestedSource() {
        guard let requested = env.navigation.requestedSettingsSource else { return }
        selectedKind = requested
        env.navigation.requestedSettingsSource = nil
    }

    private var sourceTabBody: some View {
        VStack(spacing: 0) {
            // A menu, not segments: seven sources' names overflow the
            // window's fixed 600pt as segments, and every future source
            // would make it worse — a dropdown scales indefinitely.
            HStack {
                Picker(Localization.shared.t(.sourcePickerLabel), selection: $selectedKind) {
                    ForEach(SourceKind.allCases, id: \.self) { kind in
                        Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Form {
                Section {
                    Toggle(Localization.shared.t(.sourceInclude, selectedKind.displayName),
                           isOn: enabledBinding(selectedKind))
                }
                Section {
                    if selectedKind == .fileSystem {
                        DocumentFoldersSettings()
                    } else {
                        Text(Localization.shared.t(.sourceNoSettings))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func enabledBinding(_ kind: SourceKind) -> Binding<Bool> {
        Binding(get: { env.toggles.isEnabled(kind) },
                set: { env.toggles.set($0, for: kind) })
    }
}
