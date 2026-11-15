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
