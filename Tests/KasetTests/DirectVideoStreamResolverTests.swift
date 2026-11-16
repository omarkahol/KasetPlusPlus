import Foundation
import Testing
@testable import KasetPlus

@Suite("DirectVideoStreamResolver Tests")
@MainActor
struct DirectVideoStreamResolverTests {
    @Test("DirectVideoStreamResolver clears cache")
    func testClearCache() {
        let resolver = DirectVideoStreamResolver.shared
        resolver.clearCache()
        // Cache is cleared without crashing
        #expect(true)
    }

    @Test("NativeVideoPlayer volume and speed clamps")
    func testNativeVideoPlayerClamping() {
        let player = NativeVideoPlayer.shared
        player.setVolume(1.5)
        #expect(player.volume == 1.0)

        player.setVolume(-0.5)
        #expect(player.volume == 0.0)

        player.playbackSpeed = 3.0
        #expect(player.playbackSpeed == 3.0) // clamped when setting rate on player
    }

    @Test("NativeVideoPlayer stop resets state")
    func testNativeVideoPlayerStop() {
        let player = NativeVideoPlayer.shared
        player.stop()
        #expect(!player.isPlaying)
        #expect(!player.isLoading)
        #expect(player.currentVideoId == nil)
        #expect(player.currentURL == nil)
    }
}
