import Foundation

// MARK: - DirectVideoStreamResolver

/// Resolves direct video stream URLs using `yt-dlp` for hardware-accelerated,
/// low-latency native video playback via `AVPlayer`.
@MainActor
final class DirectVideoStreamResolver {
    static let shared = DirectVideoStreamResolver()

    private struct CachedURL {
        let url: URL
        let expirationDate: Date
    }

    /// In-memory cache of resolved stream URLs with expiration (default 3 hours TTL).
    private var cache: [String: CachedURL] = [:]
    private var inFlightTasks: [String: Task<URL?, Never>] = [:]

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
            _ = await self.resolveStreamURL(videoId: videoId, timeoutSeconds: 15.0)
        }
    }

    /// Attempts to resolve a direct HTTPS video streaming URL (progressive MP4 or HLS manifest)
    /// for a YouTube videoId.
    ///
    /// - Parameters:
    ///   - videoId: Target video ID.
    ///   - timeoutSeconds: Maximum wait time before timing out (default 10.0s).
    /// - Returns: Direct streaming URL if resolved within the timeout, or `nil` on failure/timeout/DRM.
    func resolveStreamURL(videoId: String, timeoutSeconds: TimeInterval = 10.0) async -> URL? {
        // 1. Check in-memory cache
        if let cachedURL = self.cachedStreamURL(for: videoId) {
            return cachedURL
        }

        // 2. Check if a task is already in-flight for this videoId to prevent duplicate processes
        if let existingTask = self.inFlightTasks[videoId] {
            return await existingTask.value
        }

        guard let ytdlpPath = DownloadManager.shared.ytdlpPath else {
            return nil
        }

        let task: Task<URL?, Never> = Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ytdlpPath)
            // Prioritize combined MP4 and HLS streams natively playable by AVPlayer without external demuxing:
            // 1. Adaptive HLS master playlist
            // 2. 720p progressive MP4 (format 22)
            // 3. 360p progressive MP4 (format 18)
            // 4. Any combined mp4/best stream
            process.arguments = [
                "-g",
                "-f", "best[protocol^=m3u8]/22/18/best[ext=mp4]/b/best",
                "--no-playlist",
                "--no-warnings",
                "--extractor-args", "youtube:player_client=android,web",
                "--socket-timeout", "6",
                "https://www.youtube.com/watch?v=\(videoId)",
            ]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                return nil
            }

            // Race process completion with timeout
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if process.isRunning {
                    process.terminate()
                }
            }

            return await withTaskCancellationHandler {
                process.waitUntilExit()
                timeoutTask.cancel()

                guard process.terminationStatus == 0 else { return nil }

                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !output.isEmpty,
                      let url = URL(string: output.components(separatedBy: .newlines).first ?? output),
                      url.scheme == "https" || url.scheme == "http"
                else {
                    return nil
                }

                return url
            } onCancel: {
                if process.isRunning {
                    process.terminate()
                }
            }
        }

        self.inFlightTasks[videoId] = task
        let resolvedURL = await task.value
        self.inFlightTasks.removeValue(forKey: videoId)

        if let resolvedURL {
            // Cache for 3 hours (YouTube direct playback URLs are valid for 6+ hours)
            self.cache[videoId] = CachedURL(url: resolvedURL, expirationDate: Date().addingTimeInterval(3 * 3600))
        }

        return resolvedURL
    }

    /// Prefetches a stream URL into memory cache in the background.
    func prefetchStreamURL(videoId: String) {
        guard self.cache[videoId] == nil, self.inFlightTasks[videoId] == nil else { return }
        Task {
            _ = await self.resolveStreamURL(videoId: videoId, timeoutSeconds: 5.0)
        }
    }

    /// Clears any cached stream URLs.
    func clearCache() {
        self.cache.removeAll()
    }
}
