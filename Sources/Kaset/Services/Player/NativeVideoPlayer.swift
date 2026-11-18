import AVFoundation
import AVKit
import Foundation

extension Notification.Name {
    static let nativeVideoPlayerChanged = Notification.Name("com.sertacozercan.kaset.nativeVideoPlayerChanged")
}

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
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var startupTimeoutTask: Task<Void, Never>?
    private var activeResourceLoader: HLSMasterManifestLoader?
    private var preloadedResourceLoader: HLSMasterManifestLoader?
    private var pendingStartAt: TimeInterval?
    private var shouldBePlaying = false

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
    var onPlaybackFailed: (@MainActor () -> Void)?
    var onMediaSelectionOptionsResolved: (@MainActor ([YouTubeCaptionTrack], String?, [YouTubeAudioTrack], String?) -> Void)?
    var onAvailableQualityLevelsResolved: (@MainActor ([String]) -> Void)?

    private var preferredQualityLevel: String = "auto"
    private var cachedMasterPlaylist: (url: URL, text: String)?
    private var preferredCaptionLanguageCode: String?
    private var hasExplicitCaptionSelection = false
    private var preferredAudioTrackId: String?
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
        if let preloaded = self.preloadedItem,
           self.preloadedVideoId == videoId,
           preloaded.status != .failed
        {
            playerItem = preloaded
            self.activeResourceLoader = self.preloadedResourceLoader
            self.preloadedItem = nil
            self.preloadedVideoId = nil
            self.preloadedResourceLoader = nil
        } else {
            self.preloadedItem = nil
            self.preloadedVideoId = nil
            self.preloadedResourceLoader = nil
            let built = self.makePlayerItem(for: url, preferredQualityLevel: self.preferredQualityLevel)
            playerItem = built.item
            self.activeResourceLoader = built.loader
        }

        // Buffer ~4s ahead for fast startup at <=720p/auto, and 10s ahead for >=1080p so
        // high-bitrate segments (1080p60/1440p/4K) don't stall at segment boundaries.
        // For HLS streams, HLSMasterManifestLoader filters variants directly so preferredPeakBitRate
        // stays 0 and never blocks high-bitrate variants.
        playerItem.preferredForwardBufferDuration = Self.preferredForwardBufferDuration(for: self.preferredQualityLevel)
        playerItem.preferredPeakBitRate = HLSAudioSamplePlayer.isHLSURL(url)
            ? 0
            : Self.preferredPeakBitRate(for: self.preferredQualityLevel)

        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.volume = self.storedVolume
        self.player = player
        self.pendingStartAt = (startAt ?? 0) > 0 ? startAt : nil
        self.shouldBePlaying = true
        NotificationCenter.default.post(name: .nativeVideoPlayerChanged, object: player)

        self.setupItemObservers(for: playerItem, in: player)

        let scheme = url.scheme?.lowercased()
        if scheme == "https" || scheme == "http" {
            self.startupTimeoutTask = Task { @MainActor [weak self, weak playerItem, weak player] in
                do {
                    try await Task.sleep(for: .seconds(8))
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
                self.stop()
                self.onPlaybackFailed?()
            }
        }

        player.rate = self.playbackSpeed
        self.isPlaying = true
    }

    /// Preloads the next video item into memory to enable instant, gapless transitions.
    func preloadNext(url: URL, videoId: String) {
        guard self.preloadedVideoId != videoId else { return }
        let built = self.makePlayerItem(for: url, preferredQualityLevel: "auto", cacheMasterPlaylist: false)
        built.item.preferredForwardBufferDuration = 0
        self.preloadedItem = built.item
        self.preloadedResourceLoader = built.loader
        self.preloadedVideoId = videoId
    }

    /// Pauses playback.
    func pause() {
        self.shouldBePlaying = false
        self.player?.pause()
        self.isPlaying = false
        self.isLoading = false
    }

    /// Resumes playback.
    func resume() {
        guard let player = self.player else { return }
        self.shouldBePlaying = true
        player.rate = self.playbackSpeed
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

    /// Maps a YouTube quality identifier (e.g., `"hd1080"`, `"auto"`) to an `AVPlayerItem` peak bitrate cap.
    static func preferredPeakBitRate(for level: String) -> Double {
        switch level {
        case "highres": 35_000_000
        case "hd2880": 25_000_000
        case "hd2160": 20_000_000
        case "hd1440": 10_000_000
        case "hd1080": 5_000_000
        case "hd720": 2_500_000
        case "large": 1_200_000
        case "medium": 700_000
        case "small": 350_000
        case "tiny": 150_000
        default: 0
        }
    }

    private static func preferredForwardBufferDuration(for level: String) -> TimeInterval {
        switch level {
        case "highres", "hd2880", "hd2160", "hd1440", "hd1080":
            10.0
        default:
            4.0
        }
    }

    /// Applies a quality level to the current and subsequent native `AVPlayerItem`s.
    /// For HLS streams, reloads the item at the current playback position with the filtered
    /// master manifest so `AVPlayer` switches to the requested resolution immediately.
    func setQualityLevel(_ level: String) {
        let previousLevel = self.preferredQualityLevel
        self.preferredQualityLevel = level
        guard let player = self.player,
              let currentURL = self.currentURL,
              previousLevel != level
        else { return }

        if HLSAudioSamplePlayer.isHLSURL(currentURL) {
            self.reloadCurrentHLSItemForQuality(level, on: player, url: currentURL)
        } else {
            player.currentItem?.preferredPeakBitRate = Self.preferredPeakBitRate(for: level)
        }
    }

    private func reloadCurrentHLSItemForQuality(_ level: String, on player: AVPlayer, url: URL) {
        self.startupTimeoutTask?.cancel()
        self.startupTimeoutTask = nil

        let resumeTime = self.pendingStartAt ?? self.currentTime
        let wasPlaying = self.shouldBePlaying

        self.removeObservers()
        if resumeTime > 0 {
            player.pause()
        }

        let built = self.makePlayerItem(for: url, preferredQualityLevel: level)
        built.item.preferredForwardBufferDuration = Self.preferredForwardBufferDuration(for: level)
        built.item.preferredPeakBitRate = 0

        self.activeResourceLoader = built.loader
        self.pendingStartAt = resumeTime > 0 ? resumeTime : nil
        self.shouldBePlaying = wasPlaying
        self.isLoading = true

        player.replaceCurrentItem(with: built.item)
        self.setupItemObservers(for: built.item, in: player)
        self.scheduleStartupTimeout(for: built.item, in: player, url: url, timeoutSeconds: 10)
    }

    private func scheduleStartupTimeout(
        for playerItem: AVPlayerItem,
        in player: AVPlayer,
        url: URL,
        timeoutSeconds: Int
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
            self.stop()
            self.onPlaybackFailed?()
        }
    }

    /// Selects a legible (caption/subtitle) media option on the current `AVPlayerItem`, or `nil` to turn captions off.
    func selectCaptionTrack(languageCode: String?) {
        self.hasExplicitCaptionSelection = true
        self.preferredCaptionLanguageCode = languageCode
        guard let item = self.player?.currentItem else { return }
        let videoId = self.currentVideoId
        Task { @MainActor [weak self, weak item] in
            guard let self, let item, self.player?.currentItem === item, self.currentVideoId == videoId else { return }
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            guard self.player?.currentItem === item, self.currentVideoId == videoId else { return }
            guard let languageCode else {
                item.select(nil, in: group)
                return
            }
            let normalized = languageCode.lowercased()
            let matching = group.options.first { option in
                Self.mediaOptionCode(option).lowercased() == normalized
            }
            item.select(matching, in: group)
        }
    }

    /// Selects an audible (audio track) media option on the current `AVPlayerItem`.
    func selectAudioTrack(id: String) {
        self.preferredAudioTrackId = id
        guard let item = self.player?.currentItem else { return }
        let videoId = self.currentVideoId
        Task { @MainActor [weak self, weak item] in
            guard let self, let item, self.player?.currentItem === item, self.currentVideoId == videoId else { return }
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
            guard self.player?.currentItem === item, self.currentVideoId == videoId else { return }
            if let matching = group.options.first(where: { Self.mediaOptionCode($0) == id }) {
                item.select(matching, in: group)
            }
        }
    }

    /// Shows the native macOS AirPlay route picker for the active `AVPlayer`.
    func showAirPlayPicker(at screenPoint: CGPoint? = nil) {
        guard let player = self.player else { return }
        let picker = AVRoutePickerView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        picker.player = player
        picker.isRoutePickerButtonBordered = false

        let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
        guard let contentView = targetWindow?.contentView else { return }
        let anchorPoint: NSPoint = if let screenPoint, let window = targetWindow {
            contentView.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        } else {
            NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        }
        picker.frame = NSRect(x: anchorPoint.x - 12, y: anchorPoint.y - 12, width: 24, height: 24)
        contentView.addSubview(picker)
        if let button = picker.subviews.compactMap({ $0 as? NSButton }).first {
            button.performClick(nil)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            picker.removeFromSuperview()
        }
    }

    private static func mediaOptionCode(_ option: AVMediaSelectionOption) -> String {
        option.extendedLanguageTag ?? option.locale?.identifier ?? option.displayName
    }

    private func resolveMediaSelectionOptions(for item: AVPlayerItem, videoId: String?) {
        Task { @MainActor [weak self, weak item] in
            guard let self, let item, self.player?.currentItem === item, self.currentVideoId == videoId else { return }
            let legibleGroup = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            let audibleGroup = try? await item.asset.loadMediaSelectionGroup(for: .audible)
            guard self.player?.currentItem === item, self.currentVideoId == videoId else { return }

            // Re-apply any user-selected caption or audio track (e.g. after a quality switch reload).
            if self.hasExplicitCaptionSelection, let legibleGroup {
                if let code = self.preferredCaptionLanguageCode?.lowercased() {
                    let match = legibleGroup.options.first { Self.mediaOptionCode($0).lowercased() == code }
                    item.select(match, in: legibleGroup)
                } else {
                    item.select(nil, in: legibleGroup)
                }
            }
            if let audioId = self.preferredAudioTrackId, let audibleGroup,
               let match = audibleGroup.options.first(where: { Self.mediaOptionCode($0) == audioId })
            {
                item.select(match, in: audibleGroup)
            }

            let currentSelection = item.currentMediaSelection
            let captionTracks: [YouTubeCaptionTrack] = legibleGroup?.options.map { option in
                YouTubeCaptionTrack(
                    languageCode: Self.mediaOptionCode(option),
                    displayName: option.displayName
                )
            } ?? []
            let activeCaptionCode = legibleGroup.flatMap { group in
                currentSelection.selectedMediaOption(in: group).map { Self.mediaOptionCode($0) }
            }

            let audibleOptions = audibleGroup?.options ?? []
            let hasExplicitOriginalAudio = audibleOptions.contains {
                $0.hasMediaCharacteristic(.isOriginalContent)
                    || $0.displayName.localizedCaseInsensitiveContains("original")
            }
            let audioTracks: [YouTubeAudioTrack] = audibleOptions.map { option in
                let isOriginal = if hasExplicitOriginalAudio {
                    option.hasMediaCharacteristic(.isOriginalContent)
                        || option.displayName.localizedCaseInsensitiveContains("original")
                } else {
                    audibleGroup?.defaultOption == option
                }
                return YouTubeAudioTrack(
                    id: Self.mediaOptionCode(option),
                    displayName: option.displayName,
                    isOriginal: isOriginal
                )
            }
            let activeAudioId = audibleGroup.flatMap { group in
                currentSelection.selectedMediaOption(in: group).map { Self.mediaOptionCode($0) }
            }

            self.onMediaSelectionOptionsResolved?(captionTracks, activeCaptionCode, audioTracks, activeAudioId)
        }
    }

    /// Stops playback and tears down observers.
    func stop() {
        self.shouldBePlaying = false
        self.startupTimeoutTask?.cancel()
        self.startupTimeoutTask = nil
        self.pendingStartAt = nil
        self.removeObservers()
        self.player?.pause()
        self.player = nil
        self.activeResourceLoader = nil
        NotificationCenter.default.post(name: .nativeVideoPlayerChanged, object: nil)
        self.currentURL = nil
        self.currentVideoId = nil
        self.cachedMasterPlaylist = nil
        self.preferredCaptionLanguageCode = nil
        self.hasExplicitCaptionSelection = false
        self.preferredAudioTrackId = nil
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
                guard let self, self.pendingStartAt == nil else { return }
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
        self.statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, let player = self.player, player.currentItem === item else { return }
                if item.status == .readyToPlay {
                    self.startupTimeoutTask?.cancel()
                    self.startupTimeoutTask = nil
                    let dur = item.duration.seconds
                    if dur.isFinite, dur > 0 {
                        self.onDurationResolved?(dur)
                    }
                    self.resolveMediaSelectionOptions(for: item, videoId: self.currentVideoId)
                    if let startAt = self.pendingStartAt, startAt > 0 {
                        let targetTime = CMTime(seconds: startAt, preferredTimescale: 600)
                        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player, weak item] _ in
                            Task { @MainActor [weak self, weak player, weak item] in
                                guard let self, let player, let item,
                                      self.player === player,
                                      player.currentItem === item
                                else { return }
                                self.pendingStartAt = nil
                                if item.isPlaybackLikelyToKeepUp || !self.shouldBePlaying {
                                    self.isLoading = false
                                }
                                if self.shouldBePlaying {
                                    player.rate = self.playbackSpeed
                                }
                            }
                        }
                    } else {
                        self.pendingStartAt = nil
                        self.isLoading = false
                        if self.shouldBePlaying, player.rate == 0 {
                            player.rate = self.playbackSpeed
                        }
                    }
                } else if item.status == .failed {
                    self.startupTimeoutTask?.cancel()
                    self.startupTimeoutTask = nil
                    self.pendingStartAt = nil
                    self.shouldBePlaying = false
                    self.isLoading = false
                    self.isPlaying = false
                    self.onPlaybackFailed?()
                }
            }
        }

        // 5. Buffer / Keep up KVO
        self.likelyToKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player?.currentItem === item else { return }
                if item.isPlaybackLikelyToKeepUp {
                    if self.pendingStartAt == nil {
                        self.isLoading = false
                        if self.shouldBePlaying, let player = self.player, player.rate == 0 {
                            player.rate = self.playbackSpeed
                        }
                    }
                } else if self.shouldBePlaying, self.player?.timeControlStatus != .playing {
                    self.isLoading = true
                }
            }
        }

        // 6. Time control status KVO
        self.timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player === player else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.startupTimeoutTask?.cancel()
                    self.startupTimeoutTask = nil
                    self.isLoading = false
                    self.isPlaying = true
                case .waitingToPlayAtSpecifiedRate:
                    if self.shouldBePlaying,
                       player.currentItem?.isPlaybackLikelyToKeepUp != true
                    {
                        self.isLoading = true
                    }
                case .paused:
                    if !self.shouldBePlaying {
                        self.isPlaying = false
                        self.isLoading = false
                    } else if player.currentItem?.status == .readyToPlay, self.pendingStartAt == nil {
                        player.rate = self.playbackSpeed
                    }
                @unknown default:
                    break
                }
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
        self.timeControlStatusObserver?.invalidate()
        self.timeControlStatusObserver = nil
    }

    private func makePlayerItem(
        for url: URL,
        preferredQualityLevel: String,
        cacheMasterPlaylist: Bool = true
    ) -> (item: AVPlayerItem, loader: HLSMasterManifestLoader?) {
        guard HLSAudioSamplePlayer.isHLSURL(url),
              let customURL = URL(string: "kaset-hls://master/\(UUID().uuidString).m3u8")
        else {
            return (AVPlayerItem(url: url), nil)
        }
        let asset = AVURLAsset(url: customURL)
        let cachedText = (cacheMasterPlaylist && self.cachedMasterPlaylist?.url == url)
            ? self.cachedMasterPlaylist?.text
            : nil
        let onLoaded: (@MainActor @Sendable (String, [String]) -> Void)? = if cacheMasterPlaylist {
            { [weak self] masterText, availableLevels in
                guard let self else { return }
                if self.currentURL == url {
                    self.cachedMasterPlaylist = (url, masterText)
                    self.onAvailableQualityLevelsResolved?(availableLevels)
                }
            }
        } else {
            nil
        }
        let loader = HLSMasterManifestLoader(
            sourceURL: url,
            preferredQualityLevel: preferredQualityLevel,
            initialMasterPlaylistText: cachedText,
            onMasterPlaylistLoaded: onLoaded
        )
        asset.resourceLoader.setDelegate(loader, queue: HLSMasterManifestLoader.delegateQueue)
        return (AVPlayerItem(asset: asset), loader)
    }
}

// MARK: - HLSMasterManifestLoader

/// Intercepts HLS master manifest loading for `NativeVideoPlayer` so unsupported `vp09` variants
/// are filtered out, `avc1`/`hvc1` variants are ordered for ABR or filtered to a user-pinned
/// quality level, and available quality tiers are reported back to the player UI.
final class HLSMasterManifestLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let delegateQueue = DispatchQueue(label: "com.kaset.hls-video-master-loader")

    private static let orderedQualityLevels = [
        "highres", "hd2880", "hd2160", "hd1440", "hd1080", "hd720", "large", "medium", "small", "tiny",
    ]

    private let sourceURL: URL
    private let preferredQualityLevel: String
    private let initialMasterPlaylistText: String?
    private let onMasterPlaylistLoaded: (@MainActor @Sendable (String, [String]) -> Void)?

    init(
        sourceURL: URL,
        preferredQualityLevel: String = "auto",
        initialMasterPlaylistText: String? = nil,
        onMasterPlaylistLoaded: (@MainActor @Sendable (String, [String]) -> Void)? = nil
    ) {
        self.sourceURL = sourceURL
        self.preferredQualityLevel = preferredQualityLevel
        self.initialMasterPlaylistText = initialMasterPlaylistText
        self.onMasterPlaylistLoaded = onMasterPlaylistLoaded
        super.init()
    }

    func resourceLoader(
        _: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let cachedText = self.initialMasterPlaylistText {
            let rewritten = Self.rewriteMasterPlaylist(cachedText, preferredQualityLevel: self.preferredQualityLevel)
            let responseData = rewritten?.data(using: .utf8) ?? Data(cachedText.utf8)
            Self.finish(loadingRequest: loadingRequest, with: responseData)
            return true
        }

        let sourceURL = self.sourceURL
        let preferredQualityLevel = self.preferredQualityLevel
        let onMasterPlaylistLoaded = self.onMasterPlaylistLoaded
        Task {
            let session = await HLSManifestCache.shared.sharedSession
            var request = URLRequest(url: sourceURL)
            request.httpShouldHandleCookies = false
            request.timeoutInterval = 6.0

            guard let (rawData, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200 ... 299).contains(http.statusCode)
            else {
                loadingRequest.finishLoading(with: URLError(.cannotLoadFromNetwork))
                return
            }

            let responseData: Data
            if let text = String(data: rawData, encoding: .utf8) {
                let availableLevels = Self.availableQualityLevels(in: text)
                if let onMasterPlaylistLoaded {
                    await MainActor.run {
                        onMasterPlaylistLoaded(text, availableLevels)
                    }
                }
                if let rewritten = Self.rewriteMasterPlaylist(text, preferredQualityLevel: preferredQualityLevel),
                   let rewrittenData = rewritten.data(using: .utf8)
                {
                    responseData = rewrittenData
                } else {
                    responseData = rawData
                }
            } else {
                responseData = rawData
            }

            Self.finish(loadingRequest: loadingRequest, with: responseData)
        }
        return true
    }

    private static func finish(loadingRequest: AVAssetResourceLoadingRequest, with responseData: Data) {
        loadingRequest.contentInformationRequest?.contentType = "com.apple.mpegurl"
        loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
        loadingRequest.contentInformationRequest?.contentLength = Int64(responseData.count)
        loadingRequest.dataRequest?.respond(with: responseData)
        loadingRequest.finishLoading()
    }

    /// Returns the distinct YouTube quality levels present in `avc1`/`hvc1` variants, ordered highest-to-lowest.
    static func availableQualityLevels(in masterText: String) -> [String] {
        let parsed = Self.parseMasterPlaylist(masterText)
        let present = Set(parsed.variants.compactMap(\.qualityLevel))
        return Self.orderedQualityLevels.filter { present.contains($0) }
    }

    static func rewriteMasterPlaylist(_ masterText: String, preferredQualityLevel: String = "auto") -> String? {
        let parsed = Self.parseMasterPlaylist(masterText)
        let variants = parsed.variants
        guard !variants.isEmpty else { return nil }

        let selected: [MasterVariant]
        if preferredQualityLevel.isEmpty || preferredQualityLevel == "auto" {
            // Start with 720p (~1.0-2.5 Mbps) first for fast ~1s startup, followed by 1080p+ so ABR
            // steps up immediately on segment 1, then lower fallback rungs.
            let hd720Variants = variants
                .filter { $0.bandwidth >= 900_000 && $0.bandwidth <= 2_500_000 }
                .sorted { $0.bandwidth > $1.bandwidth }
            let higherVariants = variants
                .filter { $0.bandwidth > 2_500_000 }
                .sorted { $0.bandwidth > $1.bandwidth }
            let lowerVariants = variants
                .filter { $0.bandwidth < 900_000 }
                .sorted { $0.bandwidth > $1.bandwidth }
            selected = hd720Variants + higherVariants + lowerVariants
        } else {
            let targetLevel = Self.resolvedTargetQualityLevel(
                requested: preferredQualityLevel,
                availableVariants: variants
            )
            let matching = targetLevel.map { target in
                variants.filter { $0.qualityLevel == target }
            } ?? []
            selected = (matching.isEmpty ? variants : matching).sorted { $0.bandwidth > $1.bandwidth }
        }

        var output = parsed.headerLines.joined(separator: "\n") + "\n"
        for variant in selected {
            output += variant.infLine + "\n" + variant.urlLine + "\n"
        }
        return output
    }

    /// Maps an `#EXT-X-STREAM-INF:` line's `RESOLUTION=WxH` attribute to a YouTube quality identifier.
    static func qualityLevel(forStreamInfLine line: String) -> String? {
        guard let range = line.range(of: "RESOLUTION=") else { return nil }
        let token = line[range.upperBound...].prefix(while: { $0 != "," && !$0.isWhitespace })
        let parts = token.split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]),
              width > 0,
              height > 0
        else { return nil }

        let shortSide = min(width, height)
        let longSide = max(width, height)
        if shortSide >= 4320 || longSide >= 7680 { return "highres" }
        if shortSide >= 2880 || longSide >= 5120 { return "hd2880" }
        if shortSide >= 2160 || longSide >= 3840 { return "hd2160" }
        if shortSide >= 1440 || longSide >= 2560 { return "hd1440" }
        if shortSide >= 1080 || longSide >= 1920 { return "hd1080" }
        if shortSide >= 720 || longSide >= 1280 { return "hd720" }
        if shortSide >= 480 || longSide >= 854 { return "large" }
        if shortSide >= 360 || longSide >= 640 { return "medium" }
        if shortSide >= 240 || longSide >= 426 { return "small" }
        return "tiny"
    }

    private struct MasterVariant {
        let bandwidth: Int
        let qualityLevel: String?
        let infLine: String
        let urlLine: String
    }

    private static func parseMasterPlaylist(_ masterText: String) -> (headerLines: [String], variants: [MasterVariant]) {
        let lines = masterText.components(separatedBy: .newlines)
        var headerLines: [String] = []
        var variants: [MasterVariant] = []

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-STREAM-INF:"), index + 1 < lines.count {
                let urlLine = lines[index + 1]
                if line.contains("avc1") || line.contains("hvc1") {
                    let bandwidth = Self.extractBandwidth(from: line)
                    let quality = Self.qualityLevel(forStreamInfLine: line)
                    variants.append(MasterVariant(bandwidth: bandwidth, qualityLevel: quality, infLine: line, urlLine: urlLine))
                }
                index += 2
            } else {
                if !line.isEmpty {
                    headerLines.append(line)
                }
                index += 1
            }
        }
        return (headerLines, variants)
    }

    private static func resolvedTargetQualityLevel(requested: String, availableVariants: [MasterVariant]) -> String? {
        let availableLevels = Set(availableVariants.compactMap(\.qualityLevel))
        guard !availableLevels.isEmpty else { return nil }
        if availableLevels.contains(requested) {
            return requested
        }
        guard let requestedIndex = Self.orderedQualityLevels.firstIndex(of: requested) else {
            return nil
        }
        // Prefer the highest available quality at or below the requested tier, otherwise the lowest available.
        let orderedAvailable = Self.orderedQualityLevels.enumerated().filter { availableLevels.contains($0.element) }
        if let lowerOrEqual = orderedAvailable.first(where: { $0.offset >= requestedIndex }) {
            return lowerOrEqual.element
        }
        return orderedAvailable.last?.element
    }

    private static func extractBandwidth(from streamInfLine: String) -> Int {
        guard let range = streamInfLine.range(of: "BANDWIDTH=") else { return 0 }
        let digits = streamInfLine[range.upperBound...].prefix(while: { $0.isNumber })
        return Int(digits) ?? 0
    }
}
