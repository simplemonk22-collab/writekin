import Foundation

struct FilterConfig: Sendable, Codable {
    var minWordsEmailDoc = 30
    var minWordsChat = 8
    var quoteRatioFloor = 0.3
    var urlTokenRatioCeiling = 0.5
    var requiredLang: String? = "en"
    /// When false, the game-share rule (Wordle/Connections/Strands/etc. emoji
    /// grids) is skipped entirely — those items fall through to the
    /// remaining rules like everything else.
    var gameShareEnabled = true
}
