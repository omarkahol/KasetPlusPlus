import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import os

// MARK: - HLSSegment

struct HLSSegment: Sendable, Equatable {
    let index: Int
    let url: URL
    let startTime: TimeInterval
    let duration: TimeInterval
}

// MARK: - HLSResolvedPlaylist

struct HLSResolvedPlaylist: Sendable {
    let audioPlaylistURL: URL
    let segments: [HLSSegment]
    let totalDuration: TimeInterval
}

// MARK: - HLSPlaylistParser

enum HLSPlaylistParser {
    /// Extracts the best audio-only media playlist URL from an HLS master manifest.
    /// Prefers `itag/234` (128kbps AAC-LC) when available, falling back to the last `TYPE=AUDIO` entry.
    static func parseMasterAudioPlaylistURL(from masterText: String) -> URL? {
        let lines = masterText.components(separatedBy: .newlines)
        let audioLines = lines.filter { line in
            line.hasPrefix("#EXT-X-MEDIA:") && line.contains("TYPE=AUDIO")
        }
        guard !audioLines.isEmpty else { return nil }

        let preferredLine = audioLines.first(where: { $0.contains("/itag/234/") || $0.contains("itag=234") })
            ?? audioLines.last

        guard let line = preferredLine,
              let uriRange = line.range(of: "URI=\"")
        else { return nil }

        let afterQuote = line[uriRange.upperBound...]
        guard let endQuote = afterQuote.firstIndex(of: "\"") else { return nil }
        let uriString = String(afterQuote[..<endQuote])
        return URL(string: uriString)
    }

    /// Parses an HLS media playlist into timed segments.
    /// Returns `nil` if the playlist uses fMP4 (`#EXT-X-MAP`) or encryption (`#EXT-X-KEY`),
    /// allowing callers to fall back to `AVPlayer`.
    static func parseMediaPlaylistSegments(from playlistText: String) -> [HLSSegment]? {
        let lines = playlistText.components(separatedBy: .newlines)
        var segments: [HLSSegment] = []
        var pendingDuration: TimeInterval?
        var cumulativeStart: TimeInterval = 0

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-MAP:") || line.hasPrefix("#EXT-X-KEY:") {
                return nil
            }

            if line.hasPrefix("#EXTINF:") {
                let valuePart = line.dropFirst("#EXTINF:".count)
                let numberString = valuePart.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
                if let duration = TimeInterval(numberString.trimmingCharacters(in: .whitespaces)),
                   duration.isFinite, duration > 0
                {
                    pendingDuration = duration
                }
                continue
            }

            if line.hasPrefix("#") {
                continue
            }

            if let url = URL(string: line),
               let scheme = url.scheme?.lowercased(),
               scheme == "https" || scheme == "http"
            {
                let duration = pendingDuration ?? 0
                segments.append(HLSSegment(
                    index: segments.count,
                    url: url,
                    startTime: cumulativeStart,
                    duration: duration
                ))
                cumulativeStart += duration
                pendingDuration = nil
            }
        }

        return segments.isEmpty ? nil : segments
    }
}

// MARK: - HLSManifestCache

actor HLSManifestCache {
    static let shared = HLSManifestCache()

    private struct CachedEntry {
        let playlist: HLSResolvedPlaylist
        let cachedAt: Date
    }

    private let session: URLSession
    private var cache: [URL: CachedEntry] = [:]
    private var inFlight: [URL: Task<HLSResolvedPlaylist?, Never>] = [:]
    private let cacheTTL: TimeInterval = 2.5 * 3600

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = APISessionConfiguration.make()
            config.httpShouldSetCookies = false
            self.session = URLSession(configuration: config)
        }
    }

    var sharedSession: URLSession {
        self.session
    }

    func prewarmConnection() async {
        guard let url = URL(string: "https://manifest.googlevideo.com/generate_204") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 3.0
        _ = try? await self.session.data(for: request)
    }

    func prewarm(masterURL: URL) {
        if let existing = self.cache[masterURL], Date().timeIntervalSince(existing.cachedAt) < self.cacheTTL {
            return
        }
        guard self.inFlight[masterURL] == nil else { return }
        Task {
            _ = await self.resolvePlaylist(from: masterURL)
        }
    }

    func resolvePlaylist(from manifestURL: URL) async -> HLSResolvedPlaylist? {
        if let cached = self.cache[masterURLKey(manifestURL)],
           Date().timeIntervalSince(cached.cachedAt) < self.cacheTTL
        {
            return cached.playlist
        }
        if let task = self.inFlight[manifestURL] {
            return await task.value
        }

        let task = Task<HLSResolvedPlaylist?, Never> { [session = self.session] in
            guard let masterText = await Self.fetchText(from: manifestURL, session: session) else {
                return nil
            }

            let audioPlaylistURL: URL
            let mediaText: String
            if let extractedAudioURL = HLSPlaylistParser.parseMasterAudioPlaylistURL(from: masterText) {
                audioPlaylistURL = extractedAudioURL
                guard let fetchedMedia = await Self.fetchText(from: extractedAudioURL, session: session) else {
                    return nil
                }
                mediaText = fetchedMedia
            } else if masterText.contains("#EXTINF:") {
                audioPlaylistURL = manifestURL
                mediaText = masterText
            } else {
                return nil
            }

            guard let segments = HLSPlaylistParser.parseMediaPlaylistSegments(from: mediaText) else {
                return nil
            }
            let totalDuration = segments.reduce(0) { $0 + $1.duration }
            return HLSResolvedPlaylist(
                audioPlaylistURL: audioPlaylistURL,
                segments: segments,
                totalDuration: totalDuration
            )
        }

        self.inFlight[manifestURL] = task
        let resolved = await task.value
        self.inFlight.removeValue(forKey: manifestURL)
        if let resolved {
            self.cache[self.masterURLKey(manifestURL)] = CachedEntry(playlist: resolved, cachedAt: Date())
        }
        return resolved
    }

    func invalidate(masterURL: URL) {
        self.cache.removeValue(forKey: masterURL)
    }

    private func masterURLKey(_ url: URL) -> URL {
        url
    }

    private static func fetchText(from url: URL, session: URLSession) async -> String? {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 5.0
        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - ADTSAudioStreamParser

/// Streams raw ADTS AAC bytes (including ID3v2 headers emitted by Apple HLS packed audio)
/// through AudioToolbox's `AudioFileStream` and emits sample-accurate `CMSampleBuffer`s.
private final class ADTSAudioStreamParser {
    private var streamID: AudioFileStreamID?
    private var asbd: AudioStreamBasicDescription?
    private var magicCookie: Data?
    private var formatDescription: CMAudioFormatDescription?
    private var sampleOffset: Int64
    private let onSampleBuffer: (CMSampleBuffer, Int, Double) -> Void

    private(set) var parsedPacketsCount = 0

    init(
        initialSampleOffset: Int64,
        onSampleBuffer: @escaping (CMSampleBuffer, Int, Double) -> Void
    ) {
        self.sampleOffset = initialSampleOffset
        self.onSampleBuffer = onSampleBuffer

        let contextPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioFileStreamOpen(
            contextPtr,
            { context, streamID, propertyID, _ in
                let parser = Unmanaged<ADTSAudioStreamParser>.fromOpaque(context).takeUnretainedValue()
                parser.handlePropertyChange(streamID: streamID, propertyID: propertyID)
            },
            { context, numberBytes, numberPackets, inputData, packetDescriptions in
                let parser = Unmanaged<ADTSAudioStreamParser>.fromOpaque(context).takeUnretainedValue()
                parser.handlePackets(
                    numberBytes: numberBytes,
                    numberPackets: numberPackets,
                    inputData: inputData,
                    packetDescriptions: packetDescriptions
                )
            },
            kAudioFileAAC_ADTSType,
            &self.streamID
        )
    }

    deinit {
        if let streamID = self.streamID {
            AudioFileStreamClose(streamID)
        }
    }

    var currentSampleRate: Double {
        self.asbd?.mSampleRate ?? 44_100
    }

    var currentSampleOffset: Int64 {
        self.sampleOffset
    }

    @discardableResult
    func parse(_ data: Data) -> OSStatus {
        guard let streamID = self.streamID, !data.isEmpty else { return noErr }
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return noErr }
            return AudioFileStreamParseBytes(streamID, UInt32(data.count), baseAddress, [])
        }
    }

    private func handlePropertyChange(streamID: AudioFileStreamID, propertyID: AudioFileStreamPropertyID) {
        if propertyID == kAudioFileStreamProperty_DataFormat {
            var description = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if AudioFileStreamGetProperty(streamID, propertyID, &size, &description) == noErr {
                self.asbd = description
                self.formatDescription = nil
            }
        } else if propertyID == kAudioFileStreamProperty_MagicCookieData {
            var size: UInt32 = 0
            var writable: DarwinBoolean = false
            if AudioFileStreamGetPropertyInfo(streamID, propertyID, &size, &writable) == noErr, size > 0 {
                var buffer = [UInt8](repeating: 0, count: Int(size))
                if AudioFileStreamGetProperty(streamID, propertyID, &size, &buffer) == noErr {
                    self.magicCookie = Data(buffer)
                    self.formatDescription = nil
                }
            }
        }
    }

    private func handlePackets(
        numberBytes: UInt32,
        numberPackets: UInt32,
        inputData: UnsafeRawPointer,
        packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        guard numberBytes > 0, numberPackets > 0, let packetDescriptions, var asbd = self.asbd else {
            return
        }

        if self.formatDescription == nil {
            var createdFormat: CMAudioFormatDescription?
            let status: OSStatus = if let cookie = self.magicCookie, !cookie.isEmpty {
                cookie.withUnsafeBytes { rawCookie in
                    CMAudioFormatDescriptionCreate(
                        allocator: kCFAllocatorDefault,
                        asbd: &asbd,
                        layoutSize: 0,
                        layout: nil,
                        magicCookieSize: cookie.count,
                        magicCookie: rawCookie.baseAddress,
                        extensions: nil,
                        formatDescriptionOut: &createdFormat
                    )
                }
            } else {
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: 0,
                    layout: nil,
                    magicCookieSize: 0,
                    magicCookie: nil,
                    extensions: nil,
                    formatDescriptionOut: &createdFormat
                )
            }
            guard status == noErr else { return }
            self.formatDescription = createdFormat
        }

        guard let formatDescription = self.formatDescription else { return }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: Int(numberBytes),
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: Int(numberBytes),
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == noErr, let blockBuffer else { return }

        let copyStatus = CMBlockBufferReplaceDataBytes(
            with: inputData,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: Int(numberBytes)
        )
        guard copyStatus == noErr else { return }

        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44_100
        let framesPerPacket = asbd.mFramesPerPacket > 0 ? Int64(asbd.mFramesPerPacket) : 1024
        let pts = CMTime(value: self.sampleOffset, timescale: Int32(sampleRate))

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(numberPackets),
            presentationTimeStamp: pts,
            packetDescriptions: packetDescriptions,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return }

        self.parsedPacketsCount += Int(numberPackets)
        self.sampleOffset += Int64(numberPackets) * framesPerPacket
        let endSeconds = Double(self.sampleOffset) / sampleRate
        self.onSampleBuffer(sampleBuffer, Int(numberPackets), endSeconds)
    }
}

// MARK: - HLSAudioSamplePlayer

/// Low-latency HLS audio streamer backed by `AudioFileStream` (`AudioToolbox`) and
/// `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`.
/// Starts audio after ~150ms of AAC packets instead of waiting for `AVPlayer`'s full HLS buffer.
@MainActor
final class HLSAudioSamplePlayer {
    private static let initialBufferFloorSeconds: TimeInterval = 0.14
    private static let maxAheadBufferSeconds: TimeInterval = 3.0
    private static let streamChunkSizeBytes = 2048

    private let feedQueue = DispatchQueue(label: "com.kaset.hls-audio-sample-feed")
    private let stateLock = OSAllocatedUnfairLock(initialState: UInt64(0))

    private var renderer: AVSampleBufferAudioRenderer?
    private var synchronizer: AVSampleBufferRenderSynchronizer?
    private var streamingTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    private var activePlaylist: HLSResolvedPlaylist?
    private var generation: UInt64 = 0
    private var shouldBePlaying = false
    private var hasStartedPlayback = false
    private var hasFiredNearEnd = false
    private var hasFinishedEnqueuing = false
    private var enqueuedEndSeconds: TimeInterval = 0

    private(set) var currentURL: URL?
    private(set) var currentVideoId: String?
    private(set) var duration: TimeInterval = 0

    var volume: Float = 1.0 {
        didSet {
            let clamped = max(0.0, min(1.0, self.volume))
            self.renderer?.volume = clamped
        }
    }

    var currentTime: TimeInterval {
        guard let synchronizer = self.synchronizer else { return 0 }
        let seconds = synchronizer.currentTime().seconds
        return seconds.isFinite && seconds >= 0 ? seconds : 0
    }

    var onProgressUpdate: (@MainActor (TimeInterval) -> Void)?
    var onDurationResolved: (@MainActor (TimeInterval) -> Void)?
    var onPlaybackStarted: (@MainActor () -> Void)?
    var onPlaybackEnded: (@MainActor () -> Void)?
    var onNearEnd: (@MainActor (TimeInterval) -> Void)?
    var onFallbackRequired: (@MainActor (URL, String?) -> Void)?
    var onPlaybackFailed: (@MainActor (String?, (any Error)?) -> Void)?

    static func isHLSURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        guard scheme == "https" || scheme == "http" else { return false }
        let lower = url.absoluteString.lowercased()
        return url.pathExtension.lowercased() == "m3u8"
            || lower.contains("hls_variant")
            || lower.contains("hls_playlist")
    }

    func play(url: URL, videoId: String?) {
        self.stop()
        self.currentURL = url
        self.currentVideoId = videoId
        self.shouldBePlaying = true
        self.hasStartedPlayback = false
        self.hasFiredNearEnd = false
        self.hasFinishedEnqueuing = false
        self.enqueuedEndSeconds = 0
        self.duration = 0

        let renderer = AVSampleBufferAudioRenderer()
        renderer.volume = max(0.0, min(1.0, self.volume))
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)
        synchronizer.setRate(0.0, time: .zero)

        self.renderer = renderer
        self.synchronizer = synchronizer

        let playGen = self.advanceGeneration()
        self.startProgressLoop(generation: playGen)

        self.streamingTask = Task { @MainActor [weak self] in
            guard let self, self.generation == playGen else { return }
            guard let playlist = await HLSManifestCache.shared.resolvePlaylist(from: url) else {
                guard self.generation == playGen else { return }
                self.stop()
                self.onFallbackRequired?(url, videoId)
                return
            }
            guard self.generation == playGen else { return }

            self.activePlaylist = playlist
            self.duration = playlist.totalDuration
            if playlist.totalDuration > 0 {
                self.onDurationResolved?(playlist.totalDuration)
            }

            await self.streamSegments(
                fromSegmentIndex: 0,
                startTimeSeconds: 0,
                playlist: playlist,
                renderer: renderer,
                synchronizer: synchronizer,
                generation: playGen
            )
        }
    }

    func pause() {
        self.shouldBePlaying = false
        guard let synchronizer = self.synchronizer else { return }
        synchronizer.setRate(0.0, time: synchronizer.currentTime())
    }

    func resume() {
        self.shouldBePlaying = true
        guard let synchronizer = self.synchronizer else { return }
        if self.hasStartedPlayback {
            synchronizer.setRate(1.0, time: synchronizer.currentTime())
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let playlist = self.activePlaylist,
              let renderer = self.renderer,
              let synchronizer = self.synchronizer,
              !playlist.segments.isEmpty
        else { return }

        let clamped = max(0, min(playlist.totalDuration > 0 ? playlist.totalDuration - 0.1 : seconds, seconds))
        let targetSegment = playlist.segments.last(where: { $0.startTime <= clamped }) ?? playlist.segments[0]

        if playlist.totalDuration > 10, clamped / playlist.totalDuration < 0.8 {
            self.hasFiredNearEnd = false
        }

        let seekGen = self.advanceGeneration()
        self.streamingTask?.cancel()
        self.hasFinishedEnqueuing = false
        self.hasStartedPlayback = false
        self.enqueuedEndSeconds = targetSegment.startTime

        let targetCMTime = CMTime(seconds: targetSegment.startTime, preferredTimescale: 44_100)
        self.feedQueue.sync {
            renderer.flush()
        }
        synchronizer.setRate(0.0, time: targetCMTime)

        self.startProgressLoop(generation: seekGen)
        self.streamingTask = Task { @MainActor [weak self] in
            guard let self, self.generation == seekGen else { return }
            await self.streamSegments(
                fromSegmentIndex: targetSegment.index,
                startTimeSeconds: targetSegment.startTime,
                playlist: playlist,
                renderer: renderer,
                synchronizer: synchronizer,
                generation: seekGen
            )
        }
    }

    func stop() {
        self.shouldBePlaying = false
        _ = self.advanceGeneration()
        self.streamingTask?.cancel()
        self.streamingTask = nil
        self.progressTask?.cancel()
        self.progressTask = nil
        self.activePlaylist = nil

        if let synchronizer = self.synchronizer {
            synchronizer.setRate(0.0, time: synchronizer.currentTime())
        }
        if let renderer = self.renderer {
            self.feedQueue.sync {
                renderer.stopRequestingMediaData()
                renderer.flush()
            }
        }
        self.synchronizer = nil
        self.renderer = nil
        self.currentURL = nil
        self.currentVideoId = nil
        self.duration = 0
        self.hasStartedPlayback = false
        self.hasFiredNearEnd = false
        self.hasFinishedEnqueuing = false
        self.enqueuedEndSeconds = 0
    }

    // MARK: - Private Streaming Engine

    private func advanceGeneration() -> UInt64 {
        self.generation &+= 1
        let next = self.generation
        self.stateLock.withLock { $0 = next }
        return next
    }

    private func isGenerationCurrent(_ targetGeneration: UInt64) -> Bool {
        self.stateLock.withLock { $0 == targetGeneration }
    }

    private func startProgressLoop(generation: UInt64) {
        self.progressTask?.cancel()
        self.progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.generation == generation, !Task.isCancelled else { return }

                let current = self.currentTime
                if self.hasStartedPlayback {
                    self.onProgressUpdate?(current)

                    if self.duration > 10, current / self.duration >= 0.8, !self.hasFiredNearEnd {
                        self.hasFiredNearEnd = true
                        self.onNearEnd?(current)
                    }
                }

                if self.hasFinishedEnqueuing,
                   self.hasStartedPlayback,
                   self.enqueuedEndSeconds > 0,
                   current >= self.enqueuedEndSeconds - 0.12
                {
                    self.onPlaybackEnded?()
                    return
                }
            }
        }
    }

    private func streamSegments(
        fromSegmentIndex startIndex: Int,
        startTimeSeconds: TimeInterval,
        playlist: HLSResolvedPlaylist,
        renderer: AVSampleBufferAudioRenderer,
        synchronizer: AVSampleBufferRenderSynchronizer,
        generation: UInt64
    ) async {
        let session = await HLSManifestCache.shared.sharedSession
        var nextSegmentTask: Task<Data?, Never>?
        var currentSampleOffset = Int64((startTimeSeconds * 44_100).rounded())

        for index in startIndex ..< playlist.segments.count {
            guard !Task.isCancelled, self.generation == generation else {
                nextSegmentTask?.cancel()
                return
            }

            // Throttle ahead-of-playhead buffering to keep memory bounded (~3s ahead).
            while !Task.isCancelled,
                  self.generation == generation,
                  self.hasStartedPlayback,
                  (self.enqueuedEndSeconds - self.currentTime) > Self.maxAheadBufferSeconds || !renderer.isReadyForMoreMediaData
            {
                try? await Task.sleep(for: .milliseconds(30))
            }
            guard !Task.isCancelled, self.generation == generation else {
                nextSegmentTask?.cancel()
                return
            }

            let segment = playlist.segments[index]

            // Prefetch segment[index + 1] in parallel while segment[index] streams/decodes.
            let prefetchedDataTask = nextSegmentTask
            if index + 1 < playlist.segments.count {
                let nextURL = playlist.segments[index + 1].url
                nextSegmentTask = Task<Data?, Never> {
                    await Self.downloadSegment(url: nextURL, session: session)
                }
            } else {
                nextSegmentTask = nil
            }

            let feedResult: (success: Bool, nextOffset: Int64)
            if let prefetchedDataTask {
                guard let segmentData = await prefetchedDataTask.value else {
                    if !self.hasStartedPlayback, let url = self.currentURL {
                        let videoId = self.currentVideoId
                        self.stop()
                        self.onFallbackRequired?(url, videoId)
                    } else {
                        let videoId = self.currentVideoId
                        self.stop()
                        self.onPlaybackFailed?(videoId, URLError(.cannotLoadFromNetwork))
                    }
                    return
                }
                feedResult = self.feedFullSegmentData(
                    segmentData,
                    initialSampleOffset: currentSampleOffset,
                    startTimeSeconds: startTimeSeconds,
                    renderer: renderer,
                    synchronizer: synchronizer,
                    generation: generation
                )
            } else {
                feedResult = await self.streamFirstSegmentBytes(
                    url: segment.url,
                    session: session,
                    initialSampleOffset: currentSampleOffset,
                    startTimeSeconds: startTimeSeconds,
                    renderer: renderer,
                    synchronizer: synchronizer,
                    generation: generation
                )
            }

            guard !Task.isCancelled, self.generation == generation else {
                nextSegmentTask?.cancel()
                return
            }

            if !feedResult.success {
                nextSegmentTask?.cancel()
                if !self.hasStartedPlayback, let url = self.currentURL {
                    let videoId = self.currentVideoId
                    self.stop()
                    self.onFallbackRequired?(url, videoId)
                } else {
                    let videoId = self.currentVideoId
                    self.stop()
                    self.onPlaybackFailed?(videoId, URLError(.cannotDecodeContentData))
                }
                return
            }

            currentSampleOffset = feedResult.nextOffset
        }

        guard !Task.isCancelled, self.generation == generation else { return }
        self.feedQueue.sync {
            guard self.isGenerationCurrent(generation) else { return }
            renderer.stopRequestingMediaData()
        }
        self.hasFinishedEnqueuing = true
        if !self.hasStartedPlayback, self.enqueuedEndSeconds > startTimeSeconds {
            self.beginSynchronizedPlaybackIfNeeded(
                startTimeSeconds: startTimeSeconds,
                synchronizer: synchronizer,
                generation: generation
            )
        }
    }

    private func streamFirstSegmentBytes(
        url: URL,
        session: URLSession,
        initialSampleOffset: Int64,
        startTimeSeconds: TimeInterval,
        renderer: AVSampleBufferAudioRenderer,
        synchronizer: AVSampleBufferRenderSynchronizer,
        generation: UInt64
    ) async -> (success: Bool, nextOffset: Int64) {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 8.0

        let initialStartTime = startTimeSeconds
        let startCMTime = CMTime(seconds: initialStartTime, preferredTimescale: 44_100)
        var dataTask: URLSessionDataTask?

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let streamDelegate = SegmentStreamDelegate(
                    feedQueue: self.feedQueue,
                    isGenerationCurrent: { [weak self] in
                        self?.isGenerationCurrent(generation) ?? false
                    },
                    initialSampleOffset: initialSampleOffset,
                    startTimeSeconds: initialStartTime,
                    initialBufferFloorSeconds: Self.initialBufferFloorSeconds,
                    renderer: renderer,
                    onInitialBufferReached: { [weak self] endSeconds in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == generation else { return }
                            self.enqueuedEndSeconds = max(self.enqueuedEndSeconds, endSeconds)
                            if !self.hasStartedPlayback {
                                self.hasStartedPlayback = true
                                if self.shouldBePlaying {
                                    synchronizer.setRate(1.0, time: startCMTime)
                                }
                                self.onPlaybackStarted?()
                            }
                        }
                    },
                    onProgressEnd: { [weak self] endSeconds in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == generation else { return }
                            self.enqueuedEndSeconds = max(self.enqueuedEndSeconds, endSeconds)
                        }
                    },
                    onComplete: { success, nextOffset in
                        continuation.resume(returning: (success, nextOffset))
                    }
                )
                let task = session.dataTask(with: request)
                task.delegate = streamDelegate
                dataTask = task
                task.resume()
            }
        } onCancel: {
            dataTask?.cancel()
        }
    }

    private func feedFullSegmentData(
        _ data: Data,
        initialSampleOffset: Int64,
        startTimeSeconds: TimeInterval,
        renderer: AVSampleBufferAudioRenderer,
        synchronizer: AVSampleBufferRenderSynchronizer,
        generation: UInt64
    ) -> (success: Bool, nextOffset: Int64) {
        var latestEndSeconds = self.enqueuedEndSeconds
        let parser = ADTSAudioStreamParser(initialSampleOffset: initialSampleOffset) { [weak self] sampleBuffer, _, endSeconds in
            guard let self else { return }
            self.feedQueue.sync {
                guard self.isGenerationCurrent(generation) else { return }
                renderer.enqueue(sampleBuffer)
            }
            latestEndSeconds = max(latestEndSeconds, endSeconds)
        }

        let status = parser.parse(data)
        self.enqueuedEndSeconds = max(self.enqueuedEndSeconds, latestEndSeconds)

        if !self.hasStartedPlayback,
           (self.enqueuedEndSeconds - startTimeSeconds) >= Self.initialBufferFloorSeconds
        {
            self.beginSynchronizedPlaybackIfNeeded(
                startTimeSeconds: startTimeSeconds,
                synchronizer: synchronizer,
                generation: generation
            )
        }

        return (status == noErr && parser.parsedPacketsCount > 0, parser.currentSampleOffset)
    }

    private func beginSynchronizedPlaybackIfNeeded(
        startTimeSeconds: TimeInterval,
        synchronizer: AVSampleBufferRenderSynchronizer,
        generation: UInt64
    ) {
        guard self.generation == generation, !self.hasStartedPlayback else { return }
        self.hasStartedPlayback = true
        if self.shouldBePlaying {
            let startCMTime = CMTime(seconds: startTimeSeconds, preferredTimescale: 44_100)
            synchronizer.setRate(1.0, time: startCMTime)
        }
        self.onPlaybackStarted?()
    }

    private static func downloadSegment(url: URL, session: URLSession) async -> Data? {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 8.0
        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            return nil
        }
        return data
    }
}

// MARK: - SegmentStreamDelegate

/// Streams incoming TCP `Data` chunks directly into `ADTSAudioStreamParser` on `feedQueue`
/// without per-byte async iterator overhead.
private final class SegmentStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let feedQueue: DispatchQueue
    private let isGenerationCurrent: () -> Bool
    private let startTimeSeconds: TimeInterval
    private let initialBufferFloorSeconds: TimeInterval
    private let renderer: AVSampleBufferAudioRenderer
    private let onInitialBufferReached: (TimeInterval) -> Void
    private let onProgressEnd: (TimeInterval) -> Void
    private let onComplete: (Bool, Int64) -> Void

    private var parser: ADTSAudioStreamParser?
    private var hasNotifiedInitialBuffer = false
    private var hasCompleted = false
    private var hasValidResponse = false
    private var lastStatus: OSStatus = noErr
    private var initialSampleOffset: Int64

    init(
        feedQueue: DispatchQueue,
        isGenerationCurrent: @escaping () -> Bool,
        initialSampleOffset: Int64,
        startTimeSeconds: TimeInterval,
        initialBufferFloorSeconds: TimeInterval,
        renderer: AVSampleBufferAudioRenderer,
        onInitialBufferReached: @escaping (TimeInterval) -> Void,
        onProgressEnd: @escaping (TimeInterval) -> Void,
        onComplete: @escaping (Bool, Int64) -> Void
    ) {
        self.feedQueue = feedQueue
        self.isGenerationCurrent = isGenerationCurrent
        self.initialSampleOffset = initialSampleOffset
        self.startTimeSeconds = startTimeSeconds
        self.initialBufferFloorSeconds = initialBufferFloorSeconds
        self.renderer = renderer
        self.onInitialBufferReached = onInitialBufferReached
        self.onProgressEnd = onProgressEnd
        self.onComplete = onComplete
        super.init()
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              (200 ... 299).contains(http.statusCode),
              self.isGenerationCurrent()
        else {
            completionHandler(.cancel)
            return
        }
        self.hasValidResponse = true
        self.feedQueue.async { [weak self] in
            guard let self, self.isGenerationCurrent() else { return }
            self.parser = ADTSAudioStreamParser(initialSampleOffset: self.initialSampleOffset) { [weak self] sampleBuffer, _, endSeconds in
                guard let self, self.isGenerationCurrent() else { return }
                self.renderer.enqueue(sampleBuffer)
                if !self.hasNotifiedInitialBuffer,
                   (endSeconds - self.startTimeSeconds) >= self.initialBufferFloorSeconds
                {
                    self.hasNotifiedInitialBuffer = true
                    self.onInitialBufferReached(endSeconds)
                } else {
                    self.onProgressEnd(endSeconds)
                }
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.hasValidResponse, self.isGenerationCurrent() else {
            dataTask.cancel()
            return
        }
        self.feedQueue.async { [weak self] in
            guard let self, self.isGenerationCurrent(), let parser = self.parser else { return }
            let status = parser.parse(data)
            if status != noErr {
                self.lastStatus = status
                dataTask.cancel()
            }
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        self.feedQueue.async { [weak self] in
            guard let self, !self.hasCompleted else { return }
            self.hasCompleted = true
            let packetCount = self.parser?.parsedPacketsCount ?? 0
            let nextOffset = self.parser?.currentSampleOffset ?? self.initialSampleOffset
            let success = self.hasValidResponse
                && error == nil
                && self.lastStatus == noErr
                && packetCount > 0
                && self.isGenerationCurrent()
            self.onComplete(success, nextOffset)
        }
    }
}
