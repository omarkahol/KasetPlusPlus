import Foundation
import JavaScriptCore
import Testing
@testable import KasetPlus

@Suite("Slow buffering autoplay regressions", .serialized, .tags(.service))
@MainActor
struct SlowBufferingAutoplayRegressionTests {
    @Test("Music observer recovers autoplay on canplaythrough even after initial retries exhausted")
    func musicObserverRecoversAutoplayOnCanplaythroughAfterExhaustion() throws {
        let context = try MusicPlaybackObserverTestContext.make(setup: """
        video.paused = true;
        video.readyState = 2;
        window.__kasetAutoplayPending = true;
        window.__kasetAutoplayAttempts = 5;
        """)

        context.evaluateScript("dispatch('canplaythrough');")

        #expect(context.evaluateScript("video.paused").toBool() == false)
        #expect(context.evaluateScript("window.__kasetAutoplayAttempts").toInt32() == 1)
        #expect(context.exception == nil)
    }

    @Test("Music autoplay intent sync triggers recovery when video is already ready and paused")
    func musicAutoplaySyncTriggersRecoveryWhenVideoAlreadyReady() throws {
        let context = try MusicPlaybackObserverTestContext.make(setup: """
        video.paused = true;
        video.readyState = 3;
        """)

        context.evaluateScript(SingletonPlayerWebView.autoplayIntentSynchronizationScript(
            shouldAutoplay: true,
            nativePlaybackGeneration: 1,
            documentGeneration: 7
        ))

        #expect(context.evaluateScript("video.paused").toBool() == false)
        #expect(context.exception == nil)
    }

    @Test("Music PlayerService rejects non-ready samples while settling ready-paused for first-toggle resume")
    func musicPlayerServicePreservesLoadingStateDuringSlowBuffering() async {
        let playerService = PlayerService()
        let song = Song(
            id: "slow-song",
            title: "Slow Buffering Song",
            artists: [Artist(id: "a1", name: "Artist")],
            videoId: "slow-vid"
        )
        playerService.currentTrack = song
        playerService.pendingPlayVideoId = "slow-vid"
        playerService.currentWebPlaybackVideoId = { "slow-vid" }
        playerService.state = .loading
        playerService.shouldResumeAfterInterruption = true
        playerService.isAwaitingPlaybackConfirmation = true
        playerService.isExplicitPauseIntentActive = false

        // Non-ready buffering samples are filtered out by the bridge gate, preserving `.loading`.
        #expect(!SingletonPlayerWebView.isAuthoritativePlaybackSample(hasReadyMedia: false, isShowingAd: false))
        #expect(playerService.state == .loading)

        // Once a ready-paused sample arrives, state settles cleanly to `.paused` so the very first
        // toggle (`playPause()`) immediately calls `resume()` rather than pausing and needing a second click.
        playerService.updatePlaybackState(
            isPlaying: false,
            progress: 0,
            duration: 180,
            observedVideoId: "slow-vid"
        )

        #expect(playerService.state == .paused)
        #expect(!playerService.isAwaitingPlaybackConfirmation)

        await playerService.playPause()
        #expect(playerService.shouldResumeAfterInterruption)
        #expect(playerService.isAwaitingPlaybackConfirmation)
    }

    @Test("YouTube watch observer recovers autoplay on canplay/canplaythrough when not natively paused")
    func youtubeWatchObserverRecoversAutoplayOnSlowLoad() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var listeners = {};
        function addListener(name, cb) {
            if (!listeners[name]) listeners[name] = [];
            listeners[name].push(cb);
        }
        function dispatch(name) {
            (listeners[name] || []).forEach(function(cb) { cb({ currentTarget: video }); });
        }
        var Date = { now: function() { return 1000; } };
        function setTimeout() { return 1; }
        function clearTimeout() {}
        function setInterval() { return 1; }
        function clearInterval() {}
        function MutationObserver() { this.observe = function() {}; }

        var playCalls = 0;
        var video = {
            paused: true,
            ended: false,
            currentSrc: 'https://media.example/v1',
            currentTime: 0,
            duration: 120,
            readyState: 3,
            volume: 1,
            muted: false,
            playbackRate: 1,
            error: null,
            addEventListener: addListener,
            pause: function() { this.paused = true; },
            play: function() { playCalls += 1; this.paused = false; }
        };
        var moviePlayer = {
            classList: { contains: function() { return false; } },
            getVideoData: function() { return { video_id: 'yt1', title: 'Slow Video' }; },
            playVideo: function() {}
        };
        var document = {
            readyState: 'complete',
            title: 'Slow Video - YouTube',
            body: {},
            addEventListener: function() {},
            getElementById: function(id) { return id === 'movie_player' ? moviePlayer : null; },
            querySelectorAll: function() { return []; },
            querySelector: function(sel) {
                if (sel === '#movie_player video' || sel === 'video') return video;
                return null;
            }
        };
        var window = globalThis;
        window.location = { href: 'https://www.youtube.com/watch?v=yt1' };
        window.__kasetDocumentGeneration = 1;
        window.__kasetNativePausePending = false;
        window.__kasetAutoplayPending = true;
        window.webkit = { messageHandlers: { youtubePlayer: { postMessage: function() {} } } };
        """)
        context.evaluateScript(YouTubeWatchWebView.observerScript)
        context.evaluateScript("dispatch('canplay');")

        #expect(context.evaluateScript("playCalls").toInt32() >= 1)
        #expect(context.evaluateScript("video.paused").toBool() == false)
        #expect(context.exception == nil)
    }

    @Test("YouTubePlayerService fallbackToWebKitWatch refreshes loading timeout after slow stream resolution")
    func youtubePlayerServiceFallbackRefreshesLoadingTimeout() async throws {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(
            playbackController: controller,
            playbackLoadingTimeout: .milliseconds(600),
            streamURLResolver: { _ in
                try? await Task.sleep(for: .milliseconds(120))
                return nil
            }
        )
        let video = MockYouTubeClient.makeVideo(videoId: "slow-yt")

        service.play(video: video)

        // Wait until stream resolution fails and fallbackToWebKitWatch loads WebKit,
        // then allow a brief margin under the refreshed 600ms window.
        for _ in 0 ..< 50 where controller.loadedVideoIds.isEmpty {
            try await Task.sleep(for: .milliseconds(15))
        }
        try await Task.sleep(for: .milliseconds(150))

        #expect(controller.loadedVideoIds == ["slow-yt"])
        #expect(service.isPlaybackLoading == true)
        #expect(service.pendingPausedIdentityReloadVideoId == nil)
        #expect(controller.cancelPendingLoadCount == 0)

        // Now deliver ready media from WebKit; playback adopts cleanly without manual Play.
        service.updatePlaybackState(.init(
            isPlaying: true,
            progress: 0,
            duration: 120,
            hasReadyMedia: true,
            videoId: "slow-yt",
            boundVideoId: "slow-yt"
        ))

        #expect(service.isPlaybackLoading == false)
        #expect(service.isPlaying == true)
    }

    @Test("Music observer back-to-back canplay and canplaythrough never toggle-pauses via play-pause button")
    func musicObserverCanplayAndCanplaythroughNeverTogglePauses() throws {
        let context = try MusicPlaybackObserverTestContext.make(setup: """
        var toggleButtonClicks = 0;
        var toggleButton = {
            click: function() {
                toggleButtonClicks += 1;
                video.paused = !video.paused;
            }
        };
        var originalQuerySelector = document.querySelector;
        document.querySelector = function(selector) {
            if (selector === 'ytmusic-player-bar #play-pause-button'
                || selector === '#play-pause-button') {
                return toggleButton;
            }
            return originalQuerySelector(selector);
        };
        video.paused = true;
        video.readyState = 2;
        window.__kasetAutoplayPending = true;
        """)

        context.evaluateScript("dispatch('canplay'); dispatch('canplaythrough');")

        #expect(context.evaluateScript("toggleButtonClicks").toInt32() == 0)
        #expect(context.evaluateScript("video.paused").toBool() == false)
        #expect(context.exception == nil)
    }

    @Test("YouTube watch observer keeps autoplay pending on stalled play event until playing")
    func youtubeWatchObserverKeepsAutoplayPendingUntilPlaying() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var listeners = {};
        function addListener(name, cb) {
            if (!listeners[name]) listeners[name] = [];
            listeners[name].push(cb);
        }
        function dispatch(name) {
            (listeners[name] || []).forEach(function(cb) { cb({ type: name, currentTarget: video }); });
        }
        var Date = { now: function() { return 1000; } };
        function setTimeout() { return 1; }
        function clearTimeout() {}
        function setInterval() { return 1; }
        function clearInterval() {}
        function MutationObserver() { this.observe = function() {}; }

        var playCalls = 0;
        var video = {
            paused: true,
            ended: false,
            currentSrc: 'https://media.example/v1',
            currentTime: 0,
            duration: 120,
            readyState: 2,
            volume: 1,
            muted: false,
            playbackRate: 1,
            error: null,
            addEventListener: addListener,
            pause: function() { this.paused = true; },
            play: function() { playCalls += 1; this.paused = false; }
        };
        var moviePlayer = {
            classList: { contains: function() { return false; } },
            getVideoData: function() { return { video_id: 'yt1', title: 'Slow Video' }; },
            playVideo: function() {}
        };
        var document = {
            readyState: 'complete',
            title: 'Slow Video - YouTube',
            body: {},
            addEventListener: function() {},
            getElementById: function(id) { return id === 'movie_player' ? moviePlayer : null; },
            querySelectorAll: function() { return []; },
            querySelector: function(sel) {
                if (sel === '#movie_player video' || sel === 'video') return video;
                return null;
            }
        };
        var window = globalThis;
        window.location = { href: 'https://www.youtube.com/watch?v=yt1' };
        window.__kasetDocumentGeneration = 1;
        window.__kasetNativePausePending = false;
        window.__kasetAutoplayPending = true;
        window.webkit = { messageHandlers: { youtubePlayer: { postMessage: function() {} } } };
        """)
        context.evaluateScript(YouTubeWatchWebView.observerScript)

        // Initial 'play' fires while video stays paused/stalled (before 'playing')
        context.evaluateScript("dispatch('play');")
        #expect(context.evaluateScript("window.__kasetAutoplayPending").toBool() == true)

        // When media becomes ready on 'canplay', autoplay recovery triggers video.play()
        context.evaluateScript("video.readyState = 3; dispatch('canplay');")
        #expect(context.evaluateScript("playCalls").toInt32() >= 1)
        #expect(context.evaluateScript("video.paused").toBool() == false)

        // Once 'playing' fires while unpaused, autoplay intent clears cleanly
        context.evaluateScript("dispatch('playing');")
        #expect(context.evaluateScript("window.__kasetAutoplayPending").toBool() == false)
        #expect(context.exception == nil)
    }

    @Test("YouTubePlayerService advance routes next video through NativeVideoPlayer when native streaming is enabled")
    func youtubePlayerServiceAdvanceRoutesThroughNativePlayer() async throws {
        defer { NativeVideoPlayer.shared.stop() }
        let controller = MockYouTubeWatchPlaybackController()
        var resolvedIds: [String] = []
        let service = YouTubePlayerService(
            playbackController: controller,
            prefersNativeVideoStreaming: true,
            streamURLResolver: { videoId in
                resolvedIds.append(videoId)
                return URL(string: "https://example.com/\(videoId).m3u8")
            }
        )
        let first = MockYouTubeClient.makeVideo(videoId: "first-vid")
        let next = MockYouTubeClient.makeVideo(videoId: "next-vid")

        service.play(video: first)
        try await Task.sleep(for: .milliseconds(30))
        service.setUpNext([next])

        await service.skipForward()
        try await Task.sleep(for: .milliseconds(30))

        #expect(resolvedIds == ["first-vid", "next-vid"])
        #expect(service.currentVideo?.videoId == "next-vid")
        #expect(service.isPlayingNativeVideo == true)
        #expect(NativeVideoPlayer.shared.currentVideoId == "next-vid")
        #expect(controller.loadedVideoIds.isEmpty)
    }
}
