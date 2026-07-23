import Foundation

/// Curated list of words/phrases that skew heavily toward LLM-generated prose
/// ("AI tics"). Matched case-insensitively as substrings against lowercased
/// text in `ContaminationScan.metrics`.
enum TicLexicon {
    static let words: [String] = [
        "delve", "delved", "delving", "tapestry", "furthermore", "moreover",
        "additionally", "it's worth noting", "in conclusion", "vibrant",
        "crucial", "pivotal", "landscape", "leverage", "utilize", "robust",
        "seamless", "comprehensive", "notably", "underscore", "spearhead",
        "foster", "harness", "navigate the", "in the realm of",
        "it is important to note", "dive into", "embark", "elevate", "unlock",
        "game-changer", "cutting-edge", "at the end of the day", "as an ai",
        "i hope this email finds you well", "boasts", "testament to",
        "plays a vital role", "multifaceted", "in today's fast-paced",
        "unwavering", "holistic", "synergy", "paradigm shift", "myriad",
        "invaluable", "trailblazing", "ever-evolving",
    ]
}
