import AVFoundation
import Foundation

// MARK: - NativeAudioPlayer

/// High-performance native audio player supporting local audio files, direct audio streams,
/// and gapless queue pre-buffering using AVPlayer.
@MainActor
final class NativeAudioPlayer: NSObject {
    static let shared = NativeAudioPlayer()

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var playerItemEndObserver: (any NSObjectProtocol)?
    private var durationObserver: NSKeyValueObservation?

    /// Preloaded next item to provide gapless transitions.
    private(set) var preloadedItem: AVPlayerItem?
    private(set) var preloadedVideoId: String?

    private(set) var currentURL: URL?
    private(set) var currentVideoId: String?
    private(set) var isPlaying: Bool = false {
        didSet {
            self.onStateChange?(self.isPlaying)
        }
    }

    var duration: TimeInterval {
        guard let item = self.player?.currentItem else { return 0 }
        let duration = item.duration.seconds
        return duration.isFinite && duration > 0 ? duration : 0
    }

    var currentTime: TimeInterval {
        guard let item = self.player?.currentItem else { return 0 }
        let time = item.currentTime().seconds
        return time.isFinite && time >= 0 ? time : 0
    }

    var volume: Float {
        get { self.player?.volume ?? 1.0 }
        set { self.player?.volume = max(0.0, min(1.0, newValue)) }
    }

    // Callbacks for PlayerService integration
    var onProgressUpdate: (@MainActor (TimeInterval) -> Void)?
    var onDurationResolved: (@MainActor (TimeInterval) -> Void)?
    var onPlaybackEnded: (@MainActor () -> Void)?
    var onStateChange: (@MainActor (Bool) -> Void)?
    var onNearEnd: (@MainActor (TimeInterval) -> Void)?
    var onPlaybackFailed: (@MainActor (String?, (any Error)?) -> Void)?

    private var hasFiredNearEnd = false

    private override init() {
        super.init()
    }

    // MARK: - Controls

    /// Starts playback of an audio URL (local file URL or direct remote stream URL).
    func play(url: URL, videoId: String? = nil) {
        self.stop()
        self.currentURL = url
        self.currentVideoId = videoId
        self.hasFiredNearEnd = false

        let playerItem: AVPlayerItem
        if let preloaded = self.preloadedItem, self.preloadedVideoId == videoId {
            playerItem = preloaded
            self.preloadedItem = nil
            self.preloadedVideoId = nil
        } else {
            playerItem = AVPlayerItem(url: url)
        }

        // Configure player item for low latency: buffer the first 3 seconds so playback starts immediately
        playerItem.preferredForwardBufferDuration = 3.0

        let player = AVPlayer(playerItem: playerItem)
        // Snappy start: start immediately without waiting to minimize stalling
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player

        self.setupItemObservers(for: playerItem, in: player)

        player.playImmediately(atRate: 1.0)
        self.isPlaying = true
    }

    /// Convenience for local offline files.
    func play(fileURL: URL) {
        self.play(url: fileURL, videoId: nil)
    }

    /// Convenience for playing a DownloadItem.
    func play(item: DownloadManager.DownloadItem) {
        if let fileURL = DownloadManager.shared.fileURL(for: item.videoId) {
            self.play(url: fileURL, videoId: item.videoId)
        }
    }

    /// Preloads the next track into memory for gapless track transitions.
    func preloadNext(url: URL, videoId: String) {
        guard self.preloadedVideoId != videoId else { return }
        self.preloadedVideoId = videoId
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 3.0
        self.preloadedItem = item
    }

    /// Clears any preloaded item.
    func clearPreload() {
        self.preloadedItem = nil
        self.preloadedVideoId = nil
    }

    private func setupItemObservers(for playerItem: AVPlayerItem, in player: AVPlayer) {
        // Observe status (duration readiness and playback failure)
        self.durationObserver = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            if status == .failed {
                let error = item.error
                Task { @MainActor [weak self] in
                    guard let self, self.player?.currentItem === item else { return }
                    let failedVideoId = self.currentVideoId
                    self.stop()
                    self.onPlaybackFailed?(failedVideoId, error)
                }
                return
            }
            guard status == .readyToPlay else { return }
            let duration = item.duration.seconds
            guard duration.isFinite, duration > 0 else { return }
            Task { @MainActor [weak self] in
                self?.onDurationResolved?(duration)
            }
        }

        // Observe periodic time updates (every 200ms)
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        self.timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onProgressUpdate?(seconds)

                // Check for 80% mark to trigger queue preloading
                let dur = self.duration
                if dur > 10, seconds / dur >= 0.8, !self.hasFiredNearEnd {
                    self.hasFiredNearEnd = true
                    self.onNearEnd?(seconds)
                }
            }
        }

        // Observe track completion
        self.playerItemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.onPlaybackEnded?()
            }
        }
    }

    /// Resumes playback.
    func resume() {
        guard let player = self.player else { return }
        player.play()
        self.isPlaying = true
    }

    /// Pauses playback.
    func pause() {
        guard let player = self.player else { return }
        player.pause()
        self.isPlaying = false
    }

    /// Toggles play/pause.
    func togglePlayPause() {
        if self.isPlaying {
            self.pause()
        } else {
            self.resume()
        }
    }

    /// Seeks to the specified position in seconds.
    func seek(to seconds: TimeInterval) {
        guard let player = self.player else { return }
        let targetTime = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Sets playback volume (0.0 to 1.0).
    func setVolume(_ volume: Double) {
        self.volume = Float(volume)
    }

    /// Stops playback and tears down observers.
    func stop() {
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

        self.player?.pause()
        self.player = nil
        self.currentURL = nil
        self.currentVideoId = nil
        self.isPlaying = false
        self.hasFiredNearEnd = false
    }
}
