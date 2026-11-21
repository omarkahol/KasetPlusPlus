import Foundation

/// Shared parser for `playlistPanelVideoRenderer` (and its `playlistPanelVideoWrapperRenderer` wrapper).
enum PanelVideoRendererParser {
    /// Unwraps either a direct `playlistPanelVideoRenderer` or a wrapped
    /// `playlistPanelVideoWrapperRenderer.primaryRenderer.playlistPanelVideoRenderer`.
    static func unwrap(_ item: [String: Any]) -> [String: Any]? {
        if let direct = item["playlistPanelVideoRenderer"] as? [String: Any] {
            return direct
        }
        if let wrapper = item["playlistPanelVideoWrapperRenderer"] as? [String: Any],
           let primary = wrapper["primaryRenderer"] as? [String: Any],
           let wrapped = primary["playlistPanelVideoRenderer"] as? [String: Any]
        {
            return wrapped
        }
        return nil
    }

    static func parseTitle(from renderer: [String: Any]) -> String {
        if let titleData = renderer["title"] as? [String: Any],
           let runs = titleData["runs"] as? [[String: Any]],
           let firstRun = runs.first,
           let text = firstRun["text"] as? String
        {
            return text
        }
        return "Unknown"
    }

    static func parseArtists(from renderer: [String: Any]) -> [Artist] {
        var artists: [Artist] = []
        guard let bylineData = renderer["longBylineText"] as? [String: Any],
              let runs = bylineData["runs"] as? [[String: Any]]
        else { return artists }

        for run in runs {
            guard let text = run["text"] as? String else { continue }
            if text == " • " || text == " · " {
                break
            }
            guard text != " & ", text != ", " else { continue }

            let artistId: String = if let navEndpoint = run["navigationEndpoint"] as? [String: Any],
                                      let browseEndpoint = navEndpoint["browseEndpoint"] as? [String: Any],
                                      let browseId = browseEndpoint["browseId"] as? String
            {
                browseId
            } else {
                ParsingHelpers.stableId(title: "artist", components: text)
            }
            artists.append(Artist(id: artistId, name: text))
        }
        return artists
    }

    static func parseThumbnail(from renderer: [String: Any]) -> URL? {
        guard let thumbnail = renderer["thumbnail"] as? [String: Any],
              let thumbnails = thumbnail["thumbnails"] as? [[String: Any]],
              let lastThumb = thumbnails.last,
              let urlString = lastThumb["url"] as? String
        else { return nil }

        let normalizedURL = urlString.hasPrefix("//") ? "https:" + urlString : urlString
        return URL(string: normalizedURL)
    }

    static func parseDuration(from renderer: [String: Any]) -> TimeInterval? {
        guard let lengthText = renderer["lengthText"] as? [String: Any],
              let runs = lengthText["runs"] as? [[String: Any]],
              let firstRun = runs.first,
              let text = firstRun["text"] as? String
        else { return nil }

        return ParsingHelpers.parseDuration(text)
    }

    /// Parses a `Song` from a queue/panel item dictionary (direct or wrapped).
    static func parseSong(from item: [String: Any]) -> Song? {
        guard let renderer = self.unwrap(item),
              let videoId = renderer["videoId"] as? String
        else {
            return nil
        }

        return Song(
            id: videoId,
            title: self.parseTitle(from: renderer),
            artists: self.parseArtists(from: renderer),
            album: nil,
            duration: self.parseDuration(from: renderer),
            thumbnailURL: self.parseThumbnail(from: renderer),
            videoId: videoId,
            isExplicit: ParsingHelpers.extractIsExplicit(from: renderer)
        )
    }
}
