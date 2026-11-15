import Foundation

// MARK: - MediaType

/// Media type of a downloaded item (audio or video).
enum MediaType: String, Codable, Sendable, Equatable, CaseIterable {
    case audio
    case video
}

// MARK: - DownloadedSong

/// Represents a locally saved offline track or video with its metadata index.
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
    var mediaType: MediaType

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
        likeStatus: LikeStatus? = nil,
        mediaType: MediaType = .audio
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
        self.mediaType = mediaType
    }

    enum CodingKeys: String, CodingKey {
        case id
        case videoId
        case title
        case artists
        case albumTitle
        case duration
        case artworkPath
        case localRelativePath
        case fileSize
        case downloadDate
        case audioFormat
        case likeStatus
        case mediaType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.videoId = try container.decode(String.self, forKey: .videoId)
        self.title = try container.decode(String.self, forKey: .title)
        self.artists = try container.decode([Artist].self, forKey: .artists)
        self.albumTitle = try container.decodeIfPresent(String.self, forKey: .albumTitle)
        self.duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        self.artworkPath = try container.decodeIfPresent(String.self, forKey: .artworkPath)
        self.localRelativePath = try container.decode(String.self, forKey: .localRelativePath)
        self.fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
        self.downloadDate = try container.decode(Date.self, forKey: .downloadDate)
        self.audioFormat = try container.decode(String.self, forKey: .audioFormat)
        self.likeStatus = try container.decodeIfPresent(LikeStatus.self, forKey: .likeStatus)
        self.mediaType = try container.decodeIfPresent(MediaType.self, forKey: .mediaType) ?? .audio
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.videoId, forKey: .videoId)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.artists, forKey: .artists)
        try container.encodeIfPresent(self.albumTitle, forKey: .albumTitle)
        try container.encodeIfPresent(self.duration, forKey: .duration)
        try container.encodeIfPresent(self.artworkPath, forKey: .artworkPath)
        try container.encode(self.localRelativePath, forKey: .localRelativePath)
        try container.encodeIfPresent(self.fileSize, forKey: .fileSize)
        try container.encode(self.downloadDate, forKey: .downloadDate)
        try container.encode(self.audioFormat, forKey: .audioFormat)
        try container.encodeIfPresent(self.likeStatus, forKey: .likeStatus)
        try container.encode(self.mediaType, forKey: .mediaType)
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

    /// Returns the absolute local media file URL given the base downloads directory.
    func fileURL(baseDirectory: URL) -> URL {
        baseDirectory.appendingPathComponent(self.localRelativePath)
    }
}
