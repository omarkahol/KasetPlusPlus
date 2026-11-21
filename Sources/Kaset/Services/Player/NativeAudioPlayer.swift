import AVFoundation
import Foundation

// MARK: - NativeAudioPlayer

/// High-performance native audio player supporting local audio files, direct audio streams,
/// and gapless queue pre-buffering using AVPlayer.
@MainActor
final class NativeAudioPlayer: BaseAVPlayerController {
    static let shared = NativeAudioPlayer()

    private let samplePlayer = HLSAudioSamplePlayer()
    private var isUsingSamplePlayer = false

    private(set) var isPlaying: Bool = false {
        didSet {
            self.onStateChange?(self.isPlaying)
        }
    }

    var duration: TimeInterval {
        if self.isUsingSamplePlayer {
            return self.samplePlayer.duration
        }
        return self.avDuration
    }

    var currentTime: TimeInterval {
        if self.isUsingSamplePlayer {
            return self.samplePlayer.currentTime
        }
        return self.avCurrentTime
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

    override private init() {
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

        let playerItem = self.consumePreloadedItem(forVideoId: videoId) ?? AVPlayerItem(url: url)

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

        self.scheduleStartupTimeout(for: playerItem, in: player, url: url, timeoutSeconds: 6) { [weak self] in
            guard let self else { return }
            let failedVideoId = self.currentVideoId
            self.stop()
            self.onPlaybackFailed?(failedVideoId, URLError(.timedOut))
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
                await HLSManifestCache.shared.prewarm(multivariantURL: url)
            }
            return
        }
        guard self.preloadedVideoId != videoId else { return }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1.5
        let scheme = url.scheme?.lowercased()
        if scheme == "https" || scheme == "http" {
            item.preferredPeakBitRate = 450_000
        }
        self.setPreload(item: item, videoId: videoId)
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
                self.cancelStartupTimeout()
                if duration.isFinite, duration > 0 {
                    self.onDurationResolved?(duration)
                }
                if self.shouldBePlaying, let player = self.player, player.rate == 0 {
                    player.play()
                }
            }
        }

        self.installTimeControlStatusObserver(
            on: player,
            onPlaying: { [weak self] in
                self?.isPlaying = true
            },
            onPausedWhileStopped: { [weak self] in
                self?.isPlaying = false
            },
            onPausedWhileShouldBePlaying: { observedPlayer in
                if observedPlayer.currentItem?.status == .readyToPlay {
                    observedPlayer.play()
                }
            }
        )

        // Observe periodic time updates (every 200ms)
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        self.installPeriodicTimeObserver(on: player, interval: interval) { [weak self] seconds in
            guard let self else { return }
            self.onProgressUpdate?(seconds)

            // Check for 80% mark to trigger queue preloading
            let dur = self.duration
            if dur > 10, seconds / dur >= 0.8, !self.hasFiredNearEnd {
                self.hasFiredNearEnd = true
                self.onNearEnd?(seconds)
            }
        }

        // Observe track completion
        self.installPlaybackEndObserver(for: playerItem) { [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.onPlaybackEnded?()
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
        self.cancelStartupTimeout()
        self.removeAVObservers()

        self.player?.pause()
        self.player = nil
        self.currentURL = nil
        self.currentVideoId = nil
        self.isPlaying = false
        self.hasFiredNearEnd = false
    }
}
