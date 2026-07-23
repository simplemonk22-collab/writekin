// Spanish language pack — the table lives in L10nTables+Spanish.swift
// (too large to inline); the match vocabularies live here.

extension LanguagePack {
    static let spanish = LanguagePack(
        table: L10nTables.spanish,
        greetings: [
            "hola", "buenos días", "buenas tardes", "buenas noches",
            "estimado", "estimada", "querido", "querida",
        ],
        signoffs: [
            "gracias", "saludos", "un saludo", "atentamente", "cordialmente",
            "un abrazo", "abrazos", "besos", "hasta pronto", "nos vemos",
        ],
        casualWords: [
            "jaja", "jajaja", "vale", "oye", "va", "porfa", "qué tal", "dale",
        ],
        assistantImperatives: [
            "escribe ", "haz ", "crea ", "genera ", "explica ", "resume ",
            "arregla ", "traduce ", "dame ", "puedes ", "ayúdame ",
        ])
}
