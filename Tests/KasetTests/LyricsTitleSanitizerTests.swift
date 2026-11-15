import Testing
@testable import KasetPlus

@Suite("LyricsTitleSanitizer")
struct LyricsTitleSanitizerTests {
    @Test(
        "Strips noise from titles",
        arguments: [
            ("Blinding Lights (Official Video)", "Blinding Lights"),
            ("Levitating [Official Audio]", "Levitating"),
            ("Shape of You (Lyrics)", "Shape of You"),
            ("Bad Habits [Lyric Video]", "Bad Habits"),
            ("Stay (feat. Justin Bieber)", "Stay"),
            ("Peaches ft. Daniel Caesar", "Peaches"),
            ("Heat Waves - Official Music Video", "Heat Waves"),
            ("Yellow (Remastered 2011)", "Yellow"),
            ("Plain Title", "Plain Title"),
        ]
    )
    func sanitizesTitle(input: String, expected: String) {
        #expect(LyricsTitleSanitizer.sanitizeTitle(input) == expected)
    }

    @Test("Never returns an empty title")
    func neverEmpty() {
        #expect(LyricsTitleSanitizer.sanitizeTitle("(Official Video)") == "(Official Video)")
    }

    @Test(
        "Cleans artist names",
        arguments: [
            ("Coldplay - Topic", "Coldplay"),
            ("TaylorSwiftVEVO", "TaylorSwift"),
            ("Dua Lipa & DaBaby", "Dua Lipa"),
            ("Coldplay, BTS", "Coldplay"),
            ("Adele", "Adele"),
        ]
    )
    func sanitizesArtist(input: String, expected: String) {
        #expect(LyricsTitleSanitizer.sanitizeArtist(input) == expected)
    }
}
