import Foundation

// MARK: - RadioQueueResult

/// Result from parsing a radio queue, including songs and continuation token.
struct RadioQueueResult {
    let songs: [Song]
    /// Continuation token for fetching more songs (infinite mix).
    let continuationToken: String?
}

// MARK: - RadioQueueParser

/// Parses radio queue responses from YouTube Music API.
enum RadioQueueParser {
    private static let logger = DiagnosticsLogger.api

    /// Parses the radio queue from the "next" endpoint response.
    /// - Parameter data: The response from the "next" endpoint with a radio playlist ID
    /// - Returns: RadioQueueResult containing songs and optional continuation token
    static func parse(from data: [String: Any]) -> RadioQueueResult {
        guard let contents = data["contents"] as? [String: Any],
              let watchNextRenderer = contents["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any],
              let tabbedRenderer = watchNextRenderer["tabbedRenderer"] as? [String: Any],
              let watchNextTabbedResults = tabbedRenderer["watchNextTabbedResultsRenderer"] as? [String: Any],
              let tabs = watchNextTabbedResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let musicQueueRenderer = tabContent["musicQueueRenderer"] as? [String: Any],
              let queueContent = musicQueueRenderer["content"] as? [String: Any],
              let playlistPanelRenderer = queueContent["playlistPanelRenderer"] as? [String: Any],
              let playlistContents = playlistPanelRenderer["contents"] as? [[String: Any]]
        else {
            self.logger.debug("RadioQueueParser: Failed to parse radio queue structure. Top keys: \(data.keys.sorted())")
            return RadioQueueResult(songs: [], continuationToken: nil)
        }

        // Extract continuation token for infinite mix
        var continuationToken: String?
        if let continuations = playlistPanelRenderer["continuations"] as? [[String: Any]],
           let firstContinuation = continuations.first,
           let nextRadioData = firstContinuation["nextRadioContinuationData"] as? [String: Any],
           let token = nextRadioData["continuation"] as? String
        {
            continuationToken = token
        }

        let songs = Self.parseSongs(from: playlistContents)
        return RadioQueueResult(songs: songs, continuationToken: continuationToken)
    }

    /// Parses a continuation response for more queue items.
    /// - Parameter data: The continuation response
    /// - Returns: RadioQueueResult with additional songs and next continuation token
    static func parseContinuation(from data: [String: Any]) -> RadioQueueResult {
        guard let continuationContents = data["continuationContents"] as? [String: Any],
              let playlistPanelContinuation = continuationContents["playlistPanelContinuation"] as? [String: Any],
              let contents = playlistPanelContinuation["contents"] as? [[String: Any]]
        else {
            return RadioQueueResult(songs: [], continuationToken: nil)
        }

        // Extract next continuation token
        var continuationToken: String?
        if let continuations = playlistPanelContinuation["continuations"] as? [[String: Any]],
           let firstContinuation = continuations.first,
           let nextRadioData = firstContinuation["nextRadioContinuationData"] as? [String: Any],
           let token = nextRadioData["continuation"] as? String
        {
            continuationToken = token
        }

        let songs = Self.parseSongs(from: contents)
        return RadioQueueResult(songs: songs, continuationToken: continuationToken)
    }

    /// Parses songs from playlist panel contents.
    private static func parseSongs(from playlistContents: [[String: Any]]) -> [Song] {
        playlistContents.compactMap { PanelVideoRendererParser.parseSong(from: $0) }
    }
}
