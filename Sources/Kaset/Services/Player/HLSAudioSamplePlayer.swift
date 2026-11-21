import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import os

// MARK: - HLSAudioSamplePlayer

/// Low-latency HLS audio streamer backed by `AudioFileStream` (`AudioToolbox`) and
/// `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`.
/// Starts audio after ~150ms of AAC packets instead of waiting for `AVPlayer`'s full HLS buffer.
@MainActor
final class HLSAudioSamplePlayer {
    private static let initialBufferFloorSeconds: TimeInterval = 0.14
    private static let maxAheadBufferSeconds: TimeInterval = 3.0
    private static let streamChunkSizeBytes = 2048

    private struct StreamPlaybackContext {
        let renderer: AVSampleBufferAudioRenderer
        let synchronizer: AVSampleBufferRenderSynchronizer
        let generation: UInt64
    }

    // swiftlint:disable:next no_dispatch_queue
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
                context: StreamPlaybackContext(renderer: renderer, synchronizer: synchronizer, generation: playGen)
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

        let targetCMTime = CMTime(seconds: targetSegment.startTime, preferredTimescale: 44100)
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
                context: StreamPlaybackContext(renderer: renderer, synchronizer: synchronizer, generation: seekGen)
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
        context: StreamPlaybackContext
    ) async {
        let renderer = context.renderer
        let synchronizer = context.synchronizer
        let generation = context.generation
        let session = await HLSManifestCache.shared.sharedSession
        var nextSegmentTask: Task<Data?, Never>?
        var currentSampleOffset = Int64((startTimeSeconds * 44100).rounded())

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
                    context: context
                )
            } else {
                feedResult = await self.streamFirstSegmentBytes(
                    url: segment.url,
                    session: session,
                    initialSampleOffset: currentSampleOffset,
                    startTimeSeconds: startTimeSeconds,
                    context: context
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
        context: StreamPlaybackContext
    ) async -> (success: Bool, nextOffset: Int64) {
        let renderer = context.renderer
        let synchronizer = context.synchronizer
        let generation = context.generation
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 8.0

        let initialStartTime = startTimeSeconds
        let startCMTime = CMTime(seconds: initialStartTime, preferredTimescale: 44100)
        let dataTaskState = OSAllocatedUnfairLock<(task: URLSessionDataTask?, cancelled: Bool)>(
            initialState: (nil, false)
        )

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
                let shouldCancel = dataTaskState.withLock { state in
                    state.task = task
                    return state.cancelled
                }
                if shouldCancel {
                    task.cancel()
                }
                task.resume()
            }
        } onCancel: {
            let task = dataTaskState.withLock { state in
                state.cancelled = true
                return state.task
            }
            task?.cancel()
        }
    }

    private func feedFullSegmentData(
        _ data: Data,
        initialSampleOffset: Int64,
        startTimeSeconds: TimeInterval,
        context: StreamPlaybackContext
    ) -> (success: Bool, nextOffset: Int64) {
        let renderer = context.renderer
        let synchronizer = context.synchronizer
        let generation = context.generation
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
            let startCMTime = CMTime(seconds: startTimeSeconds, preferredTimescale: 44100)
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
    // swiftlint:disable:next no_dispatch_queue
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
        // swiftlint:disable:next no_dispatch_queue
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
        dataTask _: URLSessionDataTask,
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
