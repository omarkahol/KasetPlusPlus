import AVFoundation
import Foundation

// MARK: - BaseAVPlayerController

/// Shared `AVPlayer` lifecycle, observer, preloading, and startup-timeout base controller
/// for `NativeAudioPlayer` and `NativeVideoPlayer`.
@MainActor
class BaseAVPlayerController: NSObject {
    var player: AVPlayer?
    var timeObserverToken: Any?
    var playerItemEndObserver: (any NSObjectProtocol)?
    var durationObserver: NSKeyValueObservation?
    var statusObserver: NSKeyValueObservation?
    var likelyToKeepUpObserver: NSKeyValueObservation?
    var timeControlStatusObserver: NSKeyValueObservation?
    var startupTimeoutTask: Task<Void, Never>?
    var shouldBePlaying = false
    var storedVolume: Float = 1.0
    var hasFiredNearEnd = false

    /// Preloaded next item to provide gapless transitions.
    private(set) var preloadedItem: AVPlayerItem?
    private(set) var preloadedVideoId: String?

    var currentURL: URL?
    var currentVideoId: String?

    var avDuration: TimeInterval {
        guard let item = self.player?.currentItem else { return 0 }
        let duration = item.duration.seconds
        return duration.isFinite && duration > 0 ? duration : 0
    }

    var avCurrentTime: TimeInterval {
        guard let item = self.player?.currentItem else { return 0 }
        let time = item.currentTime().seconds
        return time.isFinite && time >= 0 ? time : 0
    }

    func setPreload(item: AVPlayerItem, videoId: String) {
        self.preloadedItem = item
        self.preloadedVideoId = videoId
    }

    func consumePreloadedItem(forVideoId videoId: String?) -> AVPlayerItem? {
        if let preloaded = self.preloadedItem,
           self.preloadedVideoId == videoId,
           preloaded.status != .failed
        {
            self.preloadedItem = nil
            self.preloadedVideoId = nil
            return preloaded
        }
        self.preloadedItem = nil
        self.preloadedVideoId = nil
        return nil
    }

    /// Clears any preloaded item.
    func clearPreload() {
        self.preloadedItem = nil
        self.preloadedVideoId = nil
    }

    func scheduleStartupTimeout(
        for playerItem: AVPlayerItem,
        in player: AVPlayer,
        url: URL,
        timeoutSeconds: Int,
        onTimeout: @escaping @MainActor () -> Void
    ) {
        let scheme = url.scheme?.lowercased()
        guard scheme == "https" || scheme == "http" else { return }
        self.startupTimeoutTask = Task { @MainActor [weak self, weak playerItem, weak player] in
            do {
                try await Task.sleep(for: .seconds(timeoutSeconds))
            } catch {
                return
            }
            guard let self,
                  let playerItem,
                  let player,
                  self.player === player,
                  self.player?.currentItem === playerItem,
                  self.shouldBePlaying,
                  playerItem.status != .readyToPlay,
                  player.timeControlStatus != .playing
            else { return }
            onTimeout()
        }
    }

    func cancelStartupTimeout() {
        self.startupTimeoutTask?.cancel()
        self.startupTimeoutTask = nil
    }

    func installPeriodicTimeObserver(
        on player: AVPlayer,
        interval: CMTime,
        onTick: @escaping @MainActor (TimeInterval) -> Void
    ) {
        self.timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            guard seconds.isFinite, seconds >= 0 else { return }
            Task { @MainActor in
                onTick(seconds)
            }
        }
    }

    func installPlaybackEndObserver(
        for item: AVPlayerItem,
        onEnded: @escaping @MainActor () -> Void
    ) {
        self.playerItemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                onEnded()
            }
        }
    }

    func installTimeControlStatusObserver(
        on player: AVPlayer,
        onPlaying: @escaping @MainActor () -> Void,
        onWaiting: @escaping @MainActor (AVPlayer) -> Void = { _ in },
        onPausedWhileStopped: @escaping @MainActor () -> Void,
        onPausedWhileShouldBePlaying: @escaping @MainActor (AVPlayer) -> Void
    ) {
        self.timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player === observedPlayer else { return }
                switch observedPlayer.timeControlStatus {
                case .playing:
                    self.cancelStartupTimeout()
                    onPlaying()
                case .waitingToPlayAtSpecifiedRate:
                    onWaiting(observedPlayer)
                case .paused:
                    if !self.shouldBePlaying {
                        onPausedWhileStopped()
                    } else {
                        onPausedWhileShouldBePlaying(observedPlayer)
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    func removeAVObservers() {
        if let token = self.timeObserverToken {
            self.player?.removeTimeObserver(token)
            self.timeObserverToken = nil
        }
        if let observer = self.playerItemEndObserver {
            NotificationCenter.default.removeObserver(observer)
            self.playerItemEndObserver = nil
        }
        self.durationObserver?.invalidate()
        self.durationObserver = nil
        self.statusObserver?.invalidate()
        self.statusObserver = nil
        self.likelyToKeepUpObserver?.invalidate()
        self.likelyToKeepUpObserver = nil
        self.timeControlStatusObserver?.invalidate()
        self.timeControlStatusObserver = nil
    }
}
