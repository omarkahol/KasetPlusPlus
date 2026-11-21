// swiftlint:disable file_length
import Foundation
import Observation

// MARK: - DownloadManager

/// Manages downloading YouTube Music tracks for offline playback using yt-dlp.
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    // MARK: - DownloadStatus

    enum DownloadStatus: Equatable, Sendable {
        case queued
        case preparing
        case downloading(progress: Double, speed: String)
        case completed(fileURL: URL)
        case failed(error: String)

        var isDownloading: Bool {
            switch self {
            case .queued, .preparing, .downloading:
                true
            case .completed, .failed:
                false
            }
        }

        var progress: Double {
            switch self {
            case let .downloading(progress, _):
                progress
            case .completed:
                1.0
            default:
                0.0
            }
        }
    }

    // MARK: - Observable State

    /// All downloaded songs currently indexed on disk.
    var downloadedSongs: [DownloadedSong] = []

    /// Current statuses of active and queued downloads keyed by video ID.
    var activeDownloads: [String: DownloadStatus] = [:]

    // MARK: - DownloadItem

    /// Represents an item in the download queue.
    struct DownloadItem: Equatable, Sendable {
        let videoId: String
        let title: String
        let artistsDisplay: String
        let albumTitle: String?
        let duration: TimeInterval?
        let thumbnailURL: URL?
        let mediaType: MediaType
        let song: Song?

        init(song: Song, mediaType: MediaType = .audio) {
            self.videoId = song.videoId
            self.title = song.title
            self.artistsDisplay = song.artistsDisplay
            self.albumTitle = song.album?.title
            self.duration = song.duration
            self.thumbnailURL = song.thumbnailURL
            self.mediaType = mediaType
            self.song = song
        }

        init(
            videoId: String,
            title: String,
            artistsDisplay: String,
            albumTitle: String? = nil,
            duration: TimeInterval? = nil,
            thumbnailURL: URL? = nil,
            mediaType: MediaType
        ) {
            self.videoId = videoId
            self.title = title
            self.artistsDisplay = artistsDisplay
            self.albumTitle = albumTitle
            self.duration = duration
            self.thumbnailURL = thumbnailURL
            self.mediaType = mediaType
            self.song = nil
        }
    }

    // MARK: - Private State

    private final class ProcessProgressState: @unchecked Sendable {
        private static let minimumUpdateInterval: Duration = .milliseconds(100)

        private let lock = NSLock()
        private var lastDestination = ""
        private var lastProgressUpdate: ContinuousClock.Instant?

        func setDestination(_ destination: String) {
            self.lock.withLock {
                self.lastDestination = destination
            }
        }

        func destination() -> String {
            self.lock.withLock {
                self.lastDestination
            }
        }

        func shouldEmitProgress(_ percent: Double) -> Bool {
            let now = ContinuousClock.now
            return self.lock.withLock {
                if percent >= 1.0 {
                    self.lastProgressUpdate = now
                    return true
                }
                if let last = self.lastProgressUpdate,
                   now - last < Self.minimumUpdateInterval
                {
                    return false
                }
                self.lastProgressUpdate = now
                return true
            }
        }
    }

    @ObservationIgnored private var downloadQueue: [DownloadItem] = []
    @ObservationIgnored private var activeProcesses: [String: Process] = [:]
    @ObservationIgnored private var canceledVideoIds: Set<String> = []
    @ObservationIgnored private let logger = DiagnosticsLogger.download

    private init() {
        self.loadIndex()
        self.cleanupLegacyVideosDirectory()
        _ = Self.cleanupOrphanedPartialFiles(in: [self.musicDirectory, self.videosDirectory])
        SpotlightIndexService.shared.reindexAll(self.downloadedSongs, baseDirectory: self.downloadsDirectory)
    }

    /// Removes orphaned `.part`, `.ytdl`, and `.temp` partial-download files left behind by interrupted runs.
    @discardableResult
    static func cleanupOrphanedPartialFiles(
        in directories: [URL],
        fileManager: FileManager = .default
    ) -> Int {
        let partialExtensions: Set = ["part", "ytdl", "temp"]
        var removedCount = 0
        for directory in directories {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for fileURL in contents {
                let ext = fileURL.pathExtension.lowercased()
                let name = fileURL.lastPathComponent.lowercased()
                if partialExtensions.contains(ext) || name.contains(".part-frag") {
                    if (try? fileManager.removeItem(at: fileURL)) != nil {
                        removedCount += 1
                    }
                }
            }
        }
        return removedCount
    }

    // MARK: - Directories

    /// Base download directory configured in settings.
    var downloadsDirectory: URL {
        let dir = SettingsManager.shared.resolvedDownloadDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Subdirectory for downloaded audio tracks.
    var musicDirectory: URL {
        let dir = self.downloadsDirectory.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Directory for downloaded video files (~/Movies/KasetPlus Downloads).
    var videosDirectory: URL {
        let dir = SettingsManager.defaultVideoDownloadDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns the base directory for a given media type (`videosDirectory` for `.video`, `downloadsDirectory` for `.audio`).
    func baseDirectory(for mediaType: MediaType) -> URL {
        switch mediaType {
        case .audio: self.downloadsDirectory
        case .video: self.videosDirectory
        }
    }

    /// Returns the resolved local media file URL for a downloaded item.
    func mediaFileURL(for song: DownloadedSong) -> URL {
        song.fileURL(baseDirectory: self.baseDirectory(for: song.mediaType))
    }

    /// Subdirectory for cached track artwork.
    var artworksDirectory: URL {
        let dir = self.downloadsDirectory.appendingPathComponent("Artworks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Subdirectory for cached track lyrics (.lrc sidecar files).
    var lyricsDirectory: URL {
        let dir = self.downloadsDirectory.appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// URL for a track's .lrc sidecar file.
    func lyricsFileURL(for videoId: String) -> URL {
        self.lyricsDirectory.appendingPathComponent("\(videoId).lrc")
    }

    /// Reads cached lyrics for a videoId if an .lrc sidecar file exists on disk.
    func cachedLyrics(for videoId: String) -> LyricResult? {
        let file = self.lyricsFileURL(for: videoId)
        guard FileManager.default.fileExists(atPath: file.path),
              let content = try? String(contentsOf: file, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        if let synced = LRCParser.parse(content), !synced.lines.isEmpty {
            let withSource = SyncedLyrics(lines: synced.lines, source: "Offline Cache")
            return .synced(withSource)
        } else {
            return .plain(Lyrics(text: content, source: "Offline Cache"))
        }
    }

    /// Saves lyrics to a local .lrc sidecar file.
    func saveLyrics(_ lyrics: LyricResult, for videoId: String) {
        let file = self.lyricsFileURL(for: videoId)
        let text: String
        switch lyrics {
        case let .synced(synced):
            text = LRCParser.encode(synced)
        case let .plain(plain):
            text = plain.text
        case .unavailable:
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// JSON metadata index file path.
    private var indexFileURL: URL {
        self.downloadsDirectory.appendingPathComponent("downloads_index.json")
    }

    // MARK: - Binary Path Resolution

    /// Resolved executable path for `yt-dlp`.
    var ytdlpPath: String? {
        let custom = SettingsManager.shared.customYtdlpPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }

        return YTDLPBinaryLocator.shared.ytdlpPath()
    }

    /// Resolved executable path for `ffmpeg`.
    var ffmpegPath: String? {
        YTDLPBinaryLocator.shared.ffmpegPath(customPath: SettingsManager.shared.customFfmpegPath)
    }

    var isYtdlpAvailable: Bool {
        self.ytdlpPath != nil
    }

    var isFfmpegAvailable: Bool {
        self.ffmpegPath != nil
    }

    // MARK: - Query Status

    /// Returns true if the song is downloaded and exists on disk.
    func isDownloaded(videoId: String) -> Bool {
        guard let song = self.downloadedSongs.first(where: { $0.videoId == videoId }) else {
            return false
        }
        let url = self.mediaFileURL(for: song)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Returns the download status of a video ID.
    func status(for videoId: String) -> DownloadStatus? {
        if let status = self.activeDownloads[videoId] {
            return status
        }
        if self.isDownloaded(videoId: videoId), let song = self.downloadedSongs.first(where: { $0.videoId == videoId }) {
            return .completed(fileURL: self.mediaFileURL(for: song))
        }
        return nil
    }

    /// Returns the local audio file URL for a downloaded song if it exists on disk.
    func fileURL(for videoId: String) -> URL? {
        guard let song = self.downloadedSongs.first(where: { $0.videoId == videoId }) else {
            return nil
        }
        let url = self.mediaFileURL(for: song)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Queue Actions

    /// Enqueues a song for download (default audio).
    func download(song: Song, mediaType: MediaType = .audio) {
        let item = DownloadItem(song: song, mediaType: mediaType)
        self.enqueue(item: item)
    }

    /// Enqueues a video for download.
    func downloadVideo(
        id: String,
        title: String,
        artistsDisplay: String = "",
        thumbnailURL: URL? = nil,
        duration: TimeInterval? = nil
    ) {
        let item = DownloadItem(
            videoId: id,
            title: title,
            artistsDisplay: artistsDisplay,
            albumTitle: nil,
            duration: duration,
            thumbnailURL: thumbnailURL,
            mediaType: .video
        )
        self.enqueue(item: item)
    }

    /// Enqueues a YouTube video model for download.
    func download(video: YouTubeVideo) {
        var duration: TimeInterval?
        if let lengthText = video.lengthText {
            let parts = lengthText.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2 {
                duration = parts[0] * 60 + parts[1]
            } else if parts.count == 3 {
                duration = parts[0] * 3600 + parts[1] * 60 + parts[2]
            }
        }

        self.downloadVideo(
            id: video.videoId,
            title: video.title,
            artistsDisplay: video.channelName ?? "",
            thumbnailURL: video.thumbnailURL,
            duration: duration
        )
    }

    private func enqueue(item: DownloadItem) {
        guard !self.isDownloaded(videoId: item.videoId) else { return }
        if let currentStatus = self.activeDownloads[item.videoId], currentStatus.isDownloading {
            return
        }

        self.canceledVideoIds.remove(item.videoId)
        self.logger.info("Enqueuing download for \(item.title) (\(item.videoId)) [\(item.mediaType.rawValue)]")
        self.activeDownloads[item.videoId] = .queued

        if !self.downloadQueue.contains(where: { $0.videoId == item.videoId }) {
            self.downloadQueue.append(item)
        }

        self.processQueue()
    }

    /// Enqueues multiple songs for download.
    func downloadAll(songs: [Song], mediaType: MediaType = .audio) {
        for song in songs {
            let item = DownloadItem(song: song, mediaType: mediaType)
            if self.isDownloaded(videoId: item.videoId) {
                continue
            }
            if let currentStatus = self.activeDownloads[item.videoId], currentStatus.isDownloading {
                continue
            }
            self.canceledVideoIds.remove(item.videoId)
            self.activeDownloads[item.videoId] = .queued
            if !self.downloadQueue.contains(where: { $0.videoId == item.videoId }) {
                self.downloadQueue.append(item)
            }
        }
        self.processQueue()
    }

    /// Cancels a queued or active download.
    func cancel(videoId: String) {
        self.logger.info("Canceling download for \(videoId)")
        self.canceledVideoIds.insert(videoId)
        self.downloadQueue.removeAll { $0.videoId == videoId }

        if let proc = self.activeProcesses.removeValue(forKey: videoId) {
            proc.terminate()
        }

        self.activeDownloads.removeValue(forKey: videoId)
        self.cleanupPartialFiles(for: videoId)
        self.processQueue()
    }

    /// Deletes a downloaded song from disk and removes it from the metadata index.
    func removeDownload(videoId: String) {
        self.logger.info("Removing download for \(videoId)")
        self.cancel(videoId: videoId)

        if let index = self.downloadedSongs.firstIndex(where: { $0.videoId == videoId }) {
            let song = self.downloadedSongs[index]
            let fileURL = self.mediaFileURL(for: song)
            try? FileManager.default.removeItem(at: fileURL)

            if let artwork = song.artworkPath {
                let artworkURL = self.downloadsDirectory.appendingPathComponent(artwork)
                try? FileManager.default.removeItem(at: artworkURL)
            }

            try? FileManager.default.removeItem(at: self.lyricsFileURL(for: videoId))

            self.downloadedSongs.remove(at: index)
            self.saveIndex()
            SpotlightIndexService.shared.remove(videoId: videoId)
        }

        self.activeDownloads.removeValue(forKey: videoId)
    }

    /// Deletes all downloaded songs, artworks, and resets the index.
    func removeAllDownloads() {
        self.logger.info("Removing all downloads")
        for videoId in self.activeProcesses.keys {
            self.cancel(videoId: videoId)
        }
        self.downloadQueue.removeAll()
        self.activeDownloads.removeAll()

        for song in self.downloadedSongs {
            let fileURL = self.mediaFileURL(for: song)
            try? FileManager.default.removeItem(at: fileURL)
        }
        try? FileManager.default.removeItem(at: self.musicDirectory)
        let legacyVideosDir = self.downloadsDirectory.appendingPathComponent("Videos", isDirectory: true)
        try? FileManager.default.removeItem(at: legacyVideosDir)
        try? FileManager.default.removeItem(at: self.artworksDirectory)
        try? FileManager.default.removeItem(at: self.lyricsDirectory)
        try? FileManager.default.removeItem(at: self.indexFileURL)

        self.downloadedSongs.removeAll()
    }

    // MARK: - Queue Processing

    private func processQueue() {
        let maxConcurrent = SettingsManager.shared.maxConcurrentDownloads
        while self.activeProcesses.count < maxConcurrent, !self.downloadQueue.isEmpty {
            let item = self.downloadQueue.removeFirst()
            self.startDownload(item: item)
        }
    }

    private func startDownload(item: DownloadItem) {
        guard let ytdlp = self.ytdlpPath else {
            self.activeDownloads[item.videoId] = .failed(error: String(localized: "yt-dlp is not installed."))
            self.processQueue()
            return
        }

        self.activeDownloads[item.videoId] = .preparing
        let videoId = item.videoId
        let targetDirectory = (item.mediaType == .video) ? self.videosDirectory : self.musicDirectory

        // Build Process
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ytdlp)

        let audioFormat = SettingsManager.shared.downloadAudioFormat
        let videoQuality = SettingsManager.shared.videoDownloadQuality
        proc.arguments = self.buildDownloadArguments(
            item: item,
            targetDirectory: targetDirectory,
            audioFormat: audioFormat,
            videoQuality: videoQuality
        )
        proc.environment = Self.configuredDownloadEnvironment()

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        self.activeProcesses[videoId] = proc

        let progressState = ProcessProgressState()
        let itemTitle = item.title

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(data: handle.availableData, encoding: .utf8) ?? ""
            guard !chunk.isEmpty else { return }
            Self.handleDownloadOutputChunk(chunk, videoId: videoId, progressState: progressState)
        }

        proc.terminationHandler = { [weak self] process in
            pipe.fileHandleForReading.readabilityHandler = nil
            let finalDestination = progressState.destination()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeProcesses.removeValue(forKey: videoId)
                let wasCanceled = self.canceledVideoIds.remove(videoId) != nil

                if wasCanceled {
                    self.logger.info("Download was canceled for \(itemTitle) (\(videoId))")
                    self.activeDownloads.removeValue(forKey: videoId)
                    self.cleanupPartialFiles(for: videoId)
                } else if process.terminationStatus == 0 {
                    self.logger.info("Download completed successfully for \(itemTitle) (\(videoId))")
                    let fileExt = (item.mediaType == .video) ? videoQuality.fileExtension : audioFormat.fileExtension
                    self.finalizeDownload(item: item, fileExtension: fileExt, detectedDestination: finalDestination)
                } else {
                    self.logger.error("Download failed for \(itemTitle) (\(videoId)) with exit code \(process.terminationStatus)")
                    self.activeDownloads[videoId] = .failed(error: String(localized: "Download failed."))
                }

                self.processQueue()
            }
        }

        do {
            try proc.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            self.activeProcesses.removeValue(forKey: videoId)
            self.activeDownloads[videoId] = .failed(error: error.localizedDescription)
            self.processQueue()
        }
    }

    private func finalizeDownload(item: DownloadItem, fileExtension: String, detectedDestination: String) {
        let baseDir = self.baseDirectory(for: item.mediaType)
        let fallbackFileName = "\(item.title) [\(item.videoId)].\(fileExtension)"
        let actualFileName: String = if !detectedDestination.isEmpty {
            (detectedDestination as NSString).lastPathComponent
        } else {
            fallbackFileName
        }

        let localRelativePath = (item.mediaType == .video) ? actualFileName : "Music/\(actualFileName)"
        let mediaFileURL = baseDir.appendingPathComponent(localRelativePath)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: mediaFileURL.path)[.size] as? Int64)

        // Cache Artwork thumbnail asynchronously
        let currentLikeStatus = item.song.flatMap { SongLikeStatusManager.shared.status(for: $0) ?? $0.likeStatus }
        Task {
            let relativeArtworkPath = await self.cacheArtwork(videoId: item.videoId, thumbnailURL: item.thumbnailURL)

            let artists: [Artist] = if let song = item.song {
                song.artists
            } else if !item.artistsDisplay.isEmpty {
                [Artist(id: "", name: item.artistsDisplay)]
            } else {
                []
            }

            let downloaded = DownloadedSong(
                id: item.videoId,
                videoId: item.videoId,
                title: item.title,
                artists: artists,
                albumTitle: item.albumTitle,
                duration: item.duration,
                artworkPath: relativeArtworkPath,
                localRelativePath: localRelativePath,
                fileSize: fileSize,
                downloadDate: Date(),
                audioFormat: fileExtension,
                likeStatus: currentLikeStatus,
                mediaType: item.mediaType
            )

            self.downloadedSongs.removeAll { $0.videoId == item.videoId }
            self.downloadedSongs.insert(downloaded, at: 0)
            self.saveIndex()

            self.activeDownloads[item.videoId] = .completed(fileURL: mediaFileURL)

            if item.mediaType == .audio {
                await self.prefetchLyricsSidecar(
                    videoId: item.videoId,
                    title: item.title,
                    artist: item.artistsDisplay,
                    album: item.albumTitle,
                    duration: item.duration
                )
            }
        }
    }

    /// Fetches lyrics for a freshly downloaded track and stores them as a `.lrc` sidecar
    /// so they are available offline. Synced (LRCLIB) is preferred over plain (Lyrics.ovh).
    private func prefetchLyricsSidecar(
        videoId: String,
        title: String,
        artist: String,
        album: String?,
        duration: TimeInterval?
    ) async {
        guard self.cachedLyrics(for: videoId) == nil else { return }
        let info = LyricsSearchInfo(title: title, artist: artist, album: album, duration: duration, videoId: videoId)
        let providers: [LyricsProvider] = [LRCLibProvider(), LyricsOvhProvider()]
        for provider in providers {
            let result = await provider.search(info: info)
            if case .unavailable = result {
                continue
            }
            self.saveLyrics(result, for: videoId)
            self.logger.info("Cached lyrics sidecar for \(videoId) from \(provider.name)")
            return
        }
    }

    /// Updates the stored like status of a downloaded song and persists the index.
    func updateLikeStatus(videoId: String, likeStatus: LikeStatus?) {
        guard let index = self.downloadedSongs.firstIndex(where: { $0.videoId == videoId }) else { return }
        var updated = self.downloadedSongs[index]
        updated.likeStatus = likeStatus
        self.downloadedSongs[index] = updated
        self.saveIndex()
    }

    private func cacheArtwork(for song: Song) async -> String? {
        await self.cacheArtwork(videoId: song.videoId, thumbnailURL: song.thumbnailURL)
    }

    private func cacheArtwork(videoId: String, thumbnailURL: URL?) async -> String? {
        guard let thumbnailURL else { return nil }
        let artworkFileName = "\(videoId).jpg"
        let fileURL = self.artworksDirectory.appendingPathComponent(artworkFileName)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            return "Artworks/\(artworkFileName)"
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: thumbnailURL)
            try data.write(to: fileURL)
            return "Artworks/\(artworkFileName)"
        } catch {
            return nil
        }
    }
}

// MARK: - Index Persistence & Output Parsers

extension DownloadManager {
    private func buildDownloadArguments(
        item: DownloadItem,
        targetDirectory: URL,
        audioFormat: SettingsManager.DownloadAudioFormat,
        videoQuality: SettingsManager.VideoDownloadQuality
    ) -> [String] {
        var args: [String] = [
            "--newline", // Line-by-line progress updates
            "--no-playlist",
            "--no-mtime",
            "--add-metadata",
            "-o", "\(targetDirectory.path)/%(title)s [%(id)s].%(ext)s",
        ]
        if item.mediaType == .audio {
            args.append("--embed-thumbnail")
        }
        if let ffmpeg = self.ffmpegPath {
            args.append(contentsOf: ["--ffmpeg-location", ffmpeg])
        }
        if item.mediaType == .video {
            args.append(contentsOf: videoQuality.ytDlpArguments)
        } else {
            args.append(contentsOf: audioFormat.ytDlpArguments)
        }
        args.append("https://www.youtube.com/watch?v=\(item.videoId)")
        return args
    }

    // swiftformat:disable:next modifierOrder
    nonisolated private static func configuredDownloadEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.deno/bin"
        if let currentPath = env["PATH"] {
            env["PATH"] = "\(extraPaths):\(currentPath)"
        } else {
            env["PATH"] = extraPaths
        }
        return env
    }

    // swiftformat:disable:next modifierOrder
    nonisolated private static func handleDownloadOutputChunk(
        _ chunk: String,
        videoId: String,
        progressState: ProcessProgressState
    ) {
        var latestProgress: (percent: Double, speed: String)?
        for line in chunk.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("[download] Destination:") {
                progressState.setDestination(
                    trimmed
                        .replacingOccurrences(of: "[download] Destination: ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                )
            } else if trimmed.contains("[ExtractAudio] Destination:") {
                progressState.setDestination(
                    trimmed
                        .replacingOccurrences(of: "[ExtractAudio] Destination: ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                )
            } else if trimmed.contains("[Merger] Merging formats into") {
                progressState.setDestination(
                    trimmed
                        .replacingOccurrences(of: "[Merger] Merging formats into ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "\"", with: "")
                )
            } else if trimmed.contains("%") {
                latestProgress = (Self.parsePercent(trimmed), Self.parseSpeed(trimmed))
            }
        }

        if let latestProgress, progressState.shouldEmitProgress(latestProgress.percent) {
            let percent = latestProgress.percent
            let speed = latestProgress.speed
            Task { @MainActor in
                if DownloadManager.shared.activeDownloads[videoId] != nil {
                    DownloadManager.shared.activeDownloads[videoId] = .downloading(progress: percent, speed: speed)
                }
            }
        }
    }

    // MARK: - Index Persistence

    private func loadIndex() {
        guard FileManager.default.fileExists(atPath: self.indexFileURL.path),
              let data = try? Data(contentsOf: self.indexFileURL),
              let decoded = try? JSONDecoder().decode([DownloadedSong].self, from: data)
        else {
            self.downloadedSongs = []
            return
        }

        // Migrate any legacy video records stored in downloadsDirectory and validate existence
        let legacyBaseDir = self.downloadsDirectory
        let videosDir = self.videosDirectory
        var didMigrate = false
        self.downloadedSongs = decoded.compactMap { song in
            var resolvedSong = song
            if song.mediaType == .video {
                let normalizedPath = song.localRelativePath.hasPrefix("Videos/")
                    ? String(song.localRelativePath.dropFirst("Videos/".count))
                    : song.localRelativePath
                let targetURL = videosDir.appendingPathComponent(normalizedPath)
                let legacyURL = legacyBaseDir.appendingPathComponent(song.localRelativePath)
                if !FileManager.default.fileExists(atPath: targetURL.path),
                   FileManager.default.fileExists(atPath: legacyURL.path)
                {
                    try? FileManager.default.moveItem(at: legacyURL, to: targetURL)
                }
                if normalizedPath != song.localRelativePath {
                    didMigrate = true
                    resolvedSong = DownloadedSong(
                        id: song.id,
                        videoId: song.videoId,
                        title: song.title,
                        artists: song.artists,
                        albumTitle: song.albumTitle,
                        duration: song.duration,
                        artworkPath: song.artworkPath,
                        localRelativePath: normalizedPath,
                        fileSize: song.fileSize,
                        downloadDate: song.downloadDate,
                        audioFormat: song.audioFormat,
                        likeStatus: song.likeStatus,
                        mediaType: song.mediaType
                    )
                }
            }
            let url = self.mediaFileURL(for: resolvedSong)
            return FileManager.default.fileExists(atPath: url.path) ? resolvedSong : nil
        }
        if didMigrate {
            self.saveIndex()
        }
    }

    private func saveIndex() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self.downloadedSongs)
            try data.write(to: self.indexFileURL, options: .atomic)
        } catch {
            self.logger.error("Failed to save downloads index: \(error.localizedDescription)")
        }
    }

    /// Registers a download completed by an external service (such as `YouTubeDownloadService`)
    /// so it appears in the app's Downloads library.
    func registerCompletedDownload(
        videoId: String,
        title: String,
        filename: String,
        isAudioOnly: Bool
    ) {
        let baseDir = isAudioOnly ? self.downloadsDirectory : self.videosDirectory
        let localRelativePath = isAudioOnly ? "Music/\(filename)" : filename
        let mediaFileURL = baseDir.appendingPathComponent(localRelativePath)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: mediaFileURL.path)[.size] as? Int64)
        let ext = (filename as NSString).pathExtension.isEmpty ? (isAudioOnly ? "mp3" : "mp4") : (filename as NSString).pathExtension
        let downloaded = DownloadedSong(
            id: videoId,
            videoId: videoId,
            title: title,
            artists: [],
            albumTitle: nil,
            duration: nil,
            artworkPath: nil,
            localRelativePath: localRelativePath,
            fileSize: fileSize,
            downloadDate: Date(),
            audioFormat: ext,
            likeStatus: nil,
            mediaType: isAudioOnly ? .audio : .video
        )
        self.downloadedSongs.removeAll { $0.videoId == videoId }
        self.downloadedSongs.insert(downloaded, at: 0)
        self.saveIndex()
        SpotlightIndexService.shared.index(downloaded, baseDirectory: self.downloadsDirectory)
    }

    /// Migrates any files from the legacy `Videos` subfolder into `videosDirectory` and removes the folder.
    private func cleanupLegacyVideosDirectory() {
        let baseDir = self.downloadsDirectory
        let legacyVideosDir = baseDir.appendingPathComponent("Videos", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: legacyVideosDir.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }

        let targetVideosDir = self.videosDirectory
        if let contents = try? FileManager.default.contentsOfDirectory(at: legacyVideosDir, includingPropertiesForKeys: nil) {
            for fileURL in contents {
                let destURL = targetVideosDir.appendingPathComponent(fileURL.lastPathComponent)
                if !FileManager.default.fileExists(atPath: destURL.path) {
                    try? FileManager.default.moveItem(at: fileURL, to: destURL)
                }
            }
        }

        var didUpdateIndex = false
        self.downloadedSongs = self.downloadedSongs.map { song in
            guard song.localRelativePath.hasPrefix("Videos/") else { return song }
            didUpdateIndex = true
            let newPath = String(song.localRelativePath.dropFirst("Videos/".count))
            return DownloadedSong(
                id: song.id,
                videoId: song.videoId,
                title: song.title,
                artists: song.artists,
                albumTitle: song.albumTitle,
                duration: song.duration,
                artworkPath: song.artworkPath,
                localRelativePath: newPath,
                fileSize: song.fileSize,
                downloadDate: song.downloadDate,
                audioFormat: song.audioFormat,
                likeStatus: song.likeStatus,
                mediaType: song.mediaType
            )
        }
        if didUpdateIndex {
            self.saveIndex()
        }

        try? FileManager.default.removeItem(at: legacyVideosDir)
    }

    // MARK: - Output Parsers

    /// Removes any lingering `.part` or temporary download files left behind by yt-dlp.
    private func cleanupPartialFiles(for videoId: String) {
        let directories = [self.downloadsDirectory, self.musicDirectory, self.videosDirectory]
        for dir in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for file in files where file.contains("[\(videoId)]") {
                let fileURL = dir.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    // swiftformat:disable:next modifierOrder
    nonisolated private static func parsePercent(_ line: String) -> Double {
        guard let range = line.range(of: #"\d+\.?\d*%"#, options: .regularExpression) else {
            return 0
        }
        let str = String(line[range]).replacingOccurrences(of: "%", with: "")
        return (Double(str) ?? 0) / 100.0
    }

    // swiftformat:disable:next modifierOrder
    nonisolated private static func parseSpeed(_ line: String) -> String {
        guard let range = line.range(of: #"at\s+\S+"#, options: .regularExpression) else {
            return ""
        }
        return String(line[range])
    }
}
