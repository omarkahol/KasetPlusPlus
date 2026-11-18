import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

// MARK: - SpotlightIndexService

/// Indexes offline downloaded tracks and videos in macOS CoreSpotlight and builds
/// `NSUserActivity` payloads for macOS Handoff.
@MainActor
final class SpotlightIndexService {
    static let shared = SpotlightIndexService()

    static let domainIdentifier = "com.sertacozercan.Kaset.downloads"

    private init() {}

    static func makeSearchableItem(for song: DownloadedSong, baseDirectory: URL) -> CSSearchableItem {
        let contentType: UTType = song.mediaType == .video ? .movie : .audio
        let attributes = CSSearchableItemAttributeSet(contentType: contentType)
        attributes.title = song.title
        if !song.artistsDisplay.isEmpty {
            attributes.artist = song.artistsDisplay
        }
        if let albumTitle = song.albumTitle, !albumTitle.isEmpty {
            attributes.album = albumTitle
        }
        if let duration = song.duration, duration > 0 {
            attributes.duration = NSNumber(value: duration)
        }
        if let artworkPath = song.artworkPath {
            attributes.thumbnailURL = baseDirectory.appendingPathComponent(artworkPath)
        }
        attributes.contentDescription = song.mediaType == .video
            ? String(localized: "Downloaded Video")
            : String(localized: "Downloaded Song")

        return CSSearchableItem(
            uniqueIdentifier: song.videoId,
            domainIdentifier: Self.domainIdentifier,
            attributeSet: attributes
        )
    }

    static func makeHandoffActivity(
        videoId: String,
        title: String,
        isYouTubeVideo: Bool
    ) -> NSUserActivity? {
        let trimmedID = videoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = isYouTubeVideo ? "www.youtube.com" : "music.youtube.com"
        components.path = "/watch"
        components.queryItems = [URLQueryItem(name: "v", value: trimmedID)]
        guard let url = components.url else { return nil }

        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.title = title.isEmpty ? trimmedID : title
        activity.webpageURL = url
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        return activity
    }

    func index(_ song: DownloadedSong, baseDirectory: URL) {
        let item = Self.makeSearchableItem(for: song, baseDirectory: baseDirectory)
        CSSearchableIndex.default().indexSearchableItems([item]) { _ in }
    }

    func remove(videoId: String) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [videoId]) { _ in }
    }

    func reindexAll(_ songs: [DownloadedSong], baseDirectory: URL) {
        let items = songs.map { Self.makeSearchableItem(for: $0, baseDirectory: baseDirectory) }
        guard !items.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems(items) { _ in }
    }
}
