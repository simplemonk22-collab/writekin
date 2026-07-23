import SwiftUI

// MARK: - Filtering

/// Edits the shared `FilterConfig` persisted by `FilterConfigStore` (read by
/// every `FilterPass` construction in `IngestCoordinator`), and offers the
/// same "Re-apply Filters" action as Sources/Timeline so a changed config
/// actually reclassifies the corpus. Only exposes fields `FilterConfig`
/// already supports — see `FilterConfigStoreTests` for the store's own
/// round-trip coverage.
struct FilterSettingsTab: View {
    @Environment(AppEnvironment.self) private var env
    @State private var config = FilterConfigStore.load()
    @State private var reapplying = false

    var body: some View {
        let loc = Localization.shared
        Form {
            Section(loc.t(.filterSectionLength)) {
                VStack(alignment: .leading) {
                    Stepper(loc.t(.filterMinWordsEmailDoc, config.minWordsEmailDoc),
                            value: $config.minWordsEmailDoc, in: 0...200)
                    Text(loc.t(.filterMinWordsEmailDocCaption))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Stepper(loc.t(.filterMinWordsChat, config.minWordsChat),
                            value: $config.minWordsChat, in: 0...200)
                    Text(loc.t(.filterMinWordsChatCaption))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section(loc.t(.filterSectionRatios)) {
                VStack(alignment: .leading) {
                    Text(loc.t(.filterQuoteThreshold, Int((config.quoteRatioFloor * 100).rounded())))
                    Slider(value: $config.quoteRatioFloor, in: 0...1)
                    Text(loc.t(.filterQuoteCaption, Int((config.quoteRatioFloor * 100).rounded())))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Text(loc.t(.filterLinksThreshold, Int((config.urlTokenRatioCeiling * 100).rounded())))
                    Slider(value: $config.urlTokenRatioCeiling, in: 0...1)
                    Text(loc.t(.filterLinksCaption, Int((config.urlTokenRatioCeiling * 100).rounded())))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section(loc.t(.filterSectionRules)) {
                VStack(alignment: .leading) {
                    Toggle(loc.t(.filterGameShares),
                           isOn: $config.gameShareEnabled)
                    Text(loc.t(.filterGameSharesCaption))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Picker(loc.t(.filterRequiredLanguage), selection: $config.requiredLang) {
                        Text("English").tag(String?.some("en"))
                        Text("Spanish").tag(String?.some("es"))
                        Text("French").tag(String?.some("fr"))
                        Text("German").tag(String?.some("de"))
                        Text("Italian").tag(String?.some("it"))
                        Text("Portuguese").tag(String?.some("pt"))
                        Text("Dutch").tag(String?.some("nl"))
                        Text("Japanese").tag(String?.some("ja"))
                        Text("Korean").tag(String?.some("ko"))
                        Text("Chinese (Simplified)").tag(String?.some("zh-Hans"))
                        Text(loc.t(.filterLangOff)).tag(String?.none)
                    }
                    Text(loc.t(.filterLangCaption))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Text(loc.t(.filterApplyNote))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(loc.t(.reapplyFilters)) {
                        Task { await reapply() }
                    }
                    .disabled(reapplying || env.ingest.isRunning || env.train.isBusy)
                    .help(env.train.isBusy
                          ? loc.t(.reapplyHelpTraining)
                          : loc.t(.reapplyHelp))
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: config.minWordsEmailDoc) { _, _ in save() }
        .onChange(of: config.minWordsChat) { _, _ in save() }
        .onChange(of: config.quoteRatioFloor) { _, _ in save() }
        .onChange(of: config.urlTokenRatioCeiling) { _, _ in save() }
        .onChange(of: config.gameShareEnabled) { _, _ in save() }
        .onChange(of: config.requiredLang) { _, _ in save() }
    }

    private func save() {
        FilterConfigStore.save(config)
    }

    private func reapply() async {
        reapplying = true
        defer { reapplying = false }
        await env.ingest.reapplyFilters(
            db: env.database,
            labelerFactory: AppEnvironment.labelerFactory(db: env.database, modelsRoot: AppEnvironment.modelsRoot))
    }
}
