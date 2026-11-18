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

    @Test("Switching quality on an active HLS stream replaces the player item to force variant switch")
    func switchingQualityReloadsActiveHLSItem() {
        let player = NativeVideoPlayer.shared
        player.stop()
        player.setQualityLevel("auto")

        guard let hlsURL = URL(string: "https://manifest.googlevideo.com/api/manifest/hls_variant/test.m3u8") else {
            Issue.record("Failed to construct test HLS URL")
            return
        }

        player.play(url: hlsURL, videoId: "hls-quality-test")
        let initialItem = player.player?.currentItem
        #expect(initialItem != nil)
        #expect(initialItem?.preferredPeakBitRate == 0)

        player.setQualityLevel("hd1080")
        let updatedItem = player.player?.currentItem
        #expect(updatedItem != nil)
        #expect(updatedItem !== initialItem)
        #expect(updatedItem?.preferredPeakBitRate == 0)

        player.stop()
        player.setQualityLevel("auto")
    }
}
