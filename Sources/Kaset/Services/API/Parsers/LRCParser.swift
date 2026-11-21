import Foundation

// MARK: - LRCParser

enum LRCParser {
    private static let timeRegex = try? NSRegularExpression(pattern: "\\[(\\d{2,}):(\\d{2})\\.(\\d{2,3})\\]")
    private static let metadataRegex = try? NSRegularExpression(pattern: "\\[([a-z]+):([^\\]]+)\\]")
    private static let pureMetadataRegex = try? NSRegularExpression(pattern: "^\\[([a-z]+):([^\\]]+)\\]\\s*$")
    private static let wordRegex = try? NSRegularExpression(pattern: "<(\\d{2,}):(\\d{2})\\.(\\d{2,3})>([^<]+)")

    static func parse(_ raw: String) -> SyncedLyrics? {
        var unmergedLines: [SyncedLyricLine] = []
        var offsetMs = 0

        let lines = raw.components(separatedBy: .newlines)

        for line in lines {
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            // Check for metadata
            if let metaMatch = Self.metadataRegex?.firstMatch(in: line, options: [], range: fullRange) {
                let key = nsLine.substring(with: metaMatch.range(at: 1)).lowercased()
                let value = nsLine.substring(with: metaMatch.range(at: 2)).trimmingCharacters(in: .whitespaces)

                if key == "offset", let offset = Int(value) {
                    offsetMs = offset
                }

                // If it's pure metadata and has no lyric text or time tag, skip
                if Self.pureMetadataRegex?.firstMatch(in: line, options: [], range: fullRange) != nil {
                    continue
                }
            }

            guard let regex = Self.timeRegex else { continue }
            let matches = regex.matches(in: line, options: [], range: fullRange)

            if matches.isEmpty {
                continue
            }

            // Text extraction
            var textOnly = regex.stringByReplacingMatches(in: line, options: [], range: fullRange, withTemplate: "")

            // Find word level timing
            var words: [TimedWord]?
            if let wRegex = Self.wordRegex {
                let nsText = textOnly as NSString
                let wMatches = wRegex.matches(in: textOnly, options: [], range: NSRange(location: 0, length: nsText.length))
                if !wMatches.isEmpty {
                    var extracted: [TimedWord] = []
                    for match in wMatches {
                        let mm = Int(nsText.substring(with: match.range(at: 1))) ?? 0
                        let ss = Int(nsText.substring(with: match.range(at: 2))) ?? 0
                        let msStr = nsText.substring(with: match.range(at: 3))
                        let ms = Self.parseCentsToMs(msStr)
                        let time = max(0, (mm * 60 * 1000) + (ss * 1000) + ms - offsetMs)
                        let word = nsText.substring(with: match.range(at: 4))
                        extracted.append(TimedWord(timeInMs: time, word: word))
                    }
                    words = extracted
                    textOnly = wRegex.stringByReplacingMatches(in: textOnly, options: [], range: NSRange(location: 0, length: nsText.length), withTemplate: "$4")
                }
            }

            textOnly = textOnly.trimmingCharacters(in: .whitespaces)

            for match in matches {
                let mm = Int(nsLine.substring(with: match.range(at: 1))) ?? 0
                let ss = Int(nsLine.substring(with: match.range(at: 2))) ?? 0
                let msStr = nsLine.substring(with: match.range(at: 3))
                let ms = Self.parseCentsToMs(msStr)

                let timeMs = (mm * 60 * 1000) + (ss * 1000) + ms - offsetMs

                unmergedLines.append(SyncedLyricLine(
                    timeInMs: max(0, timeMs),
                    duration: 0,
                    text: textOnly,
                    words: words
                ))
            }
        }

        if unmergedLines.isEmpty {
            return nil
        }

        unmergedLines.sort { $0.timeInMs < $1.timeInMs }

        var processedLines: [SyncedLyricLine] = []

        // Auto-insert empty line at 0ms if first > 300ms
        if let first = unmergedLines.first, first.timeInMs > 300 {
            processedLines.append(SyncedLyricLine(timeInMs: 0, duration: first.timeInMs, text: "", words: nil))
        }

        for i in 0 ..< unmergedLines.count {
            var line = unmergedLines[i]
            if i < unmergedLines.count - 1 {
                let next = unmergedLines[i + 1]
                line.duration = next.timeInMs - line.timeInMs
            } else {
                line.duration = 5000 // default 5 seconds end blank
            }
            processedLines.append(line)
        }

        return SyncedLyrics(lines: processedLines, source: "Parsed")
    }

    /// Encodes SyncedLyrics back into standard LRC formatted string.
    static func encode(_ synced: SyncedLyrics) -> String {
        synced.lines.map { line in
            let totalMs = line.timeInMs
            let minutes = totalMs / 60000
            let seconds = (totalMs % 60000) / 1000
            let hundredths = (totalMs % 1000) / 10
            return String(format: "[%02d:%02d.%02d]%@", minutes, seconds, hundredths, line.text)
        }.joined(separator: "\n")
    }

    /// ".1" -> 100, ".12" -> 120, ".123" -> 123
    private static func parseCentsToMs(_ cc: String) -> Int {
        var str = cc
        while str.count < 3 {
            str += "0"
        }
        if str.count > 3 {
            str = String(str.prefix(3))
        }
        return Int(str) ?? 0
    }
}
