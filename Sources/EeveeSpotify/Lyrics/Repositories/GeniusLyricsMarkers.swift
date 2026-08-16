import Foundation

struct GeniusLyricsMarkerConfiguration {
    let sectionMarkers: [String]
    let metadataPrefixes: [String]
    let titlePrefixPatterns: [String]

    static let shared = GeniusLyricsMarkerConfiguration(
        sectionMarkers: [
            "INTRO(DUCAO)?",
            "VERSE", "VERSO",
            "CHORUS", "REFRAO",
            "PRE[- ]?CHORUS", "PRE[- ]?REFRAO",
            "POST?[- ]?CHORUS", "POS[- ]?REFRAO",
            "BRIDGE", "PONTE",
            "HOOK", "GANCHO",
            "INTERLUDE", "INTERLUDIO",
            "SOLO", "INSTRUMENTAL",
            "OUTRO", "ENCERRAMENTO",
            "DROP",
            "BREAK(DOWN)?",
            "FADE[ ]?OUT",
            "LOOP",
            "PRE[- ]?OUTRO",
            "PRE[- ]?SAIDA",
            "SAIDA",
            "RANN", "SEIST",
            "PRE[- ]?CORO", "CORO"
        ],
        metadataPrefixes: [
            "PRODUCED BY",
            "WRITTEN BY",
            "COMPOSED BY",
            "TRANSLATED BY",
            "注释"
        ],
        titlePrefixPatterns: [
            "TEKISUTO\\s+O\\s+LETRA DE",
            "LETRA DE",
            "TEXT OF"
        ]
    )
}
