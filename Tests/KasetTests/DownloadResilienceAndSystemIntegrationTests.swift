import CoreSpotlight
import Foundation
import Testing
@testable import KasetPlus

@Suite("Download resilience & macOS integration", .serialized, .tags(.service))
@MainActor
struct DownloadResilienceAndSystemIntegrationTests {
    @Test("cleanupOrphanedPartialFiles removes .part/.ytdl/.temp files and preserves completed media")
    func cleansOrphanedPartialFilesOnly() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaset-download-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let partFile = tempDir.appendingPathComponent("song1.m4a.part")
        let ytdlFile = tempDir.appendingPathComponent("song1.m4a.ytdl")
        let fragFile = tempDir.appendingPathComponent("song1.part-Frag12")
        let completedFile = tempDir.appendingPathComponent("song2.m4a")

        FileManager.default.createFile(atPath: partFile.path, contents: Data("p".utf8))
        FileManager.default.createFile(atPath: ytdlFile.path, contents: Data("y".utf8))
        FileManager.default.createFile(atPath: fragFile.path, contents: Data("f".utf8))
        FileManager.default.createFile(atPath: completedFile.path, contents: Data("ok".utf8))

        let removed = DownloadManager.cleanupOrphanedPartialFiles(in: [tempDir])

        #expect(removed == 3)
        #expect(!FileManager.default.fileExists(atPath: partFile.path))
        #expect(!FileManager.default.fileExists(atPath: ytdlFile.path))
        #expect(!FileManager.default.fileExists(atPath: fragFile.path))
        #expect(FileManager.default.fileExists(atPath: completedFile.path))
    }

    @Test("makeHandoffActivity builds valid YouTube and YouTube Music web URLs")
    func handoffActivityBuildsExpectedURLs() {
        let musicActivity = SpotlightIndexService.makeHandoffActivity(
            videoId: "abc123",
            title: "Track Title",
            isYouTubeVideo: false
        )
        #expect(musicActivity?.webpageURL?.absoluteString == "https://music.youtube.com/watch?v=abc123")
        #expect(musicActivity?.isEligibleForHandoff == true)

        let videoActivity = SpotlightIndexService.makeHandoffActivity(
            videoId: "xyz789",
            title: "Video Title",
            isYouTubeVideo: true
        )
        #expect(videoActivity?.webpageURL?.absoluteString == "https://www.youtube.com/watch?v=xyz789")
        #expect(videoActivity?.isEligibleForHandoff == true)

        #expect(SpotlightIndexService.makeHandoffActivity(videoId: " ", title: "", isYouTubeVideo: false) == nil)
    }

    @Test("makeSearchableItem populates CoreSpotlight metadata for downloaded tracks")
    func searchableItemPopulatesMetadata() {
        let baseDir = URL(fileURLWithPath: "/tmp/kaset-downloads")
        let song = DownloadedSong(
            id: "vid-1",
            videoId: "vid-1",
            title: "Offline Track",
            artists: [Artist(id: "a1", name: "Offline Artist")],
            albumTitle: "Offline Album",
            duration: 215,
            artworkPath: "Artwork/vid-1.jpg",
            localRelativePath: "Music/vid-1.m4a",
            fileSize: 4_000_000,
            downloadDate: Date(),
            audioFormat: "m4a",
            mediaType: .audio
        )

        let item = SpotlightIndexService.makeSearchableItem(for: song, baseDirectory: baseDir)

        #expect(item.uniqueIdentifier == "vid-1")
        #expect(item.domainIdentifier == SpotlightIndexService.domainIdentifier)
        #expect(item.attributeSet.title == "Offline Track")
        #expect(item.attributeSet.artist == "Offline Artist")
        #expect(item.attributeSet.album == "Offline Album")
        #expect(item.attributeSet.duration == 215)
    }
}
