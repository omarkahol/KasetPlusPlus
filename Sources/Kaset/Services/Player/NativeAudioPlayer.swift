import AVFoundation
import Foundation

// MARK: - NativeAudioPlayer

/// High-performance native audio player supporting local audio files, direct audio streams,
/// and gapless queue pre-buffering using AVPlayer.
@MainActor
final class NativeAudioPlayer: NSObject {
    static let shared = NativeAudioPlayer()

    private var player: AVPlayer?
    private let samplePlayer = HLSAudioSamplePlayer()
    private var isUsingSamplePlayer = false
    private var storedVolume: Float = 1.0
    private var timeObserverToken: Any?
    private var playerItemEndObserver: (any NSObjectProtocol)?
    private var durationObserver: NSKeyValueObservation?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var startupTimeoutTask: Task<Void, Never>?
    private var shouldBePlaying = false

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
        if self.isUsingSamplePlayer {
            return self.samplePlayer.duration
        }
        guard let item = self.player?.currentItem else { return 0 }
        let duration = item.duration.seconds
        return duration.isFinite && duration > 0 ? duration : 0
    }

    var currentTime: TimeInterval {
        if self.isUsingSamplePlayer {
            return self.samplePlayer.currentTime
        }
        guard let item = self.player?.currentItem else { return 0 }
        let time = item.currentTime().seconds
        return time.isFinite && time >= 0 ? time : 0
    }

    var volume: Float {
        get { self.storedVolume }
        set {
            let clamped = max(0.0, min(1.0, newValue))
            self.storedVolume = clamped
            self.player?.volume = clamped
            self.samplePlayer.volume = clamped
        }
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
        self.setupSamplePlayerCallbacks()
    }

    private func setupSamplePlayerCallbacks() {
        self.samplePlayer.onProgressUpdate = { [weak self] seconds in
            guard let self, self.isUsingSamplePlayer else { return }
            self.onProgressUpdate?(seconds)
        }
        self.samplePlayer.onDurationResolved = { [weak self] duration in
            guard let self, self.isUsingSamplePlayer else { return }
            self.onDurationResolved?(duration)
        }
        self.samplePlayer.onPlaybackEnded = { [weak self] in
            guard let self, self.isUsingSamplePlayer else { return }
            self.isPlaying = false
            self.onPlaybackEnded?()
        }
        self.samplePlayer.onNearEnd = { [weak self] seconds in
            guard let self, self.isUsingSamplePlayer else { return }
            self.onNearEnd?(seconds)
        }
        self.samplePlayer.onPlaybackFailed = { [weak self] videoId, error in
            guard let self, self.isUsingSamplePlayer else { return }
            self.stop()
            self.onPlaybackFailed?(videoId, error)
        }
        self.samplePlayer.onFallbackRequired = { [weak self] url, videoId in
            guard let self, self.isUsingSamplePlayer else { return }
            let keepPlaying = self.shouldBePlaying
            self.playWithAVPlayer(url: url, videoId: videoId)
            if !keepPlaying {
                self.pause()
            }
        }
    }

    // MARK: - Controls

    /// Starts playback of an audio URL (local file URL or direct remote stream URL).
    func play(url: URL, videoId: String? = nil) {
        self.stop()
        if HLSAudioSamplePlayer.isHLSURL(url) {
            self.currentURL = url
            self.currentVideoId = videoId
            self.isUsingSamplePlayer = true
            self.shouldBePlaying = true
            self.samplePlayer.volume = self.storedVolume
            self.samplePlayer.play(url: url, videoId: videoId)
            self.isPlaying = true
            return
        }
        self.playWithAVPlayer(url: url, videoId: videoId)
    }

    private func playWithAVPlayer(url: URL, videoId: String?) {
        self.stop()
        self.currentURL = url
        self.currentVideoId = videoId
        self.hasFiredNearEnd = false
        self.isUsingSamplePlayer = false

        let playerItem: AVPlayerItem
        if let preloaded = self.preloadedItem,
           self.preloadedVideoId == videoId,
           preloaded.status != .failed
        {
            playerItem = preloaded
            self.preloadedItem = nil
            self.preloadedVideoId = nil
        } else {
            self.preloadedItem = nil
            self.preloadedVideoId = nil
            playerItem = AVPlayerItem(url: url)
        }

        // Configure player item for low latency: buffer 1.5s so playback starts immediately,
        // and cap remote HLS bitrate so audio-only playback never stalls on high-resolution video segments.
        playerItem.preferredForwardBufferDuration = 1.5
        let scheme = url.scheme?.lowercased()
        let isRemoteURL = scheme == "https" || scheme == "http"
        if isRemoteURL {
            playerItem.preferredPeakBitRate = 450_000
        }

        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = self.storedVolume
        self.player = player
        self.shouldBePlaying = true

        self.setupItemObservers(for: playerItem, in: player)

        if isRemoteURL {
            self.startupTimeoutTask = Task { @MainActor [weak self, weak playerItem, weak player] in
                do {
                    try await Task.sleep(for: .seconds(6))
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
                let failedVideoId = self.currentVideoId
                self.stop()
                self.onPlaybackFailed?(failedVideoId, URLError(.timedOut))
            }
        }

        player.play()
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
        if HLSAudioSamplePlayer.isHLSURL(url) {
            Task {
                await HLSManifestCache.shared.prewarm(masterURL: url)
            }
            return
        }
        guard self.preloadedVideoId != videoId else { return }
        self.preloadedVideoId = videoId
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1.5
        let scheme = url.scheme?.lowercased()
        if scheme == "https" || scheme == "http" {
            item.preferredPeakBitRate = 450_000
        }
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
            Task { @MainActor [weak self] in
                guard let self, self.player?.currentItem === item else { return }
                self.startupTimeoutTask?.cancel()
                self.startupTimeoutTask = nil
                if duration.isFinite, duration > 0 {
                    self.onDurationResolved?(duration)
                }
                if self.shouldBePlaying, let player = self.player, player.rate == 0 {
                    player.play()
                }
            }
        }

        self.timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player === player else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.startupTimeoutTask?.cancel()
                    self.startupTimeoutTask = nil
                    self.isPlaying = true
                case .waitingToPlayAtSpecifiedRate:
                    break
                case .paused:
                    if !self.shouldBePlaying {
                        self.isPlaying = false
                    } else if player.currentItem?.status == .readyToPlay {
                        player.play()
                    }
                @unknown default:
                    break
                }
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
        self.shouldBePlaying = true
        if self.isUsingSamplePlayer {
            self.samplePlayer.resume()
            self.isPlaying = true
            return
        }
        guard let player = self.player else { return }
        player.play()
        self.isPlaying = true
    }

    /// Pauses playback.
    func pause() {
        self.shouldBePlaying = false
        if self.isUsingSamplePlayer {
            self.samplePlayer.pause()
            self.isPlaying = false
            return
        }
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
        if self.isUsingSamplePlayer {
            self.samplePlayer.seek(to: seconds)
            return
        }
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
        self.shouldBePlaying = false
        if self.isUsingSamplePlayer {
            self.samplePlayer.stop()
            self.isUsingSamplePlayer = false
        }
        self.startupTimeoutTask?.cancel()
        self.startupTimeoutTask = nil
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
        self.timeControlStatusObserver?.invalidate()
        self.timeControlStatusObserver = nil

        self.player?.pause()
        self.player = nil
        self.currentURL = nil
        self.currentVideoId = nil
        self.isPlaying = false
        self.hasFiredNearEnd = false
    }
}
