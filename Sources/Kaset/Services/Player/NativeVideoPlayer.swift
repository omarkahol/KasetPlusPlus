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

    private var preferredQualityLevel: String = "auto"
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
            let built = Self.makePlayerItem(for: url)
            playerItem = built.item
            self.activeResourceLoader = built.loader
        }

        // Buffer ~4s ahead (enough to pipeline 5-6s HLS segments smoothly without forcing
        // AVPlayer to buffer 15s before starting), and respect the user's preferred quality cap.
        playerItem.preferredForwardBufferDuration = 4.0
        playerItem.preferredPeakBitRate = Self.preferredPeakBitRate(for: self.preferredQualityLevel)

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
        let built = Self.makePlayerItem(for: url)
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

    /// Applies a quality cap to the current and subsequent native `AVPlayerItem`s.
    func setQualityLevel(_ level: String) {
        self.preferredQualityLevel = level
        self.player?.currentItem?.preferredPeakBitRate = Self.preferredPeakBitRate(for: level)
    }

    /// Selects a legible (caption/subtitle) media option on the current `AVPlayerItem`, or `nil` to turn captions off.
    func selectCaptionTrack(languageCode: String?) {
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

            let audioTracks: [YouTubeAudioTrack] = audibleGroup?.options.map { option in
                YouTubeAudioTrack(
                    id: Self.mediaOptionCode(option),
                    displayName: option.displayName
                )
            } ?? []
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
        self.statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player, player.currentItem === item else { return }
                if item.status == .readyToPlay {
                    self.startupTimeoutTask?.cancel()
                    self.startupTimeoutTask = nil
                    self.isLoading = false
                    let dur = item.duration.seconds
                    if dur.isFinite, dur > 0 {
                        self.onDurationResolved?(dur)
                    }
                    self.resolveMediaSelectionOptions(for: item, videoId: self.currentVideoId)
                    if let startAt = self.pendingStartAt, startAt > 0 {
                        self.pendingStartAt = nil
                        let targetTime = CMTime(seconds: startAt, preferredTimescale: 600)
                        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
                            Task { @MainActor [weak self, weak player] in
                                guard let self, let player, self.shouldBePlaying, self.player === player else { return }
                                player.rate = self.playbackSpeed
                            }
                        }
                    } else if self.shouldBePlaying, player.rate == 0 {
                        player.rate = self.playbackSpeed
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
                    self.isLoading = false
                    if self.shouldBePlaying, let player = self.player, player.rate == 0, self.pendingStartAt == nil {
                        player.rate = self.playbackSpeed
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
                       player.currentItem?.status != .readyToPlay,
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

    private static func makePlayerItem(for url: URL) -> (item: AVPlayerItem, loader: HLSMasterManifestLoader?) {
        guard HLSAudioSamplePlayer.isHLSURL(url),
              let customURL = URL(string: "kaset-hls://master/\(UUID().uuidString).m3u8")
        else {
            return (AVPlayerItem(url: url), nil)
        }
        let asset = AVURLAsset(url: customURL)
        let loader = HLSMasterManifestLoader(sourceURL: url)
        asset.resourceLoader.setDelegate(loader, queue: HLSMasterManifestLoader.delegateQueue)
        return (AVPlayerItem(asset: asset), loader)
    }
}

// MARK: - HLSMasterManifestLoader

/// Intercepts HLS master manifest loading for `NativeVideoPlayer` so unsupported `vp09` variants
/// are filtered out and `avc1`/`hvc1` variants are ordered highest-bitrate-first (avoiding
/// `AVPlayer` starting locked onto the lowest `240p` variant).
final class HLSMasterManifestLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let delegateQueue = DispatchQueue(label: "com.kaset.hls-video-master-loader")

    private let sourceURL: URL

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
        super.init()
    }

    func resourceLoader(
        _: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let sourceURL = self.sourceURL
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

            let responseData: Data = if let text = String(data: rawData, encoding: .utf8),
                                        let rewritten = Self.rewriteMasterPlaylist(text),
                                        let rewrittenData = rewritten.data(using: .utf8)
            {
                rewrittenData
            } else {
                rawData
            }

            loadingRequest.contentInformationRequest?.contentType = "com.apple.mpegurl"
            loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
            loadingRequest.contentInformationRequest?.contentLength = Int64(responseData.count)
            loadingRequest.dataRequest?.respond(with: responseData)
            loadingRequest.finishLoading()
        }
        return true
    }

    static func rewriteMasterPlaylist(_ masterText: String) -> String? {
        let lines = masterText.components(separatedBy: .newlines)
        var headerLines: [String] = []
        var variants: [(bandwidth: Int, infLine: String, urlLine: String)] = []

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-STREAM-INF:"), index + 1 < lines.count {
                let urlLine = lines[index + 1]
                if line.contains("avc1") || line.contains("hvc1") {
                    let bandwidth = Self.extractBandwidth(from: line)
                    variants.append((bandwidth: bandwidth, infLine: line, urlLine: urlLine))
                }
                index += 2
            } else {
                if !line.isEmpty {
                    headerLines.append(line)
                }
                index += 1
            }
        }

        guard !variants.isEmpty else { return nil }
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
        let ordered = hd720Variants + higherVariants + lowerVariants

        var output = headerLines.joined(separator: "\n") + "\n"
        for variant in ordered {
            output += variant.infLine + "\n" + variant.urlLine + "\n"
        }
        return output
    }

    private static func extractBandwidth(from streamInfLine: String) -> Int {
        guard let range = streamInfLine.range(of: "BANDWIDTH=") else { return 0 }
        let digits = streamInfLine[range.upperBound...].prefix(while: { $0.isNumber })
        return Int(digits) ?? 0
    }
}
