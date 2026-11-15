import Foundation
@testable import KasetPlus
import Testing

@Suite("Download Manager Tests")
struct DownloadManagerTests {
    @Test("DownloadedSong correctly converts to Song model")
    func downloadedSongConversion() {
        let artist = Artist(id: "art1", name: "Daft Punk")
        let downloaded = DownloadedSong(
            id: "vid123",
            videoId: "vid123",
            title: "One More Time",
            artists: [artist],
            albumTitle: "Discovery",
            duration: 320,
            artworkPath: "Artworks/vid123.jpg",
            localRelativePath: "One More Time [vid123].m4a",
            fileSize: 10_000_000,
            downloadDate: Date(),
            audioFormat: "m4a",
            likeStatus: .like
        )

        let baseDir = URL(fileURLWithPath: "/Users/test/Music/KasetPlus Downloads")
        let song = downloaded.toSong(baseDirectory: baseDir)

        #expect(song.id == "vid123")
        #expect(song.videoId == "vid123")
        #expect(song.title == "One More Time")
        #expect(song.artists.count == 1)
        #expect(song.artists.first?.name == "Daft Punk")
        #expect(song.album?.title == "Discovery")
        #expect(song.duration == 320)
        #expect(song.isPlayable == true)
        #expect(song.likeStatus == .like)
        #expect(downloaded.fileURL(baseDirectory: baseDir).path == "/Users/test/Music/KasetPlus Downloads/One More Time [vid123].m4a")
        #expect(song.thumbnailURL?.path == "/Users/test/Music/KasetPlus Downloads/Artworks/vid123.jpg")
    }

    @Test("Subdirectory structure for music and videos resolves properly")
    func subdirectoryPaths() {
        let musicTrack = DownloadedSong(
            id: "m1",
            videoId: "m1",
            title: "Music Song",
            artists: [],
            albumTitle: nil,
            duration: 120,
            artworkPath: "Artworks/m1.jpg",
            localRelativePath: "Music/Music Song [m1].m4a",
            fileSize: 1000,
            downloadDate: Date(),
            audioFormat: "m4a",
            mediaType: .audio
        )

        let videoTrack = DownloadedSong(
            id: "v1",
            videoId: "v1",
            title: "Video Song",
            artists: [],
            albumTitle: nil,
            duration: 240,
            artworkPath: "Artworks/v1.jpg",
            localRelativePath: "Videos/Video Song [v1].mp4",
            fileSize: 5000,
            downloadDate: Date(),
            audioFormat: "mp4",
            mediaType: .video
        )

        let baseDir = URL(fileURLWithPath: "/Users/test/Music/KasetPlus Downloads")
        #expect(musicTrack.fileURL(baseDirectory: baseDir).path == "/Users/test/Music/KasetPlus Downloads/Music/Music Song [m1].m4a")
        #expect(videoTrack.fileURL(baseDirectory: baseDir).path == "/Users/test/Music/KasetPlus Downloads/Videos/Video Song [v1].mp4")
    }

    @Test("DownloadAudioFormat flags map correctly to yt-dlp arguments")
    func downloadAudioFormatArguments() {
        let best = SettingsManager.DownloadAudioFormat.bestAudio
        #expect(best.fileExtension == "m4a")
        #expect(best.ytDlpArguments.contains("m4a"))

        let mp3 = SettingsManager.DownloadAudioFormat.mp3_320
        #expect(mp3.fileExtension == "mp3")
        #expect(mp3.ytDlpArguments.contains("mp3"))

        let opus = SettingsManager.DownloadAudioFormat.opus
        #expect(opus.fileExtension == "opus")
        #expect(opus.ytDlpArguments.contains("opus"))
    }

    @Test("VideoDownloadQuality flags map correctly to yt-dlp arguments")
    func videoDownloadQualityArguments() {
        let best = SettingsManager.VideoDownloadQuality.best
        #expect(best.fileExtension == "mp4")
        #expect(best.ytDlpArguments.contains("-f"))
        #expect(best.formatSelector.contains("bestvideo+bestaudio/best"))

        let fhd = SettingsManager.VideoDownloadQuality.res1080p
        #expect(fhd.formatSelector.contains("height<=1080"))

        let hd = SettingsManager.VideoDownloadQuality.res720p
        #expect(hd.formatSelector.contains("height<=720"))

        let sd = SettingsManager.VideoDownloadQuality.res480p
        #expect(sd.formatSelector.contains("height<=480"))
    }

    @Test("MediaType encoding and decoding works with default backward compatibility")
    func mediaTypeCodable() throws {
        let audioSong = DownloadedSong(
            id: "vid_audio",
            videoId: "vid_audio",
            title: "Audio Track",
            artists: [],
            albumTitle: nil,
            duration: 100,
            artworkPath: nil,
            localRelativePath: "Audio Track [vid_audio].m4a",
            fileSize: 1000,
            downloadDate: Date(),
            audioFormat: "m4a",
            likeStatus: nil,
            mediaType: .audio
        )

        let videoSong = DownloadedSong(
            id: "vid_video",
            videoId: "vid_video",
            title: "Video Track",
            artists: [],
            albumTitle: nil,
            duration: 200,
            artworkPath: nil,
            localRelativePath: "Video Track [vid_video].mp4",
            fileSize: 5000,
            downloadDate: Date(),
            audioFormat: "mp4",
            likeStatus: nil,
            mediaType: .video
        )

        let encoder = JSONEncoder()
        let audioData = try encoder.encode(audioSong)
        let videoData = try encoder.encode(videoSong)

        let decoder = JSONDecoder()
        let decodedAudio = try decoder.decode(DownloadedSong.self, from: audioData)
        let decodedVideo = try decoder.decode(DownloadedSong.self, from: videoData)

        #expect(decodedAudio.mediaType == .audio)
        #expect(decodedVideo.mediaType == .video)

        // Test backward compatibility without mediaType key in JSON
        let legacyJSON = """
        {
            "id": "legacy_vid",
            "videoId": "legacy_vid",
            "title": "Legacy Track",
            "artists": [],
            "localRelativePath": "legacy.m4a",
            "downloadDate": 0,
            "audioFormat": "m4a"
        }
        """.data(using: .utf8)!

        let decodedLegacy = try decoder.decode(DownloadedSong.self, from: legacyJSON)
        #expect(decodedLegacy.mediaType == .audio)
    }

    @Test("Download status correctly identifies active states")
    func downloadStatusStates() {
        let queued = DownloadManager.DownloadStatus.queued
        let preparing = DownloadManager.DownloadStatus.preparing
        let downloading = DownloadManager.DownloadStatus.downloading(progress: 0.45, speed: "2.5MiB/s")
        let completed = DownloadManager.DownloadStatus.completed(fileURL: URL(fileURLWithPath: "/tmp/song.m4a"))
        let failed = DownloadManager.DownloadStatus.failed(error: "Network error")

        #expect(queued.isDownloading)
        #expect(preparing.isDownloading)
        #expect(downloading.isDownloading)
        #expect(!completed.isDownloading)
        #expect(!failed.isDownloading)

        #expect(downloading.progress == 0.45)
        #expect(completed.progress == 1.0)
        #expect(queued.progress == 0.0)
    }

    @Test("NavigationItem includes downloads case with correct attributes")
    func navigationItemDownloads() {
        let item = NavigationItem.downloads
        #expect(item.displayName == "Downloads")
        #expect(item.icon == "arrow.down.circle")
        #expect(!item.requiresSignIn)
    }

    @Test("Canceling download and re-enqueuing resets state cleanly")
    @MainActor
    func cancelAndReenqueue() {
        let manager = DownloadManager.shared
        let dummySong = Song(
            id: "test_cancel_id",
            title: "Test Cancel Song",
            artists: [Artist(id: "a1", name: "Artist")],
            duration: 180,
            thumbnailURL: nil,
            videoId: "test_cancel_id"
        )

        // Enqueue song
        manager.download(song: dummySong)
        #expect(manager.status(for: "test_cancel_id") != nil)

        // Cancel
        manager.cancel(videoId: "test_cancel_id")
        #expect(manager.status(for: "test_cancel_id") == nil)

        // Re-enqueue after cancel
        manager.download(song: dummySong)
        #expect(manager.status(for: "test_cancel_id") != nil)

        // Clean up
        manager.cancel(videoId: "test_cancel_id")
        #expect(manager.status(for: "test_cancel_id") == nil)
    }
}
