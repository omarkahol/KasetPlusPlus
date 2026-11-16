import AVFoundation
import Foundation

// MARK: - NativeVideoPlayer

/// High-performance native video playback engine using `AVPlayer`.
/// Provides hardware-accelerated video decoding (VideoToolbox/Metal), instant playback,
/// 60fps seek responsiveness, and gapless queue prebuffering.
@MainActor
final class NativeVideoPlayer: NSObject {
    static let shared = NativeVideoPlayer()

    private(set) var player: AVPlayer?
    private var timeObserverToken: Any?
    private var playerItemEndObserver: (any NSObjectProtocol)?
    private var durationObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var likelyToKeepUpObserver: NSKeyValueObservation?

    /// Preloaded next item to provide instant transitions between videos or shorts.
    private(set) var preloadedItem: AVPlayerItem?
    private(set) var preloadedVideoId: String?

    private(set) var currentURL: URL?
    private(set) var currentVideoId: String?
    private(set) var isPlaying: Bool = false {
        didSet {
            self.onStateChange?(self.isPlaying)
        }
    }
    private(set) var isLoading: Bool = false {
        didSet {
            self.onLoadingChange?(self.isLoading)
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

    private var storedVolume: Float = 1.0
    var volume: Float {
        get { self.player?.volume ?? self.storedVolume }
        set {
            let clamped = max(0.0, min(1.0, newValue))
            self.storedVolume = clamped
            self.player?.volume = clamped
        }
    }

    var playbackSpeed: Float = 1.0 {
        didSet {
            let clamped = max(0.25, min(2.0, self.playbackSpeed))
            if self.isPlaying {
                self.player?.rate = clamped
            }
        }
    }

    // Callbacks for service integration
    var onProgressUpdate: (@MainActor (TimeInterval) -> Void)?
    var onDurationResolved: (@MainActor (TimeInterval) -> Void)?
    var onPlaybackEnded: (@MainActor () -> Void)?
    var onStateChange: (@MainActor (Bool) -> Void)?
    var onLoadingChange: (@MainActor (Bool) -> Void)?
    var onNearEnd: (@MainActor (TimeInterval) -> Void)?

    private var hasFiredNearEnd = false

    private override init() {
        super.init()
    }

    // MARK: - Playback Controls

    /// Starts playback of a video URL (local file URL or direct remote stream URL).
    func play(url: URL, videoId: String? = nil, startAt: TimeInterval? = nil) {
        self.stop()
        self.currentURL = url
        self.currentVideoId = videoId
        self.hasFiredNearEnd = false
        self.isLoading = true

        let playerItem: AVPlayerItem
        if let preloaded = self.preloadedItem, self.preloadedVideoId == videoId {
            playerItem = preloaded
            self.preloadedItem = nil
            self.preloadedVideoId = nil
        } else {
            playerItem = AVPlayerItem(url: url)
        }

        // Configure player item for low latency and hardware decoding
        playerItem.preferredForwardBufferDuration = 15.0

        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false
        player.volume = self.storedVolume
        self.player = player

        self.setupItemObservers(for: playerItem, in: player)

        if let startAt, startAt > 0 {
            let targetTime = CMTime(seconds: startAt, preferredTimescale: 600)
            player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.player?.playImmediately(atRate: self.playbackSpeed)
                    self.isPlaying = true
                }
            }
        } else {
            player.playImmediately(atRate: self.playbackSpeed)
            self.isPlaying = true
        }
    }

    /// Preloads the next video item into memory to enable instant, gapless transitions.
    func preloadNext(url: URL, videoId: String) {
        guard self.preloadedVideoId != videoId else { return }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 5.0
        self.preloadedItem = item
        self.preloadedVideoId = videoId
    }

    /// Pauses playback.
    func pause() {
        self.player?.pause()
        self.isPlaying = false
    }

    /// Resumes playback.
    func resume() {
        guard let player = self.player else { return }
        player.playImmediately(atRate: self.playbackSpeed)
        self.isPlaying = true
    }

    /// Toggles play/pause state.
    func togglePlayPause() {
        if self.isPlaying {
            self.pause()
        } else {
            self.resume()
        }
    }

    /// Seeks to a specific timestamp in seconds with smooth, frame-accurate targeting.
    func seek(to seconds: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        guard let player = self.player else {
            completion?()
            return
        }
        let clamped = max(0, min(self.duration > 0 ? self.duration : seconds, seconds))
        let targetTime = CMTime(seconds: clamped, preferredTimescale: 600)

        // Reset near-end flag when seeking backwards
        if clamped < self.duration - 15.0 {
            self.hasFiredNearEnd = false
        }

        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in
                completion?()
            }
        }
    }

    /// Updates volume safely (0.0 to 1.0).
    func setVolume(_ volume: Float) {
        self.volume = volume
    }

    /// Stops playback and tears down observers.
    func stop() {
        self.removeObservers()
        self.player?.pause()
        self.player = nil
        self.currentURL = nil
        self.currentVideoId = nil
        self.isPlaying = false
        self.isLoading = false
        self.hasFiredNearEnd = false
    }

    // MARK: - Observers Setup

    private func setupItemObservers(for item: AVPlayerItem, in player: AVPlayer) {
        // 1. Periodic time observer (4 Hz = 250ms for smooth progress & marquee)
        let interval = CMTime(value: 1, timescale: 4)
        self.timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite, seconds >= 0 else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onProgressUpdate?(seconds)

                // Trigger near-end callback when within 15 seconds of the end for next-item preloading
                let dur = self.duration
                if dur > 20.0, seconds >= dur - 15.0, !self.hasFiredNearEnd {
                    self.hasFiredNearEnd = true
                    self.onNearEnd?(seconds)
                }
            }
        }

        // 2. Playback ended notification
        self.playerItemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.onPlaybackEnded?()
            }
        }

        // 3. Duration KVO
        self.durationObserver = item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            let dur = item.duration.seconds
            guard dur.isFinite, dur > 0 else { return }
            Task { @MainActor [weak self] in
                self?.onDurationResolved?(dur)
            }
        }

        // 4. Status KVO
        self.statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if item.status == .readyToPlay {
                    self.isLoading = false
                    let dur = item.duration.seconds
                    if dur.isFinite, dur > 0 {
                        self.onDurationResolved?(dur)
                    }
                } else if item.status == .failed {
                    self.isLoading = false
                    self.isPlaying = false
                }
            }
        }

        // 5. Buffer / Keep up KVO
        self.likelyToKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.isLoading = !item.isPlaybackLikelyToKeepUp
            }
        }
    }

    private func removeObservers() {
        if let token = self.timeObserverToken {
            self.player?.removeTimeObserver(token)
            self.timeObserverToken = nil
        }
        if let endObserver = self.playerItemEndObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.playerItemEndObserver = nil
        }
        self.durationObserver?.invalidate()
        self.durationObserver = nil
        self.statusObserver?.invalidate()
        self.statusObserver = nil
        self.likelyToKeepUpObserver?.invalidate()
        self.likelyToKeepUpObserver = nil
    }
}
