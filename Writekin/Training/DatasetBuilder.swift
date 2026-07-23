import Foundation
import GRDB

/// The eligibility criteria + cap + generator recorded in `filter_json` so a
/// dataset is reproducible in principle (spec §4).
struct DatasetFilter: Codable, Equatable, Sendable {
    var itemCap: Int
    var generatorModelID: String
    var minWordCountSMS: Int = 8
    var minWordCountEmailDoc: Int = 30
    var targetClip: Int = 4_000
}

/// Pair counts by type/split/register cell + total target words (`stats_json`).
struct DatasetStats: Codable, Equatable, Sendable {
    var pairsByType: [String: Int]
    var pairsBySplit: [String: Int]
    var pairsByCell: [String: Int]
    var totalTargetWords: Int
    /// Count of pairs whose `input_text` carries reply-context (starts with
    /// "Context:" — see `PairGenerator.context(for:)`). Additive/optional so
    /// a dataset snapshotted before this field existed decodes fine with
    /// `nil` rather than failing the whole `DatasetStats` decode.
    var contextPairCount: Int?
}

enum DatasetError: Error, Equatable {
    case noPendingPairs
}

/// Pure formatting for dataset visibility (Train screen dataset picker + the
/// read-only "Datasets" list): a dataset's bare `name` alone doesn't tell you
/// whether it's the 200-item smoke test or the 8,000-item real run, so every
/// place a dataset appears gets a one-line summary decoded from its
/// `stats_json`/`exported_at`.
enum DatasetSummary {
    /// "Dataset 3 — 7,912 pairs (6,200 train / 1,712 heldout) · Jul 20". A
    /// dataset with no decodable stats (predates `stats_json`, or corrupt)
    /// falls back to just the name + date so the row never looks blank.
    /// `@MainActor`: produces user-facing text through `Localization`.
    @MainActor
    static func line(name: String, statsJson: String?, exportedAt: Date?) -> String {
        var line = name
        if let stats = decodeStats(statsJson) {
            let total = stats.pairsByType.values.reduce(0, +)
            let train = stats.pairsBySplit["train"] ?? 0
            let heldout = stats.pairsBySplit["heldout"] ?? 0
            line += Localization.shared.t(.trDsPairsCount, formatCount(total))
            if total > 0 {
                line += Localization.shared.t(.trDsSplit, formatCount(train),
                                              formatCount(heldout))
            }
        }
        if let exportedAt {
            line += " · " + dateFormatter.string(from: exportedAt)
        }
        return line
    }

    static func decodeStats(_ json: String?) -> DatasetStats? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DatasetStats.self, from: data)
    }

    /// Exposed (not `private`) so other Train-screen formatting — e.g. the
    /// dataset row's pair-count line — can share the same "3,940" grouping
    /// without re-implementing it.
    static func formatCount(_ n: Int) -> String {
        numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

/// Turns the pending pairs of a finished `PairGenerator` run into an
/// immutable `datasets` row (spec §4): inserts the row, stamps its id onto
/// every `dataset_id IS NULL` pair, and stores filter/stats JSON. No JSONL
/// file is ever written to disk — the trainer reads pairs from the DB.
struct DatasetBuilder: Sendable {
    let db: AppDatabase

    func snapshot(name: String, filter: DatasetFilter) async throws -> Int64 {
        let filterJSON = String(data: try JSONEncoder().encode(filter), encoding: .utf8) ?? "{}"
        return try await db.writer.write { dbc in
            let pending = try Pair.filter(Column("dataset_id") == nil).fetchAll(dbc)
            guard !pending.isEmpty else { throw DatasetError.noPendingPairs }

            var byType: [String: Int] = [:]
            var bySplit: [String: Int] = [:]
            var byCell: [String: Int] = [:]
            var words = 0
            var contextCount = 0
            for pair in pending {
                byType[pair.pairType, default: 0] += 1
                bySplit[pair.split, default: 0] += 1
                byCell[pair.systemTags, default: 0] += 1
                words += pair.targetText.split(whereSeparator: \.isWhitespace).count
                // Equivalent to `input_text LIKE 'Context:%'` — computed from
                // the already-fetched `pending` rows instead of a second
                // query, since PairGenerator.context(for:) always prefixes
                // context-carrying pairs with this exact literal.
                if pair.inputText.hasPrefix("Context:") { contextCount += 1 }
            }
            let stats = DatasetStats(pairsByType: byType, pairsBySplit: bySplit,
                                     pairsByCell: byCell, totalTargetWords: words,
                                     contextPairCount: contextCount)
            let statsJSON = String(data: try JSONEncoder().encode(stats), encoding: .utf8)

            var dataset = Dataset(id: nil, name: name, filterJson: filterJSON,
                                  statsJson: statsJSON, exportedAt: Date())
            try dataset.insert(dbc)
            // Default-named datasets are renamed to their ROW id: names were
            // previously "Dataset (count+1)", which drifts off the ids as
            // soon as one dataset is deleted — real DB ended up with two
            // "Dataset 4"s while run cards (which print the id) referenced
            // a "Dataset 6" the list never showed. A caller-provided custom
            // name is kept as-is.
            if name.hasPrefix("Dataset ") {
                try dbc.execute(sql: "UPDATE datasets SET name = ? WHERE id = ?",
                                arguments: ["Dataset \(dataset.id!)", dataset.id])
            }
            try dbc.execute(sql: "UPDATE pairs SET dataset_id = ? WHERE dataset_id IS NULL",
                            arguments: [dataset.id])
            return dataset.id!
        }
    }
}
