import Foundation
@testable import Writekin

// Shared fixtures for the whole test target. `Item.stub` began life inside
// MigrationV2Tests and quietly became the standard item factory for ~85
// call sites — it lives here so nobody has to know that history.
extension Item {
    static func stub(sourceId: Int64, externalId: String, rawText: String) -> Item {
        Item(id: nil, sourceId: sourceId, accountId: nil, externalId: externalId,
             kind: "email", authoredAt: nil, recipientsJson: "[]", threadId: nil,
             rawText: rawText, cleanText: nil, wordCount: nil, lang: nil,
             sha256: UUID().uuidString, simhash64: nil, provenance: "native",
             state: "ingested", dropReason: nil, medium: nil, audience: nil,
             mode: nil, labelSource: nil, qualityScore: nil, dateConfidence: nil)
    }
}
