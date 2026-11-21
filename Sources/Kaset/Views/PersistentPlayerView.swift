import AppKit
import os
import SwiftUI

// MARK: - PersistentPlayerView

/// A SwiftUI anchor for the singleton WebView.
/// The WebView is created once, kept attached while audio playback is pending,
/// and normally rendered as a hidden 1×1 view.
struct PersistentPlayerView: NSViewRepresentable {
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(PlayerService.self) private var playerService
    @Environment(AuthService.self) private var authService

    let videoId: String?
    let isExpanded: Bool // Retained for compatibility; audio playback keeps this hidden.

    private let logger = DiagnosticsLogger.player

    func makeNSView(context _: Context) -> NSView {
        self.logger.info("PersistentPlayerView.makeNSView for videoId: \(self.videoId ?? "nil")")

        let container = NSView(frame: .zero)
        container.wantsLayer = true

        let shouldAutoload = self.videoId != nil
            && self.playerService.shouldAutoloadPendingVideo
            && SingletonPlayerWebView.shared.currentVideoId != self.videoId

        let webView = SingletonPlayerWebView.shared.getWebView(
            webKitManager: self.webKitManager,
            playerService: self.playerService,
            usesCookieFreeDataStore: self.authService.shouldUseCookieFreePlaybackDataStore,
            suppressesHomePreload: shouldAutoload
        )

        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        // Restored sessions keep the hidden WebView inert until the user explicitly resumes.
        if shouldAutoload, let videoId = self.videoId {
            self.logger.info("Initial hidden load for videoId: \(videoId)")
            SingletonPlayerWebView.shared.loadVideo(videoId: videoId)
        }

        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        let shouldAutoload = self.videoId != nil
            && self.playerService.shouldAutoloadPendingVideo
            && SingletonPlayerWebView.shared.currentVideoId != self.videoId

        let webView = SingletonPlayerWebView.shared.getWebView(
            webKitManager: self.webKitManager,
            playerService: self.playerService,
            usesCookieFreeDataStore: self.authService.shouldUseCookieFreePlaybackDataStore,
            suppressesHomePreload: shouldAutoload
        )

        if webView.superview !== container {
            self.logger.info("Re-parenting WebView to current container")
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }

        webView.frame = container.bounds

        if shouldAutoload, let videoId = self.videoId {
            SingletonPlayerWebView.shared.loadVideo(videoId: videoId)
        }
    }
}
