import AVFoundation
import Foundation

// MARK: - NativeAudioPlayer

/// Native audio player for local offline music files using AVPlayer.
@MainActor
final class NativeAudioPlayer: NSObject {
    static let shared = NativeAudioPlayer()

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var playerItemEndObserver: (any NSObjectProtocol)?
    private var durationObserver: NSKeyValueObservation?

    private(set) var currentURL: URL?
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

    private override init() {
        super.init()
    }

    // MARK: - Controls

    /// Starts playback of a local audio file URL or DownloadItem.
    func play(fileURL: URL) {
        self.stop()
        self.currentURL = fileURL

        let playerItem = AVPlayerItem(url: fileURL)
        let player = AVPlayer(playerItem: playerItem)
        self.player = player

        // Observe duration when ready
        self.durationObserver = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            let duration = item.duration.seconds
            guard duration.isFinite, duration > 0 else { return }
            Task { @MainActor [weak self] in
                self?.onDurationResolved?(duration)
            }
        }

        // Observe periodic time updates (every 250ms)
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        self.timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            Task { @MainActor [weak self] in
                self?.onProgressUpdate?(seconds)
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

        player.play()
        self.isPlaying = true
    }

    /// Convenience for playing a DownloadItem.
    func play(item: DownloadManager.DownloadItem) {
        if let fileURL = DownloadManager.shared.fileURL(for: item.videoId) {
            self.play(fileURL: fileURL)
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
        self.isPlaying = false
    }
}
