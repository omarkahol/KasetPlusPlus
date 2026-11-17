import Foundation
import Testing
@testable import KasetPlus

@Suite("Playback & media key sync regressions", .serialized, .tags(.service))
@MainActor
struct PlaybackSyncRegressionTests {
    @Test("Caption normalization treats empty and 'off' codes as nil")
    func captionNormalization() {
        #expect(YouTubePlayerService.normalizedCaptionLanguageCode(nil) == nil)
        #expect(YouTubePlayerService.normalizedCaptionLanguageCode("") == nil)
        #expect(YouTubePlayerService.normalizedCaptionLanguageCode("   ") == nil)
        #expect(YouTubePlayerService.normalizedCaptionLanguageCode("off") == nil)
        #expect(YouTubePlayerService.normalizedCaptionLanguageCode("OFF") == nil)
        #expect(YouTubePlayerService.normalizedCaptionLanguageCode(" en ") == "en")
    }

    @Test("Music starting transfers PlaybackArbiter activeSource from video to music")
    func arbiterTransfersSourceToMusic() {
        let playerService = PlayerService()
        let youtubeService = YouTubePlayerService(webKitManager: .shared)
        let arbiter = PlaybackArbiter(playerService: playerService, youtubePlayerService: youtubeService)

        arbiter.videoWillStartPlaying()
        #expect(arbiter.activeSource == .video)

        arbiter.musicDidStartPlaying()
        #expect(arbiter.activeSource == .music)
        #expect(arbiter.routesMediaKeysToVideo == false)
    }

    @Test("Native video playPause resumes immediately when paused even after prior resume intent")
    func nativeVideoPlayPauseResumesWhenPaused() {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(webKitManager: .shared, playbackController: controller)
        let video = YouTubeVideo(
            videoId: "vid1",
            title: "Test Video",
            channelName: "Channel",
            channelId: nil,
            lengthText: "2:00",
            viewCountText: nil,
            publishedText: nil,
            thumbnailURL: nil
        )

        service.play(video: video)
        // Simulate native video paused before playback started.
        service.performPause()
        #expect(service.isPlaying == false)

        // First playPause press must resume immediately, not pause again.
        service.performPlayPause()
        #expect(service.isPlaying == true)
    }
}
