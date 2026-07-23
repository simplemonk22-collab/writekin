import Testing
import SwiftUI
@testable import Writekin

struct MediumScaleTests {
    /// An explicitly-scoped `.chartForegroundStyleScale` TRAPS at render
    /// time when a mark's series value is missing from it — adding the
    /// "chat" medium without extending this scale crashed the app on the
    /// Overview charts. Every ItemKind must have a color, forever.
    @Test func everyItemKindHasAChartColor() {
        let covered = Set(CorpusChartsSection.mediumScale.map(\.key))
        for kind in ItemKind.allCases {
            #expect(covered.contains(kind.rawValue),
                    "ItemKind.\(kind.rawValue) missing from CorpusChartsSection.mediumScale — this crashes the Overview charts at render")
        }
    }
}
