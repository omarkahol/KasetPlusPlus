import Foundation

// MARK: - DirectVideoStreamResolver

/// Resolves direct video stream URLs via YouTube's InnerTube player API for hardware-accelerated,
/// low-latency native video playback via `AVPlayer`.
@MainActor
final class DirectVideoStreamResolver {
    static let shared = DirectVideoStreamResolver()

    private struct CachedURL {
        let url: URL
        let expirationDate: Date
    }

    private struct InFlightResolution {
        let id: UUID
        let task: Task<URL?, Never>
        let timeoutSeconds: TimeInterval
    }

    /// In-memory cache of resolved stream URLs with expiration (default 3 hours TTL).
    private var cache: [String: CachedURL] = [:]
    private var inFlightTasks: [String: InFlightResolution] = [:]

    private init() {}

    /// Returns a cached direct stream URL synchronously if one is present and unexpired.
    func cachedStreamURL(for videoId: String) -> URL? {
        guard let cached = self.cache[videoId], cached.expirationDate > Date() else {
            return nil
        }
        return cached.url
    }

    /// Resolves and caches a video stream URL in the background without blocking callers.
    func prewarm(videoId: String) {
        guard self.cachedStreamURL(for: videoId) == nil, self.inFlightTasks[videoId] == nil else {
            return
        }
        Task {
            _ = await self.resolveStreamURL(videoId: videoId, timeoutSeconds: 8.0)
        }
    }

    /// Attempts to resolve a direct `AVPlayer`-compatible video streaming URL (HLS manifest or muxed MP4)
    /// for a YouTube videoId.
    ///
    /// - Parameters:
    ///   - videoId: Target video ID.
    ///   - timeoutSeconds: Maximum wait time before timing out (default 6.0s).
    /// - Returns: Direct streaming URL if resolved within the timeout, or `nil` on failure/timeout/DRM.
    func resolveStreamURL(videoId: String, timeoutSeconds: TimeInterval = 6.0) async -> URL? {
        if let cachedURL = self.cachedStreamURL(for: videoId) {
            return cachedURL
        }

        let startedAt = ContinuousClock.now
        if let existing = self.inFlightTasks[videoId] {
            let existingURL = await existing.task.value
            if let existingURL {
                return existingURL
            }
            // Do not let a cancelled/shorter prefetch timeout poison a full user-initiated resolution.
            if Task.isCancelled || existing.timeoutSeconds >= timeoutSeconds {
                return nil
            }
        }

        let elapsed = startedAt.duration(to: ContinuousClock.now)
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000.0
        let remainingBudget = timeoutSeconds - elapsedSeconds
        guard !Task.isCancelled, remainingBudget > 0.1 else {
            return nil
        }

        let taskID = UUID()
        let task: Task<InnerTubeStreamResolver.ResolvedStream?, Never> = Task {
            await InnerTubeStreamResolver.shared.resolveStream(
                videoId: videoId,
                timeoutSeconds: remainingBudget
            )
        }
        let wrapperTask = Task<URL?, Never> {
            await task.value?.url
        }

        self.inFlightTasks[videoId] = InFlightResolution(
            id: taskID,
            task: wrapperTask,
            timeoutSeconds: timeoutSeconds
        )
        let resolved = await task.value
        if self.inFlightTasks[videoId]?.id == taskID {
            self.inFlightTasks.removeValue(forKey: videoId)
        }

        if let resolved {
            self.cache[videoId] = CachedURL(
                url: resolved.url,
                expirationDate: Date().addingTimeInterval(resolved.ttl)
            )
        }

        return resolved?.url
    }

    /// Prefetches a stream URL into memory cache in the background.
    func prefetchStreamURL(videoId: String) {
        guard self.cachedStreamURL(for: videoId) == nil, self.inFlightTasks[videoId] == nil else { return }
        Task {
            _ = await self.resolveStreamURL(videoId: videoId, timeoutSeconds: 4.0)
        }
    }

    /// Invalidates a cached stream URL for a video ID.
    func invalidate(videoId: String) {
        self.cache.removeValue(forKey: videoId)
    }

    /// Clears any cached stream URLs.
    func clearCache() {
        self.cache.removeAll()
    }
}
