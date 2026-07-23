// English language pack — the table lives in L10nTables+English.swift
// (too large to inline); the match vocabularies live here.

extension LanguagePack {
    static let english = LanguagePack(
        table: L10nTables.english,
        greetings: [
            "hi", "hey", "hello", "dear", "good morning", "good afternoon",
            "good evening", "greetings", "howdy", "yo",
        ],
        signoffs: [
            "thanks", "thank you", "best", "kind regards", "warm regards",
            "regards", "sincerely", "cordially", "cheers", "later",
            "talk soon", "take care", "warmly", "respectfully",
            "all the best", "yours", "xoxo", "-",
        ],
        casualWords: [
            "lol", "haha", "hahaha", "yeah", "yep", "nah", "ok", "okay",
            "btw", "omg", "gonna", "wanna", "gotta", "kinda", "thx", "rn",
            "tho", "hbu", "wyd", "lmk",
        ],
        assistantImperatives: [
            "write ", "make ", "create ", "generate ", "explain ",
            "summarize ", "fix ", "refactor ", "translate ", "give me ",
            "can you ", "help me ", "list ", "describe ",
        ])
}
