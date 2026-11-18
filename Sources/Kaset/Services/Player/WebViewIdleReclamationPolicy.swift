import Foundation

// MARK: - WebViewIdleReclamationPolicy

/// Determines when idle playback `WKWebView` instances can be reclaimed to
/// free WebKit `WebContent`/`GPU` memory while native `AVPlayer` owns playback.
@MainActor
enum WebViewIdleReclamationPolicy {
    static func shouldReclaimYouTubeWatchWebView(
        isPlayingNativeVideo: Bool,
        isPlaybackLoading: Bool,
        isIdentityReloadInFlight: Bool
    ) -> Bool {
        isPlayingNativeVideo && !isPlaybackLoading && !isIdentityReloadInFlight
    }

    static func shouldReclaimMusicWebView(
        isPlayingOfflineOrDirect: Bool,
        activeSource: AppSource,
        isMusicPlaying: Bool,
        isAwaitingWebConfirmation: Bool,
        isAuthSyncInFlight: Bool = false
    ) -> Bool {
        guard !isAwaitingWebConfirmation, !isAuthSyncInFlight else { return false }
        if isPlayingOfflineOrDirect {
            return true
        }
        return activeSource == .video && !isMusicPlaying
    }
}

// MARK: - WebViewIdleReclamationScheduler

/// Generation-scoped debouncer that reclaims an idle WebView after a grace
/// period and cancels immediately if WebKit playback is requested again.
@MainActor
final class WebViewIdleReclamationScheduler {
    private let graceDuration: Duration
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    init(graceDuration: Duration = .seconds(20)) {
        self.graceDuration = graceDuration
    }

    func schedule(perform action: @escaping @MainActor () -> Void) {
        self.cancel()
        self.generation &+= 1
        let scheduledGeneration = self.generation
        let delay = self.graceDuration
        self.task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.generation == scheduledGeneration
            else { return }
            self.task = nil
            action()
        }
    }

    func cancel() {
        self.generation &+= 1
        self.task?.cancel()
        self.task = nil
    }
}
