import Foundation

// MARK: - DownloadedSong

/// Represents a locally saved offline track with its metadata index.
struct DownloadedSong: Identifiable, Codable, Hashable, Sendable {
    let id: String // videoId
    let videoId: String
    let title: String
    let artists: [Artist]
    let albumTitle: String?
    let duration: TimeInterval?
    let artworkPath: String? // relative to downloads folder
    let localRelativePath: String // relative to downloads folder
    let fileSize: Int64?
    let downloadDate: Date
    let audioFormat: String
    var likeStatus: LikeStatus?

    init(
        id: String,
        videoId: String,
        title: String,
        artists: [Artist],
        albumTitle: String?,
        duration: TimeInterval?,
        artworkPath: String?,
        localRelativePath: String,
        fileSize: Int64?,
        downloadDate: Date,
        audioFormat: String,
        likeStatus: LikeStatus? = nil
    ) {
        self.id = id
        self.videoId = videoId
        self.title = title
        self.artists = artists
        self.albumTitle = albumTitle
        self.duration = duration
        self.artworkPath = artworkPath
        self.localRelativePath = localRelativePath
        self.fileSize = fileSize
        self.downloadDate = downloadDate
        self.audioFormat = audioFormat
        self.likeStatus = likeStatus
    }

    var artistsDisplay: String {
        self.artists.map(\.name).joined(separator: ", ")
    }

    /// Converts this downloaded song record to the app's `Song` model.
    func toSong(baseDirectory: URL) -> Song {
        let artworkURL = self.artworkPath.map { baseDirectory.appendingPathComponent($0) }

        return Song(
            id: self.videoId,
            title: self.title,
            artists: self.artists,
            album: self.albumTitle.map {
                Album(
                    id: "",
                    title: $0,
                    artists: self.artists,
                    thumbnailURL: artworkURL,
                    year: nil,
                    trackCount: nil
                )
            },
            duration: self.duration,
            thumbnailURL: artworkURL,
            videoId: self.videoId,
            isPlayable: true,
            likeStatus: self.likeStatus
        )
    }

    /// Returns the absolute local audio file URL given the base downloads directory.
    func fileURL(baseDirectory: URL) -> URL {
        baseDirectory.appendingPathComponent(self.localRelativePath)
    }
}
