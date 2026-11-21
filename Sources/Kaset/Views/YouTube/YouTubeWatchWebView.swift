import os
import SwiftUI
import WebKit

// MARK: - YouTubeWatchWebView

/// Manages the single WebView used for regular YouTube video playback.
///
/// Parallel to `SingletonPlayerWebView` (music) but tuned to youtube.com
/// watch pages: its own observer script (`#movie_player` instead of
/// `ytmusic-*` selectors), its own message handler name (`youtubePlayer`),
/// and a chrome-hiding extraction that leaves only the video surface
/// visible so the page can dock into native Kaset views.
///
/// Exactly one of music/video produces audio at a time — `PlaybackArbiter`
/// enforces the handoff.
@MainActor
final class YouTubeWatchWebView {
    static let shared = YouTubeWatchWebView()

    /// Creates an isolated wrapper for tests that exercise WebView lifecycle state.
    static func makeTestInstance(webView: WKWebView? = nil) -> YouTubeWatchWebView {
        let instance = YouTubeWatchWebView()
        instance.webView = webView
        return instance
    }

    private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
        private weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            self.coordinator?.userContentController(userContentController, didReceive: message)
        }
    }

    private(set) var webView: WKWebView?
    weak var webKitManager: WebKitManager?
    private weak var currentContainer: NSView?
    private var usesCookieFreeDataStore: Bool?
    var currentVideoId: String?
    var coordinator: Coordinator?
    private var scriptMessageHandler: WeakScriptMessageHandler?
    let logger = DiagnosticsLogger.player

    /// Seek position (seconds) to apply once the next page finishes loading.
    /// Used to resume a video at its prior position after a forced reload (e.g.
    /// an account/session-identity switch), since the `<video>` element does not
    /// exist until the new document loads. Cleared on apply.
    var pendingSeek: Double?

    /// Monotonic counter for `load(videoId:)` calls. The pre-navigation pause is
    /// async, so a newer load can be requested before an older one's callback
    /// issues `webView.load`. The callback captures the generation and bails if
    /// superseded, so a stale reload can't navigate over a newer selection.
    private var loadGeneration = 0

    /// Tracks which full-page watch document may publish playback bridge events.
    var documentGeneration = WebPlaybackDocumentGeneration()
    var documentNavigations = WebPlaybackNavigationMap<WKNavigation, WebPlaybackTrackedNavigation>()
    var cancelledDocumentNavigations = WebPlaybackNavigationMap<WKNavigation, WebPlaybackCancelledNavigation>()
    var continuationGenerationsAwaitingStart: Set<UInt64> = []
    var pendingSeeksByGeneration: [UInt64: Double] = [:]
    var pendingSeekVideoIdsByGeneration: [UInt64: String] = [:]
    var pendingSeekAttemptIDsByGeneration: [UInt64: UInt64] = [:]
    var nextPendingSeekAttemptID: UInt64 = 0
    var cancelledPendingSeekGenerations: Set<UInt64> = []
    var directSeekGenerations: Set<UInt64> = []
    var pendingSeekRetryCounts: [UInt64: Int] = [:]

    private init() {}

    /// Get or create the watch WebView.
    func getWebView(
        webKitManager: WebKitManager,
        playerService: YouTubePlayerService,
        usesCookieFreeDataStore: Bool = false
    ) -> WKWebView {
        if let existing = webView, self.usesCookieFreeDataStore == usesCookieFreeDataStore {
            return existing
        }
        let previousContainer = self.currentContainer
        if self.webView != nil {
            self.logger.info("Recreating YouTube watch WebView for auth data-store boundary")
            self.tearDown()
        }

        self.logger.info("Creating YouTube watch WebView")
        self.usesCookieFreeDataStore = usesCookieFreeDataStore

        let coordinator = Coordinator(playerService: playerService)
        self.coordinator = coordinator

        let configuration = webKitManager.createWebViewConfiguration(
            websiteDataStore: usesCookieFreeDataStore ? .nonPersistent() : nil,
            // Never network-block ads on the YouTube player: it stalls the
            // player on the killed ad request and blanks the video. The DOM
            // skip script (installed below when ad blocking is on) handles
            // client-side ads without breaking playback.
            applyAdBlock: false
        )
        let messageHandler = WeakScriptMessageHandler(coordinator: coordinator)
        self.scriptMessageHandler = messageHandler
        configuration.userContentController.add(messageHandler, name: "youtubePlayer")
        self.installUserScripts(
            on: configuration.userContentController,
            targetVolume: playerService.volume,
            documentGeneration: Self.userScriptDocumentGeneration(from: self.documentGeneration)
        )

        let newWebView = ScrollForwardingWebView(frame: .zero, configuration: configuration)
        newWebView.navigationDelegate = coordinator
        newWebView.customUserAgent = WebKitManager.userAgent
        self.webKitManager = webKitManager
        webKitManager.registerExtensionHostWebView(newWebView, role: .youtubeWatch)

        // Kill the white flash between page navigations.
        newWebView.underPageBackgroundColor = .black

        #if DEBUG
            newWebView.isInspectable = true
        #endif

        self.webView = newWebView
        if let previousContainer {
            self.ensureInHierarchy(container: previousContainer)
        }
        return newWebView
    }

    /// Ensures the WebView fills the given container (reparenting if needed).
    func ensureInHierarchy(
        container: NSView,
        expectedVideoId: String? = nil,
        selectedVideoId: String? = nil
    ) {
        guard let webView, YouTubeWatchSurfaceAttachment.claim(
            surface: webView,
            in: container,
            expectedVideoId: expectedVideoId,
            currentVideoId: selectedVideoId
        ) else { return }
        self.currentContainer = container
        self.webKitManager?.extensionHostWebViewDidBecomeActive(webView)
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
    }

    /// Loads a watch page for the given video, skipping if it is already current.
    func loadVideo(videoId: String) {
        guard videoId != self.currentVideoId else {
            self.logger.debug("YouTube video \(videoId) already loaded, skipping")
            return
        }
        // A normal (non-reload) load starts a fresh video: drop any pending
        // resume-seek left over from an interrupted identity-switch reload, so it
        // cannot be injected into a different video's document.
        self.pendingSeek = nil
        self.load(videoId: videoId)
    }

    /// Forces a full reload of the given video even when it is already current,
    /// optionally resuming at `resumeAt` seconds once the new page loads.
    ///
    /// Used after an account/session-identity switch: the page identity lives in
    /// the served document, so the in-flight watch page must be re-fetched under
    /// the new session for subsequent watch-history pings to attribute correctly.
    func reloadVideo(videoId: String, resumeAt seconds: Double? = nil) {
        self.logger.info("Force-reloading YouTube video under new session identity: \(videoId)")
        self.pendingSeek = seconds
        self.load(videoId: videoId)
    }

    @discardableResult
    func cancelPendingLoad() -> Bool {
        self.loadGeneration += 1
        var didCancelDocumentNavigation = false
        var cancelledResumeAt = self.pendingSeek
        var cancelledSelectedGeneration = false
        if let generation = self.documentGeneration.pendingGeneration {
            cancelledSelectedGeneration = true
            cancelledResumeAt = self.pendingSeeksByGeneration[generation] ?? cancelledResumeAt
            self.pendingSeeksByGeneration.removeValue(forKey: generation)
            self.pendingSeekVideoIdsByGeneration.removeValue(forKey: generation)
            self.pendingSeekAttemptIDsByGeneration.removeValue(forKey: generation)
            self.pendingSeekRetryCounts.removeValue(forKey: generation)
            self.directSeekGenerations.remove(generation)
            self.documentGeneration.cancelPendingNavigation()
            didCancelDocumentNavigation = true
        }
        if let generation = self.documentGeneration.inFlightGeneration,
           self.documentGeneration.cancelInFlightNavigation(generation)
        {
            cancelledSelectedGeneration = true
            cancelledResumeAt = self.pendingSeeksByGeneration[generation] ?? cancelledResumeAt
            for (identifier, navigation) in self.documentNavigations
                where navigation.generation == generation
            {
                self.cancelledDocumentNavigations[identifier] = WebPlaybackCancelledNavigation(
                    generation: generation,
                    shouldReportFailure: true
                )
            }
            self.documentNavigations = self.documentNavigations.filter {
                $0.value.generation != generation
            }
            self.pendingSeeksByGeneration.removeValue(forKey: generation)
            self.pendingSeekVideoIdsByGeneration.removeValue(forKey: generation)
            self.pendingSeekAttemptIDsByGeneration.removeValue(forKey: generation)
            self.pendingSeekRetryCounts.removeValue(forKey: generation)
            self.directSeekGenerations.remove(generation)
            didCancelDocumentNavigation = true
        }
        let committedLoadingGenerations = self.documentNavigations.values.compactMap { navigation in
            navigation.didCommit && navigation.generation == self.documentGeneration.currentGeneration
                ? navigation.generation
                : nil
        }
        if !committedLoadingGenerations.isEmpty {
            self.documentNavigations = self.documentNavigations.filter { _, navigation in
                !committedLoadingGenerations.contains(navigation.generation)
            }
            for generation in committedLoadingGenerations {
                if !cancelledSelectedGeneration {
                    cancelledResumeAt = self.pendingSeeksByGeneration[generation] ?? cancelledResumeAt
                }
                self.pendingSeeksByGeneration.removeValue(forKey: generation)
                self.pendingSeekVideoIdsByGeneration.removeValue(forKey: generation)
                self.pendingSeekAttemptIDsByGeneration.removeValue(forKey: generation)
                self.pendingSeekRetryCounts.removeValue(forKey: generation)
                self.directSeekGenerations.remove(generation)
            }
            didCancelDocumentNavigation = true
        }
        if didCancelDocumentNavigation, let webView = self.webView {
            // PlayerService already owns the newly selected video. Re-authorizing
            // the outgoing document would split native/WebView identity, so keep
            // the selected video as a deferred reload for explicit resume.
            self.pauseSurvivingDocument(webView)
            self.currentVideoId = nil
            self.pendingSeek = nil
            self.documentGeneration.invalidate()
            self.coordinator?.playerService.handleWebNavigationCancellation(
                resumeAtOverride: cancelledResumeAt
            )
            self.refreshDocumentUserScripts(on: webView)
        }
        self.webView?.stopLoading()
        return didCancelDocumentNavigation
    }

    private func load(videoId: String) {
        guard let webView else {
            self.logger.error("YouTube watch load called but webView is nil")
            return
        }

        self.logger.info("Loading YouTube video: \(videoId) (was: \(self.currentVideoId ?? "none"))")
        self.cancelActiveDocumentNavigation(on: webView)
        self.currentVideoId = videoId

        self.loadGeneration += 1
        let isShort = self.coordinator?.playerService.currentVideo?.videoId == videoId
            && self.coordinator?.playerService.currentVideo?.isShort == true
        let navigationPendingSeek = self.pendingSeek
        let replacedGeneration = self.documentGeneration.currentGeneration
        if let replacedAttemptID = self.pendingSeekAttemptIDsByGeneration[replacedGeneration] {
            self.completePendingSeek(
                generation: replacedGeneration,
                attemptID: replacedAttemptID
            )
        }
        self.pendingSeek = navigationPendingSeek
        if let supersededGeneration = self.documentGeneration.pendingGeneration {
            self.pendingSeeksByGeneration.removeValue(forKey: supersededGeneration)
            self.pendingSeekVideoIdsByGeneration.removeValue(forKey: supersededGeneration)
            self.pendingSeekAttemptIDsByGeneration.removeValue(forKey: supersededGeneration)
            self.pendingSeekRetryCounts.removeValue(forKey: supersededGeneration)
            self.directSeekGenerations.remove(supersededGeneration)
        }
        let navigationGeneration = self.documentGeneration.beginNavigation()
        if let navigationPendingSeek {
            self.pendingSeeksByGeneration[navigationGeneration] = navigationPendingSeek
            self.pendingSeekVideoIdsByGeneration[navigationGeneration] = videoId
            self.pendingSeekRetryCounts[navigationGeneration] = 0
            self.beginPendingSeekAttempt(generation: navigationGeneration)
        }
        let targetVolume = self.coordinator?.playerService.volume ?? 1.0
        self.installUserScripts(
            on: webView.configuration.userContentController,
            targetVolume: targetVolume,
            documentGeneration: navigationGeneration,
            pendingSeek: navigationPendingSeek,
            pendingSeekVideoId: navigationPendingSeek == nil ? nil : videoId,
            pendingSeekAttemptID: self.pendingSeekAttemptIDsByGeneration[navigationGeneration],
            isShort: isShort
        )

        guard let url = Self.watchURL(
            videoId: videoId,
            documentGeneration: navigationGeneration
        ) else {
            self.handlePendingDocumentNavigationFailure(webView: webView)
            return
        }
        // Do not wait for WebContent to acknowledge suppression. A provisional
        // process can defer the callback for seconds during rapid replacement;
        // document-generation gates reject stale bridge events and the immediate
        // navigation tears down outgoing media.
        webView.evaluateJavaScript(
            WebPlaybackDocumentGeneration.mediaSuppressionScript,
            completionHandler: nil
        )
        webView.evaluateJavaScript(
            """
            window.__kasetTargetVolume = \(targetVolume);
            window.__kasetNativePausePending = false;
            window.__kasetAutoplayPending = true;
            window.__kasetAutoplayAttempts = 0;
            window.__kasetAutoplayRetryScheduled = false;
            """,
            completionHandler: nil
        )
        self.startDocumentNavigation(
            on: webView,
            request: URLRequest(url: url),
            generation: navigationGeneration,
            pendingSeek: navigationPendingSeek,
            url: url
        )
    }

    /// Stops playback and blanks the page (called when video playback is closed).
    func tearDown() {
        let blankURL = self.beginBlankDocumentNavigation()
        guard let webView else { return }
        self.logger.info("Tearing down YouTube watch WebView")
        self.loadGeneration += 1
        self.currentVideoId = nil
        webView.evaluateJavaScript(
            "window.__kasetStopYTExtraction?.(); document.querySelector('video')?.pause()"
        ) { _, _ in }
        if let blankURL {
            webView.load(URLRequest(url: blankURL))
        }
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "youtubePlayer"
        )
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        self.webKitManager?.unregisterExtensionHostWebView(role: .youtubeWatch)
        self.webView = nil
        self.coordinator?.cancelPlaybackBridgeTasks()
        self.coordinator = nil
        self.scriptMessageHandler = nil
        self.currentContainer = nil
        self.usesCookieFreeDataStore = nil
    }
}
