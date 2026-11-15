import Foundation

// MARK: - LyricsTitleSanitizer

/// Utility to clean track titles and artist names before querying lyrics APIs (LRCLIB, Lyrics.ovh).
///
/// Strips noise patterns such as:
/// - `(Official Video)`, `(Official Music Video)`, `(Official Audio)`, `(Visualizer)`
/// - `[Official Video]`, `[Lyrics]`, `(Lyrics)`, `[Lyric Video]`, `(Lyric Video)`
/// - `(feat. ...)`, `[feat. ...]`, `ft. ...`, `feat. ...`
/// - `(Remastered 2011)`, `(Live ...)`
/// - Channel suffixes like ` - Topic`
public enum LyricsTitleSanitizer {
    private static let bracketPatterns: [String] = [
        // Parentheses with metadata
        #"\(.*?(?:official\s*(?:video|audio|music\s*video)?|music\s*video|audio|lyrics?|visualizer|remaster(?:ed)?|live|explicit|hd|4k).*?\)"#,
        // Square brackets with metadata
        #"\[.*?(?:official\s*(?:video|audio|music\s*video)?|music\s*video|audio|lyrics?|visualizer|remaster(?:ed)?|live|explicit|hd|4k).*?\]"#,
        // Featuring tags in parentheses or brackets
        #"\(.*?(?:feat|ft)\.?\s+[^\)]+\)"#,
        #"\[.*?(?:feat|ft)\.?\s+[^\]]+\]"#,
    ]

    private static let trailingPatterns: [String] = [
        // Standalone featuring tags outside brackets (e.g. "Song feat. Artist")
        #"\s+(?:feat|ft)\.?\s+.+$"#,
        // Trailing hyphen/pipe descriptions (e.g. " - Official Video", " | Official Audio")
        #"\s*[-|–—]\s*(?:official\s*(?:video|audio|music\s*video)?|music\s*video|audio|lyrics?|visualizer|remaster(?:ed)?|live).*$"#,
    ]

    /// Returns a cleaned version of the song title suitable for lyrics database searches.
    public static func sanitizeTitle(_ rawTitle: String) -> String {
        var cleaned = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Remove bracketed noise
        for pattern in self.bracketPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
            }
        }

        // 2. Remove trailing noise patterns
        for pattern in self.trailingPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
            }
        }

        // 3. Clean up multiple spaces, leftover dashes, quotes
        cleaned = cleaned.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " -|–—\"'").union(.whitespacesAndNewlines))

        // If sanitation stripped everything, fall back to the original trimmed title
        return cleaned.isEmpty ? rawTitle.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    /// Returns a cleaned version of the artist name suitable for lyrics database searches.
    public static func sanitizeArtist(_ rawArtist: String) -> String {
        var cleaned = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip " - Topic" suffix added by YouTube auto-generated art tracks
        if cleaned.hasSuffix(" - Topic") {
            cleaned = String(cleaned.dropLast(" - Topic".count))
        }

        // Strip "VEVO" suffix
        if cleaned.hasSuffix("VEVO") {
            cleaned = String(cleaned.dropLast("VEVO".count))
        }

        // If artist contains multiple comma or slash separated artists, keep the primary artist
        // E.g. "Dua Lipa & DaBaby" -> "Dua Lipa", "Coldplay, BTS" -> "Coldplay"
        let separators = [" & ", ", ", " feat. ", " ft. ", " / "]
        for sep in separators {
            if let range = cleaned.range(of: sep, options: .caseInsensitive) {
                let primary = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !primary.isEmpty {
                    cleaned = primary
                    break
                }
            }
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? rawArtist.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }
}
