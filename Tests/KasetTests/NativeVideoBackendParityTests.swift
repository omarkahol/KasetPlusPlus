import Foundation
import Testing
@testable import KasetPlus

@Suite("Native video backend parity", .serialized, .tags(.service))
@MainActor
struct NativeVideoBackendParityTests {
    @Test("preferredPeakBitRate maps YouTube quality identifiers to expected bitrate caps")
    func qualityBitrateMapping() {
        #expect(NativeVideoPlayer.preferredPeakBitRate(for: "hd2160") == 20_000_000)
        #expect(NativeVideoPlayer.preferredPeakBitRate(for: "hd1080") == 5_000_000)
        #expect(NativeVideoPlayer.preferredPeakBitRate(for: "hd720") == 2_500_000)
        #expect(NativeVideoPlayer.preferredPeakBitRate(for: "auto") == 0)
    }

    @Test("Native video mode routes quality, caption, and audio selections without touching WebKit controller")
    func nativeVideoRoutesBackendControlsWithoutWebKit() {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(
            playbackController: controller,
            prefersNativeVideoStreaming: true,
            streamURLResolver: { _ in URL(string: "https://example.com/stream.m3u8") }
        )
        let video = MockYouTubeClient.makeVideo(videoId: "native-1")
        service.play(video: video)

        service.selectQuality("hd1080")
        service.selectCaptionTrack(languageCode: "en")
        service.selectAudioTrack(id: "es")

        #expect(service.isPlayingNativeVideo == true)
        #expect(service.currentQuality == "hd1080")
        #expect(service.activeCaptionLanguageCode == "en")
        #expect(service.activeAudioTrackId == "es")
        #expect(controller.selectedQuality == nil)
        #expect(controller.selectedCaption == nil)
        #expect(controller.selectedAudioTrackId == nil)

        NativeVideoPlayer.shared.stop()
        NativeVideoPlayer.shared.setQualityLevel("auto")
    }
}
