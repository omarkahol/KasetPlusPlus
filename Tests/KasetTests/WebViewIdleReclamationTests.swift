import Testing
@testable import KasetPlus

@Suite("WebView idle reclamation", .serialized, .tags(.service))
@MainActor
struct WebViewIdleReclamationTests {
    @Test("Policy permits YouTube WebView reclamation only when native video is settled")
    func youtubeReclamationPolicy() {
        #expect(WebViewIdleReclamationPolicy.shouldReclaimYouTubeWatchWebView(
            isPlayingNativeVideo: true,
            isPlaybackLoading: false,
            isIdentityReloadInFlight: false
        ) == true)

        #expect(WebViewIdleReclamationPolicy.shouldReclaimYouTubeWatchWebView(
            isPlayingNativeVideo: false,
            isPlaybackLoading: false,
            isIdentityReloadInFlight: false
        ) == false)

        #expect(WebViewIdleReclamationPolicy.shouldReclaimYouTubeWatchWebView(
            isPlayingNativeVideo: true,
            isPlaybackLoading: true,
            isIdentityReloadInFlight: false
        ) == false)
    }

    @Test("Policy permits Music WebView reclamation when offline/direct or video source is active")
    func musicReclamationPolicy() {
        #expect(WebViewIdleReclamationPolicy.shouldReclaimMusicWebView(
            isPlayingOfflineOrDirect: true,
            activeSource: .music,
            isMusicPlaying: true,
            isAwaitingWebConfirmation: false
        ) == true)

        #expect(WebViewIdleReclamationPolicy.shouldReclaimMusicWebView(
            isPlayingOfflineOrDirect: false,
            activeSource: .video,
            isMusicPlaying: false,
            isAwaitingWebConfirmation: false
        ) == true)

        #expect(WebViewIdleReclamationPolicy.shouldReclaimMusicWebView(
            isPlayingOfflineOrDirect: false,
            activeSource: .music,
            isMusicPlaying: true,
            isAwaitingWebConfirmation: false
        ) == false)

        #expect(WebViewIdleReclamationPolicy.shouldReclaimMusicWebView(
            isPlayingOfflineOrDirect: true,
            activeSource: .music,
            isMusicPlaying: false,
            isAwaitingWebConfirmation: false,
            isAuthSyncInFlight: true
        ) == false)
    }

    @Test("Scheduler cancels pending reclamation when cancelled before grace period")
    func schedulerCancelsCleanly() async throws {
        let scheduler = WebViewIdleReclamationScheduler(graceDuration: .milliseconds(40))
        var didReclaim = false

        scheduler.schedule {
            didReclaim = true
        }
        scheduler.cancel()
        try await Task.sleep(for: .milliseconds(70))

        #expect(didReclaim == false)
    }

    @Test("Scheduler runs reclamation after grace period when not cancelled")
    func schedulerReclaimsAfterGrace() async throws {
        let scheduler = WebViewIdleReclamationScheduler(graceDuration: .milliseconds(25))
        var didReclaim = false

        scheduler.schedule {
            didReclaim = true
        }
        for _ in 0 ..< 50 where !didReclaim {
            try await Task.sleep(for: .milliseconds(15))
        }

        #expect(didReclaim == true)
    }
}
