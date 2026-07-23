import SwiftUI
import Charts
import GRDB

struct YearMediumCount: Identifiable, Equatable, Sendable {
    var id: String { "\(year)-\(medium)" }
    let year: Int
    let medium: String
    let count: Int
}

struct AccountYearCount: Identifiable, Equatable, Sendable {
    var id: String { "\(account)-\(year)" }
    let account: String
    let year: Int
    let count: Int
}

struct WordBucketCount: Identifiable, Equatable, Sendable {
    var id: String { "\(medium)-\(bucket)" }
    let medium: String
    let bucket: Int
    let count: Int
}

enum ChartDataQuery {
    static func itemsPerYearByMedium(_ db: AppDatabase) throws -> [YearMediumCount] {
        try db.writer.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT CAST(strftime('%Y', authored_at) AS INTEGER) AS y, kind, COUNT(*) AS c
                FROM items WHERE state = 'kept' AND authored_at IS NOT NULL
                GROUP BY y, kind ORDER BY y
                """)
                // `strftime` (and so `y`) is NULL for a row whose
                // `authored_at` fails to parse — decode as `Int?` and drop
                // those defensively rather than crash or let a bogus "year
                // 0" plot.
                .compactMap { row -> YearMediumCount? in
                    guard let year = row["y"] as Int? else { return nil }
                    return YearMediumCount(year: year, medium: row["kind"], count: row["c"])
                }
        }
    }

    static func volumeByAccountYear(_ db: AppDatabase, topAccounts: Int = 8) throws -> [AccountYearCount] {
        try db.writer.read { dbc in
            try Row.fetchAll(dbc, sql: """
                WITH top AS (
                    SELECT account_id FROM items
                    WHERE state = 'kept' AND account_id IS NOT NULL
                    GROUP BY account_id ORDER BY COUNT(*) DESC LIMIT ?
                )
                SELECT accounts.address_or_handle AS a,
                       CAST(strftime('%Y', authored_at) AS INTEGER) AS y,
                       COUNT(*) AS c
                FROM items
                JOIN accounts ON accounts.id = items.account_id
                WHERE items.state = 'kept' AND items.authored_at IS NOT NULL
                  AND items.account_id IN (SELECT account_id FROM top)
                GROUP BY a, y ORDER BY y
                """, arguments: [topAccounts])
                // Same defensive drop as `itemsPerYearByMedium` — a row whose
                // `authored_at` didn't parse decodes `y` as NULL.
                .compactMap { row -> AccountYearCount? in
                    guard let year = row["y"] as Int? else { return nil }
                    return AccountYearCount(account: row["a"], year: year, count: row["c"])
                }
        }
    }

    static func wordDistribution(_ db: AppDatabase) throws -> [WordBucketCount] {
        let buckets = [8, 16, 32, 64, 128, 256, 512, 1024]
        let rows: [(String, Int)] = try db.writer.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT kind, word_count FROM items
                WHERE state = 'kept' AND word_count IS NOT NULL
                """).map { ($0["kind"], $0["word_count"]) }
        }
        var counts: [String: [Int: Int]] = [:]
        for (kind, words) in rows {
            let bucket = buckets.last(where: { words >= $0 }) ?? buckets[0]
            counts[kind, default: [:]][bucket, default: 0] += 1
        }
        return counts.flatMap { kind, byBucket in
            byBucket.map { WordBucketCount(medium: kind, bucket: $0.key, count: $0.value) }
        }.sorted { ($0.medium, $0.bucket) < ($1.medium, $1.bucket) }
    }
}

struct CorpusChartsSection: View {
    let db: AppDatabase
    let refreshToken: Bool

    @State private var yearMedium: [YearMediumCount] = []
    @State private var accountYears: [AccountYearCount] = []
    @State private var wordBuckets: [WordBucketCount] = []

    /// Shared categorical scale so a medium reads as the same color across
    /// every chart on the Overview page. MUST cover every `ItemKind`: an
    /// explicitly-scoped chart scale TRAPS on unknown series values — the
    /// "chat" medium crashed the app the first time chat items reached
    /// these charts (`MediumScaleTests` pins full coverage).
    static let mediumScale: KeyValuePairs<String, Color> = [
        "email": Color.accentColor, "sms": .teal, "doc": .orange,
        "chat": .purple,
    ]

    /// The same scale keyed by the LOCALIZED medium labels the charts now
    /// plot, so the legend shows "Correo"/"Mensajes"/… while `mediumScale`
    /// keeps its raw keys (pinned by `MediumScaleTests` for ItemKind
    /// coverage). Derived, so it can't drift from the canonical scale.
    private var localizedScaleDomain: [String] {
        Self.mediumScale.map { KindLabels.medium($0.key) }
    }
    private var localizedScaleRange: [Color] {
        Self.mediumScale.map(\.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !yearMedium.isEmpty {
                GroupBox(Localization.shared.t(.chartCorpusOverTime)) {
                    // Year plotted as a categorical (String) label rather
                    // than an Int on a continuous axis — a continuous axis
                    // let Swift Charts pick its own domain/tick formatting,
                    // which defaulted to comma-grouped values ("2,000") and
                    // bunched every year near the low end of its scale.
                    Chart(yearMedium) { row in
                        BarMark(x: .value("Year", String(row.year)),
                                y: .value("Items", row.count))
                            .foregroundStyle(by: .value("Medium", KindLabels.medium(row.medium)))
                    }
                    .chartForegroundStyleScale(domain: localizedScaleDomain,
                                               range: localizedScaleRange)
                    .chartXAxisLabel(Localization.shared.t(.chartYear))
                    .chartYAxisLabel(Localization.shared.t(.chartItems))
                    .frame(height: 180)
                }
            }
            if !accountYears.isEmpty {
                GroupBox(Localization.shared.t(.chartByAccount)) {
                    Chart(accountYears) { row in
                        LineMark(x: .value("Year", String(row.year)),
                                 y: .value("Items", row.count))
                            .foregroundStyle(by: .value("Account", row.account))
                    }
                    .chartXAxisLabel(Localization.shared.t(.chartYear))
                    .chartYAxisLabel(Localization.shared.t(.chartItems))
                    .frame(height: 160)
                }
            }
            if !wordBuckets.isEmpty {
                GroupBox(Localization.shared.t(.chartWordsPerItem)) {
                    Chart(wordBuckets) { row in
                        BarMark(x: .value("Words ≥", "\(row.bucket)"),
                                y: .value("Items", row.count))
                            .foregroundStyle(by: .value("Medium", KindLabels.medium(row.medium)))
                            .position(by: .value("Medium", KindLabels.medium(row.medium)))
                    }
                    .chartForegroundStyleScale(domain: localizedScaleDomain,
                                               range: localizedScaleRange)
                    .chartXAxisLabel(Localization.shared.t(.chartWordsPerItem))
                    .chartYAxisLabel(Localization.shared.t(.chartItems))
                    .frame(height: 160)
                }
            }
        }
        .groupBoxStyle(.automatic)
        .task(id: refreshToken) { refetch() }
    }

    private func refetch() {
        yearMedium = (try? ChartDataQuery.itemsPerYearByMedium(db)) ?? []
        accountYears = (try? ChartDataQuery.volumeByAccountYear(db)) ?? []
        wordBuckets = (try? ChartDataQuery.wordDistribution(db)) ?? []
    }
}
