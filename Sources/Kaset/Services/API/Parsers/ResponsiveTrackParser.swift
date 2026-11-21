import Foundation

/// Shared parser for `musicResponsiveListItemRenderer` song rows.
enum ResponsiveTrackParser {
    /// Parses a `Song` directly from a `musicResponsiveListItemRenderer` dictionary.
    static func parseSong(
        from renderer: [String: Any],
        fallbackThumbnailURL: URL? = nil,
        includeMenuAndCredits: Bool = false
    ) -> Song? {
        guard let videoId = ParsingHelpers.extractVideoId(from: renderer) else {
            return nil
        }

        let title = ParsingHelpers.extractTitleFromFlexColumns(renderer) ?? "Unknown"
        let artists = ParsingHelpers.extractArtistsFromFlexColumns(renderer)
        let thumbnailURL = ParsingHelpers.extractThumbnailURL(from: renderer) ?? fallbackThumbnailURL
        let duration = ParsingHelpers.extractDurationFromFlexColumns(renderer)
        let album = ParsingHelpers.extractAlbumFromFlexColumns(renderer)
        let isPlayable = ParsingHelpers.isPlayableMusicItem(from: renderer)
        let isExplicit = ParsingHelpers.extractIsExplicit(from: renderer)
        let musicVideoType = ParsingHelpers.extractMusicVideoType(from: renderer)

        if includeMenuAndCredits {
            let playlistSetVideoId = ParsingHelpers.extractPlaylistSetVideoId(from: renderer)
            // Music-video rows advertise their audio recording through the credits menu.
            // Ignore the credits ID when it just repeats the row (ordinary audio tracks).
            let creditsVideoId = ParsingHelpers.extractTrackCreditsVideoId(from: renderer)
            let audioTrackVideoId = creditsVideoId == videoId ? nil : creditsVideoId
            let menuData = SongMetadataParser.parseMenuData(from: renderer)

            return Song(
                id: videoId,
                title: title,
                artists: artists,
                album: album,
                duration: duration,
                thumbnailURL: thumbnailURL,
                videoId: videoId,
                isPlayable: isPlayable,
                musicVideoType: musicVideoType,
                likeStatus: menuData.likeStatus,
                isInLibrary: menuData.isInLibrary,
                feedbackTokens: menuData.feedbackTokens,
                isExplicit: isExplicit,
                playlistSetVideoId: playlistSetVideoId,
                audioTrackVideoId: audioTrackVideoId
            )
        }

        return Song(
            id: videoId,
            title: title,
            artists: artists,
            album: album,
            duration: duration,
            thumbnailURL: thumbnailURL,
            videoId: videoId,
            isPlayable: isPlayable,
            musicVideoType: musicVideoType,
            isExplicit: isExplicit
        )
    }
}
